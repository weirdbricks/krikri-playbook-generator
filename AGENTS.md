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
  `group`, `validate`, `source_path`, `work_path`, `username`,
  `literal_pool`, `exclude`), `choices` are respected, ints stay in sane
  ranges (0–100). After value assignment, the baseline *satisfies*
  `mutually_exclusive` (keeps one member per group),
  `required_together` (fills in the rest of any touched group),
  `required_one_of` (populates an empty group) and `required_if`
  (adds demanded keys when the condition value is present). Chaos mode
  then mutates that valid baseline independently per option-slot at
  `chaos_percentage`: Typo/Hallucinate/WrongType/BadChoice, picked
  uniformly from `--chaos-kinds` — every chaos value is a delta from a
  runnable task, never a fresh random value. `ViolateConstraint` is still
  rolled once per constraint *group*: it force-includes a whole
  `mutually_exclusive` group, breaks a `required_together` group down to
  one member, or empties a `required_one_of` group. `required_if` isn't
  violated (documented gap). Deterministic per seed (`Random::PCG32`);
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
  each running its own roles/ search. `PodmanBackend` seeds it identically
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
  best-effort on the host) and podman (`--run-on-podman`, fresh container
  pair per playbook via committed template images). `--keep-going` turns
  per-playbook failures into errored results instead of aborting the
  batch; errored results are never counted as divergent.
  `--atlantic-hosts` is accepted and stored for a possible future remote/
  Atlantic.net backend but unused by either backend implemented here.
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
  FRESH pair from those committed images (`kpg-real-<n>…`,
  `kpg-krikri-<n>…`), copies the playbook into both, and execs each
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
  `ByteDiff#signature` computes from the masked diff — and each finding
  carries its count, one example playbook path and a copy-paste repro
  command (`Triage.repro_command`, backed by `run` accepting a single
  playbook file). `quality` is the generator-quality metric: per module,
  how many happy-path playbooks failed on real ansible (`ansible_failed`)
  plus the first error line — happy-path failures on the reference engine
  are wasted coverage. `rates` gives per-module byte-identical counts.
  Malformed lines and legacy lines missing `module` are skipped, a
  missing `results.jsonl` raises.
- `src/krikri_playbook_generator/options.cr` — CLI parsing for the three
  subcommands (`generate`, `run`, `report`), plus `--keep-going` and
  `--engine-timeout` (per-engine timeout in seconds; a hung engine is
  recorded with rc 124). Both `run <dir>` and `report <dir>` accept that
  directory as a positional argument (falling back to `--out`/
  `--results-dir` otherwise), and `run <file.yml>` accepts a single
  playbook path (the repro form Triage prints), matching the CLI sketch
  in `KRIKRI_PLAYBOOK_GENERATOR.md`.
- `src/krikri_playbook_generator.cr` — entrypoint, dispatches on
  `Options.parse(ARGV).command`. `Command::Report` prints the full
  report: divergences grouped by module + diff signature (with count,
  mutations, example playbook and repro command), the generator-quality
  section (happy-path failures on real ansible with first error line),
  and per-module byte-identical rates. `Command::Generate` fuses the
  whole pipeline into one call when `--run-on-podman` is passed: after
  building the playbooks (still written to `--out` for later review
  either way), it immediately runs them via `Runner` with
  `run_on_podman: true`, prints one `[DIVERGENT]`/`[IDENTICAL]`/
  `[ERROR] <path>` line per playbook, then the full report. Exit code is
  non-zero iff divergences exist (for `generate --run-on-podman`, `run`,
  and `report`); errors always exit 1. Plain `run` still supports
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
- **Coverage scope**: 100% bar for `ansible.builtin` core + krikri's
  chosen community modules; zero obligation for the rest. The default
  `--modules` list should be derived from the same source of truth the
  role-tester coverage bar uses, not hand-duplicated (see
  `community-module-scope-cut` convention in krikri's own memory).
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
- A real disposable-host backend (Atlantic.net, matching
  krikri-role-tester's) for wide/production batches is a known gap, not
  built here — see `runner.cr`'s own comment for why role-tester itself
  couldn't be reused directly. Podman fills the "fast local iteration"
  niche, not the "hundreds of hosts" one.

## Known gaps

Documented deliberately, not silently — same spirit as `required_if`
above:

- No real-host (Atlantic.net) execution backend yet; `Runner` only has
  local (`--check`-mode) and podman (`--run-on-podman`) backends (see
  above) — neither replaces provisioning real disposable hosts for a
  wide/production batch.
- `PodmanBackend` installs one fixed, generic dependency set rather than
  podman-diff's dozens of per-module installs — a randomly fuzzed module
  needing something outside that set fails identically on both engines
  in the common case, or can manufacture a false divergence if only one
  side needs it.
- `required_if` constraints are never violated by `Generator` (documented
  above).
- Multi-task interaction fuzzing (register/when chains, loops, handlers)
  is v2 per the proposal; `PlaybookBuilder` only ever emits one task per
  playbook.
- `--modules` has no default derived from krikri's core+supported-community
  list yet (the "Coverage scope" convention above) — every `generate`
  invocation currently needs an explicit `--modules` list or accepts
  ansible-core's *entire* installed module set (including modules krikri
  has no obligation to support).

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
`triage_spec.cr`. `schema_spec.cr` shells out to
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
signature grouping/dedup/sort, quality and rate behavior precisely and
fast — the real pipeline is what the `generate`→`run`→`report` chain
itself exercises live (verified manually; no spec drives the full CLI
chain end to end yet). `masks_spec.cr` unit-tests the mask list, the
LCS diff and signature stability. All temp-dir specs use `File.tempname`,
cleaned up in `ensure`.

`ameba` (1.7.0) is a dev dependency; run `crystal build lib/ameba/src/cli.cr
-o bin/ameba && ./bin/ameba` after `shards install` (no prebuilt binary is
shipped). Keep it clean — `crystal tool format .` first fixes most findings.
