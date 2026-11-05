# AGENTS.md

## What this is

`krikri-playbook-generator` is a Crystal CLI that schema-fuzzes Ansible
modules — scanning `DOCUMENTATION` schemas, generating happy-path and
"chaos mode" (deliberately invalid) argument sets, assembling them into
playbooks, and running them against real `ansible-playbook` and
`krikri-playbook` to find divergences that Galaxy roles and hand-written
test playbooks don't happen to exercise. As of v0.0.8 the comparison is
**byte-for-byte**: raw stdout/stderr/rc from both engines, diffed after a
single explicit mask list, with a stable diff signature used for triage.
See `KRIKRI_PLAYBOOK_GENERATOR.md` for the full proposal.

It is a sibling of `../krikri-role-tester` and depends on (not
duplicates) that repo's dual-engine execution/diffing machinery.

## Commands

```sh
shards install
crystal build src/krikri_playbook_generator.cr -o bin/krikri-playbook-generator
crystal spec
```

No Makefile, no CI config, no linter configured yet (ameba is a dev dep
but no `.ameba.yml` exists). Crystal >= 1.20.0 required.

## Architecture

- `src/krikri_playbook_generator/schema.cr` — `OptionSchema`/`ModuleSchema`
  plus `SchemaScanner`. **Implemented**: shells out to the real, installed
  `ansible-doc -j` for each module's option schema (type/choices/required/
  default/elements — exactly what real ansible-playbook validates
  arguments against, no YAML re-parsing of our own) and to
  `scripts/extract_constraints.py` (an embedded Python AST scanner, run via
  `python3 -` over stdin, `{{ read_file(...) }}`'d into the binary at
  compile time) for `mutually_exclusive`/`required_together`/`required_if`/
  `required_one_of`, since those live only in the module's `AnsibleModule()`
  call, not `DOCUMENTATION` — `ansible-doc` never sees them. The extractor
  only picks up literal list arguments (`ast.literal_eval`); anything built
  dynamically is left empty rather than guessed at.
- `src/krikri_playbook_generator/cmd.cr` — `Cmd.run`, mirroring
  krikri-role-tester's external-command wrapper; also how the constraint
  extractor's script body reaches `python3 -` via `input:`.
- `src/krikri_playbook_generator/generator.cr` — `ChaosKind` enum,
  `GeneratedTask` (args + mutation metadata), `Generator#generate`.
  **Implemented (v0.0.8, rewritten)**: the happy path is now a *runnable*
  valid baseline, not just schema-valid: path-typed options point at
  pre-seeded fixture files (`Fixtures` — read-only sources under
  `/opt/kpg-fixtures`, writable dests under `/tmp/kpg-work`; nothing the
  generator emits touches paths outside those two roots), `mode`/`owner`/
  `group`/`validate` and other practical traps come from a per-module
  override table (`src/krikri_playbook_generator/data/module_overrides.yml`,
  embedded at compile time, easy to extend — kinds: `mode`, `owner`,
  `group`, `validate`, `source_path`, `work_path`, `work_dir`, `username`,
  `literal_pool`, `empty_dict`, `exclude`, plus module-level `always`,
  `free_form`, `require_one_of`, `expect_failure` and `not_applicable`),
  `choices` are respected, ints stay in sane
  ranges (0–100). After value assignment, a fill never introduces a
  second member of a `mutually_exclusive` group (Ansible validates that
  last, so `addable?` checks it and a final pass enforces it), and the
  baseline *satisfies*
  `mutually_exclusive` (keeps one member per group),
  `required_together` (fills in the rest of any touched group),
  `required_one_of` (populates an empty group with a non-conflicting
  member) and `required_if`
  (adds demanded keys when the condition value is present). Chaos mode
  then mutates that valid baseline independently per option-slot at
  `chaos_percentage`: Typo/Hallucinate/WrongType/BadChoice/Jinja, picked
  uniformly from `--chaos-kinds` — every chaos value is a delta from a
  runnable task, never a fresh random value. `Jinja` is the one kind whose
  value stays semantically valid: it rewrites a value as a Jinja expression
  that evaluates back to it (`0644` -> `{{ '0644' }}`), so the delta under
  test is the engine's templating. `ViolateConstraint` is still
  rolled once per constraint *group*: it force-includes a whole
  `mutually_exclusive` group, breaks a `required_together` group down to
  one member, empties a `required_one_of` group, or violates a
  `required_if` entry by forcing its condition to the demanded value
  and dropping every key it demands (skipped when a demanded key is a
  required option or excluded, which would trip an unrelated check).
  Deterministic per seed (`Random::PCG32`);
  every mutation is recorded in `GeneratedTask#mutations`, never applied
  silently.
