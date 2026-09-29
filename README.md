# krikri-playbook-generator

A standalone tool that schema-fuzzes Ansible modules to find behavioral
divergences between real `ansible-playbook` and `krikri-playbook` that
Galaxy roles and hand-written test playbooks don't happen to exercise.

## Model

1. **schema** — scans installed `ansible-core` + collection Python module
   source for `DOCUMENTATION` YAML, normalizing each module's option spec
   (type, choices, required, default, `mutually_exclusive`,
   `required_together`, `required_if`, `required_one_of`, list `elements`).
2. **generator** — given a module schema, an RNG seed, and a
   chaos-percentage, builds random-but-schema-aware argument sets:
   - happy-path: a runnable, valid baseline. Path-typed options point at
     pre-seeded fixture files (`/opt/kpg-fixtures/...` read-only sources,
     `/tmp/kpg-work/...` writable dests — nothing outside those roots),
     `mode` is a valid octal string, `owner`/`group` are `root`,
     `validate` contains the `%s` placeholder, `choices` are respected,
     ints stay in sane ranges, and the baseline satisfies
     `mutually_exclusive`/`required_together`/`required_one_of`/
     `required_if`. Practical traps come from an extensible per-module
     override table (`src/krikri_playbook_generator/data/
     module_overrides.yml`, embedded at compile time).
   - chaos: per-option-slot, at probability `--chaos-percentage`, mutates
     the *valid baseline* into a typo'd/hallucinated option name, a
     wrong-type value, an off-schema choice, or a violated cross-option
     constraint. Every mutation is recorded on the generated task, never
     injected silently — chaos is always a delta from a runnable task.
3. **playbook-builder** — assembles generated tasks into playbook YAML,
   one task per module per play, following the shape of krikri's own
   `testing/test-*.yml` fixtures.
4. **runner** — two backends, neither the default. **Local** runs each
   playbook against both engines on this machine (`-i localhost, -c
   local`), `--check --diff` unless `--allow-mutation` is passed, so
   happy-path tasks (real modules — apt, user, ...) can't mutate *this*
   machine by accident. **Podman** (`--run-on-podman`, opt-in, needs
   `podman`) is where byte-parity actually holds: it provisions ONE
   template container pair (asserting the container's ansible-core is
   exactly 2.19.11, failing loudly otherwise), commits it to images, and
   then starts a **fresh container pair per playbook** — so users, files
   and state created by one playbook never leak into the next. Both
   engines get the identical invocation (same absolute playbook path and
   cwd, `ANSIBLE_NOCOLOR=1`, caching/gathering env vars stripped, stdin
   `</dev/null`, per-engine `timeout` so a hang is its own result, rc
   124). Raw stdout/stderr/rc are captured from both and diffed after a
   single explicit mask list. Neither backend replaces `--atlantic-hosts`
   (accepted and stored for a real disposable-host backend, not yet
   built).
5. **triage** — reads `results.jsonl` and produces the full report:
   divergences grouped by module + **diff signature** (changed lines with
   digits/paths/random names generalized and hashed, so N playbooks hit
   by the same root cause dedupe into one finding, sorted by descending
   count, each with an example playbook and a copy-paste repro command),
   a generator-quality section (per module, how many happy-path playbooks
   failed on real ansible — wasted coverage — and the first error line),
   and per-module byte-identical rates.

## Byte comparison

results.jsonl stores, per playbook: `masked_identical`, `raw_identical`,
`recap_divergent` (the old counter-only comparison, kept as an extra
field), a stable `signature`, the masked and unmasked diffs, and per
engine `rc`/`timed_out`/`recap`/raw `stdout`/`stderr`. The mask list
(`ByteDiff::MASKS` in `src/krikri_playbook_generator/masks.cr`) is
deliberately minimal, every entry carrying a justification comment:

1. real ansible's `[WARNING]: ...discovered Python interpreter...` line
   (krikri has no Python interpreter and can never emit it);
2. inherently non-deterministic fields applied identically to both
   sides: `ansible-tmp-*` temp dir names, wall-clock timestamps (ISO-8601
   and backup-file suffixes), and long digit runs (epoch-millis-class
   nonces).

Nothing else is masked — any remaining difference is the finding.

See `KRIKRI_PLAYBOOK_GENERATOR.md` in this repo for the full proposal,
open questions, and rationale for a separate repo.

## Coverage scope

