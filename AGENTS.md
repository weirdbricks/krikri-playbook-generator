# AGENTS.md

## What this is

`krikri-playbook-generator` is a Crystal CLI that schema-fuzzes Ansible
modules — scanning `DOCUMENTATION` schemas, generating happy-path and
"chaos mode" (deliberately invalid) argument sets, assembling them into
playbooks, and running them against real `ansible-playbook` and
`krikri-playbook` to find divergences that Galaxy roles and hand-written
test playbooks don't happen to exercise. See `KRIKRI_PLAYBOOK_GENERATOR.md`
for the full proposal.

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
  **Implemented**: for each option, required options are always included,
  optional ones at 50%; a happy-path value is generated per Ansible type
  (respecting `choices` when present), or — independently per option-slot
  at `chaos_percentage` — one chaos mutation (Typo/Hallucinate/WrongType/
  BadChoice, picked uniformly from `--chaos-kinds`) replaces it.
  `ViolateConstraint` is rolled once per constraint *group* rather than
  per option, since it inherently spans several options: it force-includes
  a whole `mutually_exclusive` group, breaks a `required_together` group
  down to one member, or empties a `required_one_of` group entirely.
  `required_if` isn't violated (its heterogeneous `[key, value,
  [required_keys], bool?]` shape doesn't reduce to a name group the same
  way) — documented gap, not guessed at. Deterministic per seed
  (`Random::PCG32`); every mutation is recorded in `GeneratedTask#mutations`,
  never applied silently.
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
- `src/krikri_playbook_generator/runner.cr` — `Runner`. **Implemented, but
  scoped down from the original "delegate to krikri-role-tester" plan**:
  role-tester's `RoleRunner`/backends are built around installing a Galaxy
  role and provisioning a fresh host pair per role — there's no "run this
  raw generated playbook" entry point to delegate to without cross-repo
  changes to role-tester itself, which is out of scope here. Instead
  `Runner` runs each playbook locally (`-i localhost, -c local`) against
  both engines directly, in **`--check --diff` mode by default** — chaos
  tasks are mostly self-limiting (they fail argument validation before
  doing anything), but happy-path tasks are real modules that would
  otherwise install packages, create users, etc. on *this* machine.
  `--allow-mutation` opts out of check mode for whoever wires up a real
  disposable-host backend later; `--atlantic-hosts` is accepted and
  stored for that same future wiring but unused by this local runner.
  Own small `Recap` (ok/changed/unreachable/failed/skipped, parsed from
  the `PLAY RECAP` line) rather than reusing role-tester's — copying one
  five-line regex-based struct beat adding a `path:` dependency on an app
  shard for it. Writes one `results.jsonl` line per playbook (`playbook`,
  `divergent?`, both engines' `rc`/`recap`) to `--results-dir`. Verified
  live: a real generated batch across apt/user/debug ran clean against
  both installed engines and **found two genuine recap divergences**
  between real ansible-playbook and krikri-playbook on the first try.
- `src/krikri_playbook_generator/triage.cr` — `Triage`. **Implemented**:
  reads `results.jsonl` (`Runner`'s output), and for every `divergent:
  true` line loads that playbook's `.meta.json` sidecar
  (`PlaybookBuilder`'s output — the only place linking a playbook back to
  its module and mutations) and groups by `{module, chaos_kind, option}`.
  A happy-path divergence (no mutations) groups under `{module, nil, nil}`.
  A playbook with several mutations contributes one finding per mutation
  — if a divergence could be caused by any one of several simultaneous
  mutations, triage shouldn't quietly credit only the first. Findings
  dedupe by that key (N playbooks hitting the same module+kind+option
  become one `Finding` with `count: N`, not N separate ones) and sort by
  descending count, so the highest-signal root cause surfaces first — the
  same "two roles, same root cause, one fix" principle
  `krikri-role-tester`'s own triage step already uses. A missing
  `.meta.json` sidecar (or missing `results.jsonl` entirely) is skipped/
  raised on respectively rather than crashing the whole report.
- `src/krikri_playbook_generator/options.cr` — CLI parsing for the three
  subcommands (`generate`, `run`, `report`). Both `run <dir>` and
  `report <dir>` accept that directory as a positional argument (falling
  back to `--out`/`--results-dir` otherwise), matching the CLI sketch in
  `KRIKRI_PLAYBOOK_GENERATOR.md`.
- `src/krikri_playbook_generator.cr` — entrypoint, dispatches on
  `Options.parse(ARGV).command`; `Command::Report` prints each `Finding`
  as `<module> (<kind> <option>|happy-path): <count> divergent
  playbook(s)` plus the list of playbook paths.

Every stub is now implemented (`Options`, `Preflight`, `SchemaScanner`,
`Generator`, `PlaybookBuilder`, `Runner`, `Triage`) — the full
generate → run → report pipeline works end to end. See "Known gaps"
below for what's deliberately left unbuilt.

## Conventions and gotchas

- Follow `krikri-role-tester`'s conventions where they apply here too:
  no comments unless explaining a non-obvious why; external commands go
  through `Cmd.run` (`src/krikri_playbook_generator/cmd.cr`), not a bare
  `Process.run`.
- **Coverage scope**: 100% bar for `ansible.builtin` core + krikri's
  chosen community modules; zero obligation for the rest. The default
  `--modules` list should be derived from the same source of truth the
  role-tester coverage bar uses, not hand-duplicated (see
  `community-module-scope-cut` convention in krikri's own memory).
- **Chaos mutations must always carry metadata** (`GeneratedTask#mutations`)
  — never inject a chaos mutation silently, or triage can't distinguish
  "found a real bug" from "found an artifact of our own fuzzing."
- **`Runner` defaults to `--check` and must keep doing so** — happy-path
  tasks are real modules that mutate real state (install packages, create
  users, write files); running them for real against *this* machine
  without an isolated/disposable host is not something to do by default.
  Only `--allow-mutation` (explicit, documented as dangerous) opts out.
- A real disposable-host backend (Atlantic.net, matching
  krikri-role-tester's) for `Runner`'s mutating happy-path runs is a known
  gap, not built here — see `runner.cr`'s own comment for why role-tester
  itself couldn't be reused directly.

## Known gaps

Documented deliberately, not silently — same spirit as `required_if`
above:

- No real-host (Atlantic.net) execution backend yet; `Runner` is
  local/check-mode only (see above).
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
`playbook_builder_spec.cr`, `runner_spec.cr`, `triage_spec.cr`. `schema_spec.cr` shells out to
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
reasoning as `schema_spec.cr`. `triage_spec.cr` writes hand-built
`results.jsonl`/`.meta.json` fixtures rather than running the real
pipeline, so it can assert grouping/dedup/sort behavior precisely and
fast — the real pipeline is what the `generate`→`run`→`report` chain
itself exercises live (verified manually; no spec drives the full CLI
chain end to end yet). All temp-dir specs use `File.tempname`, cleaned up
in `ensure`.

`ameba` (1.7.0) is a dev dependency; run `crystal build lib/ameba/src/cli.cr
-o bin/ameba && ./bin/ameba` after `shards install` (no prebuilt binary is
shipped). Keep it clean — `crystal tool format .` first fixes most findings.