- `src/krikri_playbook_generator/fixtures.cr` — `Fixtures`. **Implemented**:
  fixture layout (source files + a Jinja template + an executable script
  under `/opt/kpg-fixtures`, writable dests under `/tmp/kpg-work`) and the
  seed script. It also seeds the two things the engine-side-resolved actions
  need to run at all: a task file (`tasks.yml`) for
  import_tasks/include_tasks and a minimal role
  (`roles/kpgrole/tasks|defaults|vars|handlers/main.yml`) for
  include_role/import_role, which the overrides name by absolute path
  (`Fixtures::ROLE_PATH`) so both engines resolve the same value instead of
  each running its own roles/ search. It also seeds the fixtures the
  happy paths need a real object for: an armored OpenPGP key
  (`Fixtures::PGP_KEY_PATH`, for rpm_key), a local Subversion repository
  (`Fixtures::SVN_REPO_URL`, where svnadmin is installed) and a finished
  async job under `$HOME/.ansible_async` (`Fixtures::ASYNC_JOB_ID`, for
  async_status, since single-task playbooks cannot create one).
  `PodmanBackend` seeds it identically
  into BOTH containers
  during provisioning (never via playbook tasks, so seeding never appears
  in the compared output); local runs seed the host best-effort and warn
  if that fails (e.g. `/opt` not writable).
- `src/krikri_playbook_generator/playbook_builder.cr` — `PlaybookBuilder`.
  **Implemented**: v1 scope is single-task-per-module playbooks (one play,
  one task, `hosts: all`, `gather_facts: false`, `register:` +
  `ignore_errors: true` so a batch keeps going past individual failures) —
  multi-task interaction fuzzing (register/when chains, loops, handlers)
  is a v2 concern per the proposal, not built here. Each `<n>-<module>-
  happy|chaos.yml` gets a sibling `<n>-<module>-happy|chaos.meta.json`
  (module/collection/chaos?/mutations) since the playbook YAML alone
  doesn't say which slots were mutated or how — `Triage` reads this back.
  Verified live: a generated chaos playbook fails against real
  `ansible-playbook --check` with exactly the mutation the generator
  recorded (a `mutually exclusive` error matching a real
  `ViolateConstraint` mutation).
- `src/krikri_playbook_generator/runner.cr` — `Runner`. **Implemented
  (v0.0.8, rewritten for byte parity)**: the comparison is now
  byte-for-byte — raw stdout, stderr and rc from both engines under the
  identical invocation, judged identical only when rc, timeout state and
  masked stdout/stderr all match (`PlaybookResult#masked_identical?`).
  Masks (`ByteDiff::MASKS` in `masks.cr`) are applied identically to both
  sides; the list is deliberately minimal: the discovered-Python
  interpreter WARNING line (krikri has no Python), ansible-tmp temp dir
  names, wall-clock timestamps (ISO-8601 / log format / lineinfile backup
  suffixes), and long digit runs (epoch-millis-class nonces). Nothing
  else is masked. results.jsonl stores per engine `rc`/`timed_out`/
  `recap`/raw `stdout`/`stderr`, plus `masked_identical`, `raw_identical`,
  `signature` (stable root-cause hash from the masked diff), the masked
  and unmasked diffs, and module/chaos/mutations metadata read from the
  sidecar — Triage no longer needs the sidecars. `recap_divergent?` (the
  old counter-only comparison) is kept as an extra field. `Recap` now
  also parses `ignored=N` (needed to detect happy-path failures hidden by
  `ignore_errors`). Backends: local (`--check` by default unless
  `--allow-mutation`; engines wrapped in `timeout`; fixtures seeded
  best-effort on the host), podman (`--run-on-podman`, fresh container
  pair per playbook via committed template images) and Atlantic.net
  (`--run-on-atlantic`, one disposable VM per module profile).
  `--keep-going` turns
  per-playbook failures into errored results instead of aborting the
  batch; errored results are never counted as divergent.
  `--atlantic-hosts` caps how many Atlantic VMs run concurrently.