Same rule as `krikri-role-tester`'s Galaxy-role workflow: 100% bar for
`ansible.builtin` core modules and modules krikri has deliberately chosen
to support; zero obligation for the rest. The default `--modules` list is
meant to be generated from that same source of truth, not hand-duplicated.

## Build

    shards install
    crystal build src/krikri_playbook_generator.cr -o bin/krikri-playbook-generator
    crystal spec   # minitest.cr under the hood
    crystal build lib/ameba/src/cli.cr -o bin/ameba && ./bin/ameba

## Usage

The full pipeline is implemented end to end, as three separate steps:

    krikri-playbook-generator generate --modules apt,copy,user,cron --seed 42 \
      --count 500 --chaos-percentage 3 --out playbooks/

    krikri-playbook-generator run playbooks/ --results-dir ~/scratch/kpg-results

    krikri-playbook-generator report ~/scratch/kpg-results

...or fused into one call with `--run-on-podman` (needs `podman`): builds
the playbooks (still written to `--out` for later review either way),
immediately runs them against both engines inside throwaway containers
(a fresh pair per playbook), prints `[DIVERGENT]`/`[IDENTICAL]`/
`[ERROR] <path>` per playbook as it goes, then the full report. **Exit
code is non-zero iff divergences exist.**

    krikri-playbook-generator generate --modules apt,copy,user,cron --seed 42 \
      --count 500 --chaos-percentage 3 --out playbooks/ \
      --results-dir ~/scratch/kpg-results --run-on-podman --keep-going

For overnight batches, add `--keep-going` (a per-playbook failure is
recorded as an errored result and the batch continues instead of
aborting) and optionally `--engine-timeout N` (per-engine seconds; a hung
engine is recorded with rc 124). The report has three sections:

- **Divergences** — grouped by module + diff signature, one line per
  root cause with its count, the example playbook and a copy-paste repro
  command (`krikri-playbook-generator run <playbook.yml> --run-on-podman
  ...` — `run` accepts a single playbook file path).
- **Generator quality** — per module, how many happy-path playbooks
  failed on real ansible (wasted coverage) and the first error line.
- **Per-module byte-identical rate** — masked-comparison identical/total
  per module.

`report` works on any results directory, including one produced by
`generate --run-on-podman`.

Without `--run-on-podman`, `run` executes locally and defaults to Ansible
`--check` mode (no real host mutation) since happy-path tasks are real
modules that would otherwise install packages, create users, etc. on the
machine running this tool; pass `--allow-mutation` to run for real
without podman, once you have your own disposable host to point it at.
`--run-on-podman` also works on `run` alone, to re-run an
already-generated `--out` directory.

## Status

`generate`/`run` refuse to proceed unless both `ansible-playbook` and
`krikri-playbook` are resolvable (`Preflight`). `SchemaScanner` scans
real, installed modules via `ansible-doc -j` for option schemas and via a
small embedded Python AST scanner for cross-option constraints.
`Generator` turns a schema into runnable happy-path and chaos-mutated
argument sets, deterministic per `--seed`, every mutation tagged with
which slot and which kind. `PlaybookBuilder` turns those into real
playbook YAML plus a `.meta.json` sidecar per playbook. `Runner` runs
each playbook against both real engines — locally (check mode by default)
or, with `--run-on-podman`, in a fresh pair of throwaway podman containers
per playbook via `PodmanBackend` (ansible-core 2.19.11 asserted) — and
writes `results.jsonl` with masked/unmasked diffs, rc, timeout flags, the
recap comparison and a stable diff signature. `Triage` turns that into
the full report: signature-grouped divergences with repro commands, the
happy-path quality metric, and per-module byte-identical rates.

A full local `generate → run → report` pass across apt/user/debug found
two genuine divergences between real ansible-playbook and
krikri-playbook, correctly attributed down to the specific mutated
option, on the first try; a separate `--run-on-podman` run found a third
(krikri erroring on a `debug` task real Ansible skips cleanly at a high
`verbosity:`). As of v0.0.8, a validated podman run across `template`,
`copy`, `file`, `command`, `debug`, `lineinfile`, `user` (--count 3,
happy path) measures per-module byte-identical rates against real
ansible-playbook 2.19.11 in isolated container pairs. See `AGENTS.md`'s
"Known gaps" for what's deliberately not built yet (a real
disposable-host execution backend for wide/production batches,
`required_if` violation, multi-task playbooks, and a default `--modules`
list).