- `src/krikri_playbook_generator/versions.cr` — `Versions`. **Implemented**:
  writes `<results_dir>/versions.txt` (called from `Runner#run`, right
  after results.jsonl) — a best-effort provenance record parsed by
  krikri-role-triager, which splits each line on the first `": "`. One
  `key: value` line each: tool version, run start (RFC3339 UTC), krikri
  binary path/mtime/`--version`/git commit (+ ` (dirty)`)/commit subject,
  ansible-playbook version, `control`. Plus, only when the krikri
  binary's mtime is older than the committer date of the checkout's last
  commit touching `src lib plugins scripts shard.yml shard.lock
  build.sh`, the exact line `warning: krikri binary is older than its
  checkout's last build-input commit`. Every probe is best-effort (30s
  timeout, `"unavailable"` on failure, never fails the run); the command
  runner is injectable as a `Proc` so the spec can fake it.
- `src/krikri_playbook_generator/podman_backend.cr` — `PodmanBackend`.
  **Implemented (v0.0.8, rewritten for isolation)**: provisions ONE
  template pair from `docker.io/library/debian:trixie-slim`
  (`kpg-tpl-real-<ts>-<pid>`, `kpg-tpl-krikri-<ts>-<pid>`), installs
  `ansible-core` + a runtime-lib set in one, `podman cp`'s the
  `krikri-playbook` binary and its `plugins/` dir into the other, seeds
  the identical `Fixtures` tree into both, asserts the container's
  ansible-core version equals `EXPECTED_ANSIBLE_VERSION` (2.19.11 —
  fails loudly otherwise), then `podman commit`s both templates into
  images and removes the templates. Every `run_playbook` call starts a
  FRESH pair from the committed images for the playbook's OWN profile
  (`kpg-real-<n>…`, `kpg-krikri-<n>…`; the per-profile image pairs are kept
  in a map, so a mixed Debian/rpm batch never runs apt modules on Rocky),
  copies the playbook into both, and execs each
  engine with the identical invocation (`bash -c "cd /work && env -u
  ANSIBLE_GATHERING -u ANSIBLE_CACHE_PLUGIN -u
  ANSIBLE_CACHE_PLUGIN_CONNECTION ANSIBLE_NOCOLOR=1 timeout <N>
  <engine> -i inventory.ini /work/<basename> </dev/null>"`); the pair is
  `podman rm -f`'d in `ensure` immediately after. `teardown` removes
  remaining containers AND the committed images; `PodmanBackend.leak_check`
  lists any leftover `kpg-*` containers via `podman ps -a` so Runner can
  report leaks at the end of a batch. Raises `PodmanProvisionError` up
  front if `--run-on-podman` is passed but `podman` isn't on PATH. Every
  podman/ansible/krikri invocation goes through `Cmd.run` with a timeout.
  Does **not** replicate podman-diff's dozens of per-module apt/collection
  installs (see the class's own doc comment) — modules needing something
  outside the fixed set fail identically on both engines in the common
  case, or can manufacture a false divergence if only one engine needs
  it; documented limitation, not silently papered over.
- `src/krikri_playbook_generator/triage.cr` — `Triage`. **Implemented
  (v0.0.8, rewritten)**: reads `results.jsonl` only (module/chaos/
  mutations are now embedded in each line by `Runner`, so sidecars aren't
  needed) and produces three sections. `report` groups divergent
  playbooks by `{module, signature}` — the stable root-cause hash
  `ByteDiff#signature` computes from the masked diff, keyed on the
  ansible side's first `-` line (krikri's first `+` line only when there
  is no `-` line at all, prefixed `ansible:`/`krikri:` so the two kinds
  never collide; blank `-`/`+` lines never count as "first", and a bare
  task-status `-` line — just a status word and a host — additionally
  keys on krikri's first non-blank `+` line so different krikri failures
  under an ansible success don't merge) — and each finding
  carries its count, one example playbook path and a copy-paste repro
  command (`Triage.repro_command`, backed by `run` accepting a single
  playbook file). `quality` is the generator-quality metric: per module,
  how many happy-path playbooks failed on real ansible (`ansible_failed`)
  plus the first error line — happy-path failures on the reference engine
  are wasted coverage. `happy_coverage` is the batch-level version
  (attempted/failed/succeeded/success rate), excluding chaos, errored,
  `expect_failure` and `not_applicable` modules; `not_applicable_modules`
  reports the exclusions so they stay visible. `rates` gives per-module
  byte-identical counts.
  Malformed lines and legacy lines missing `module` are skipped, a
  missing `results.jsonl` raises. `ResultLine` also keeps each line's
  masked diff (from results.jsonl's `diff.masked`) and error text;
  `report_json` renders the whole report as ONE JSON object (`report
  --json`): results_dir, total/errored/divergent counts, findings in the
  same grouping/order as `report` (each with playbooks and an example
  carrying chaos/mutations/masked_diff/ansible_error), errors,
  not_applicable, happy_coverage, rates.
- `src/krikri_playbook_generator/options.cr` — CLI parsing for the three
  subcommands (`generate`, `run`, `report`), plus `--keep-going`,
  `--engine-timeout` (per-engine timeout in seconds; a hung engine is
  recorded with rc 124), `--json` (valid only with `report`; error
  otherwise) and `--min-happy-success PCT` (the happy-path success gate;
  valid with `report`, or a `generate` that runs a backend). Both
  `run <dir>` and `report <dir>` accept that
  directory as a positional argument (falling back to `--out`/
  `--results-dir` otherwise), and `run <file.yml>` accepts a single
  playbook path (the repro form Triage prints), matching the CLI sketch
  in `KRIKRI_PLAYBOOK_GENERATOR.md`. `--chaos-kinds` accepts
  `typo`, `hallucinate`, `wrong-type`, `bad-choice`, `violate-constraint`
  and `jinja`.
- `src/krikri_playbook_generator.cr` — entrypoint, dispatches on
  `Options.parse(ARGV).command`. `Command::Report` prints the full
  report: divergences grouped by module + diff signature (with count,
  mutations, example playbook and repro command), the generator-quality
  section (batch happy-path success rate, per-module failures on real
  ansible with first error line, expected-failure and not-applicable
  exclusions), and per-module byte-identical rates. `Command::Generate` fuses the
  whole pipeline into one call when `--run-on-podman` is passed: after
  building the playbooks (still written to `--out` for later review
  either way), it immediately runs them via `Runner` with
  `run_on_podman: true`, prints one `[DIVERGENT]`/`[IDENTICAL]`/
  `[ERROR] <path>` line per playbook, then the full report. Exit code is
  2 iff divergences exist (for `generate --run-on-podman`, `run`,
  and `report`); a `--min-happy-success` gate violation exits 1, as do
  tool errors. Plain `run` still supports
  `--run-on-podman` on its own, for re-running an already-generated
  `--out` directory.

Every stub is now implemented (`Options`, `Preflight`, `SchemaScanner`,
`Generator`, `PlaybookBuilder`, `Runner`, `PodmanBackend`, `Triage`) — the
full generate → run → report pipeline works end to end, locally or via
podman. See "Known gaps" below for what's deliberately left unbuilt.

## Conventions and gotchas

- Follow `krikri-role-tester`'s conventions where they apply here too:
  no comments unless explaining a non-obvious why; external commands go
  through `Cmd.run` (`src/krikri_playbook_generator/cmd.cr`), not a bare
  `Process.run` — and every podman/ansible/krikri invocation gets a
  `timeout` (either `Cmd.run`'s timeout param or an inner GNU `timeout`).
- **Mask list discipline**: `ByteDiff::MASKS` is the single, explicit
  mask list and must stay minimal — only the discovered-Python WARNING
  line and inherently non-deterministic fields (timestamps, temp dir
  names, long epoch-class digit runs, backup file names). Every entry
  needs a justification comment. Never mask anything else; an unexplained
  difference after masking IS a finding.
- **Reference-side harness gaps**: a missing package/library on the
  reference (real ansible) side — unresolved module/action or `Failed to
  import the required Python library (<name>)` — is a harness gap, never
  a divergence: it's recorded as an error and fixed by adding the package
  to `data/module_dependencies.yml` (or promoting the module with its
  dependency entry), never masked.
- **Coverage scope**: 100% bar for `ansible.builtin` core + krikri's
  chosen community modules; zero obligation for the rest. The default
  `--modules` is core only; community modules join only when deliberately
  promoted into `data/module_dependencies.yml: supported` and requested
  with `--supported-community` (promoting one is a data-file commit, not a
  code change — matching role-tester's `SUPPORTED_COMMUNITY_MODULES` and
  the `community-module-scope-cut` convention).
- **Chaos mutations must always carry metadata** (`GeneratedTask#mutations`)
  — never inject a chaos mutation silently, or triage can't distinguish
  "found a real bug" from "found an artifact of our own fuzzing."
- **`Runner`'s local backend defaults to `--check` and must keep doing
  so** — happy-path tasks are real modules that mutate real state
  (install packages, create users, write files); running them for real
  against *this* machine without an isolated/disposable host is not
  something to do by default. Only `--allow-mutation` (explicit,
  documented as dangerous) opts out, and only for the local backend.
- **Podman is opt-in (`--run-on-podman`), never the default** — even
  though it's disposable and therefore safer than local mutation, it's
  slower to provision than a plain local `--check` run and needs `podman`
  installed; the person running this tool chooses when that tradeoff is
  worth it. Don't make `PodmanBackend.available?` alone flip the default.
- **Per-playbook isolation on the podman path is a hard requirement** —
  every playbook runs in a fresh container pair from the committed
  template images; never go back to reusing one container pair across a
  batch, and never seed fixtures via playbook tasks. The container's
  ansible-core version is asserted (2.19.11) and a mismatch fails
  provisioning loudly.
- Atlantic.net is a real backend (one disposable VM per module profile),
  but only for the modules listed in `AtlanticBackend::PROFILE_FOR_MODULE`;
  any other module is refused rather than guessed onto a VM, so a wide
  `--run-on-atlantic` batch is limited to those profiles unless a new one
  is added. Every `podman run` this backend
  issues (template pair and per-playbook pair alike) carries
  `--label krikri-owner-pid=<Process.pid>` (`OWNER_LABEL` in
  `podman_backend.cr`) so external cleanup tooling can tell a live run's
  containers from abandoned ones.

## Known gaps

Documented deliberately, not silently:

- Atlantic.net batches only cover the modules listed in
  `AtlanticBackend::PROFILE_FOR_MODULE` (rpm/db/containers/misc); an
  unlisted module is refused, not run somewhere that cannot satisfy its
  happy path, so widening that coverage means adding a profile.
- `PodmanBackend` installs a UNION dependency set (base lists plus
  `Dependencies#supported`'s extras) rather than podman-diff's dozens
  of per-module installs gated on a hand-picked case list — a randomly
  fuzzed batch can't gate per case, and two images beat one per
  module. A module needing something outside the union still fails
  identically on both engines in the common case, or can manufacture a
  false divergence if only one side needs it. Promoting a module (its
  dependency entry in `module_dependencies.yml`) is the fix; modules
  the happy path genuinely cannot run (not a missing package) belong
  in `module_overrides.yml` as `not_applicable: true`, never as a
  silent exclusion.
- Multi-task interaction fuzzing (register/when chains, loops, handlers)
  is v2 per the proposal; `PlaybookBuilder` only ever emits one task per
  playbook. `async_status` is only testable at all because `Fixtures` seeds
  a finished job under `$HOME/.ansible_async`.

## Tests

`minitest.cr` (`ysbaddaden/minitest.cr`, ~> 1.6), run through `crystal spec`
— matches the workspace-wide migration off `crystal spec`'s built-in
`.should` matchers. `spec/spec_helper.cr` is just `require
"minitest/autorun"`; each spec file requires the source file it tests
directly rather than relying on a blanket require. Use `describe`/`it`
blocks with `assert_equal`/`assert_raises`/`assert`/`refute` (no
`.should`), and avoid `not_nil!` (ameba's `Lint/NotNil` flags it) — prefer
`x || default` or `x.as(T)` after a `refute_nil` check. One spec file per
source module, following `krikri-role-tester`'s pattern:
`options_spec.cr`, `preflight_spec.cr`, `schema_spec.cr`, `generator_spec.cr`,
`playbook_builder_spec.cr`, `runner_spec.cr`, `podman_backend_spec.cr`,
`triage_spec.cr`, `versions_spec.cr` (fakes the command runner as a Proc). `schema_spec.cr` shells out to
the real, locally-installed `ansible-doc`/`python3` — no fakes, since
tracking whatever ansible-core is actually installed is the entire point —
but skips exercising unfiltered discovery (`SchemaScanner.new.scan`, no
`--modules`), which would spawn two subprocesses per one of ~9000+
installed modules; verify that path live. `generator_spec.cr` builds a
small hand-written `ModuleSchema` fixture rather than going through
`SchemaScanner`, so it stays fast and doesn't depend on any particular
module's real constraints. `playbook_builder_spec.cr` parses the written
YAML back with `YAML.parse` and the sidecar with `JSON.parse` rather than
string-matching the file. `runner_spec.cr` unit-tests `Recap`/
`PlaybookResult#divergent?` directly, plus one real integration case
(`ansible.builtin.debug`, always safe/fast/idempotent) that runs both real
engines end to end and checks `results.jsonl`'s shape — not a fake, same
reasoning as `schema_spec.cr`; it passes `run_on_podman: false` (now the
Runner default anyway) explicitly so it stays fast even if that default
ever changes. `podman_backend_spec.cr` is a real integration test too
(provisions actual containers, `skip`s itself — minitest.cr's `skip`, not
crystal-spec's `pending` — if `podman` or the `krikri-playbook` binary
isn't available rather than failing the suite on a machine without them).
`triage_spec.cr` writes hand-built
`results.jsonl` fixtures (with the new `module`/`signature`/`error`
fields) rather than running the real pipeline, so it can assert
signature grouping/dedup/sort, quality/rate/`happy_coverage` behavior and
the `not_applicable` exclusions precisely and
fast — the real pipeline is what the `generate`→`run`→`report` chain
itself exercises live (verified manually; no spec drives the full CLI
chain end to end yet). `masks_spec.cr` unit-tests the mask list, the
LCS diff and signature stability. `generator_spec.cr` also covers the
Jinja kind (the templated value must be equivalent to the baseline
value), the `empty_dict` override and the mutually-exclusive-safe fills.
`podman_backend_spec.cr` provisions BOTH profiles in its regression case
and asserts a Debian playbook still runs on the Debian image after the rpm
template was provisioned last (apt-get exists only there).
`overrides_spec.cr` covers `not_applicable` parsing. All temp-dir specs use `File.tempname`,
cleaned up in `ensure`.

`ameba` (1.7.0) is a dev dependency; run `crystal build lib/ameba/src/cli.cr
-o bin/ameba && ./bin/ameba` after `shards install` (no prebuilt binary is
shipped). Keep it clean — `crystal tool format .` first fixes most findings.
