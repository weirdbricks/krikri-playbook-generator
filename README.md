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
     wrong-type value, an off-schema choice, a violated cross-option
     constraint, or a `jinja` expression that evaluates back to the same
     value (`0644` -> `{{ '0644' }}`, so the delta under test is the
     engine's templating, not the module's validation). Every mutation is
     recorded on the generated task, never injected silently — chaos is
     always a delta from a runnable task, and each kind is independently
     toggleable via `--chaos-kinds`.
   - happy-path quality is a first-class concern: `data/module_overrides.yml`
     can mark an option `exclude`d, fill it with an `empty_dict`, or mark a
     whole module `not_applicable` (a single-task local playbook cannot
     exercise it at all — `reboot` would reboot the control node,
     `apt_key`'s tooling no longer ships in the reference image). The
     overrides are only correct if real ansible actually runs the happy
     paths, which is what the success gate below measures.
3. **playbook-builder** — assembles generated tasks into playbook YAML,
   one task per module per play, following the shape of krikri's own
   `testing/test-*.yml` fixtures.
4. **runner** — two backends, neither the default. **Local** runs each
  playbook against both engines on this machine (`-i localhost, -c
  local`), `--check --diff` unless `--allow-mutation` is passed, so
  happy-path tasks (real modules — apt, user, ...) can't mutate *this*
  machine by accident; local refuses community modules outside the
  promoted set (they need collection/package provisioning only the
  podman templates do). **Podman** (`--run-on-podman`, opt-in, needs
  `podman`) is where byte-parity actually holds: it provisions ONE
  template container pair per profile (Debian/Rocky) from the UNION
  dependency set in `data/module_dependencies.yml` (base lists plus the
  in-scope modules' extras, partitioned real vs krikri), asserting the
  container's ansible-core is exactly 2.19.11, failing loudly otherwise,
  commits it to images, and then starts a **fresh container pair per
  playbook** — so users, files and state created by one playbook never
  leak into the next. The committed template images are kept as a
  content-addressed cache (tag `<name>:<fingerprint>` over the package
  lists, ansible-core pin, krikri binary/plugins digests and the fixture
  seed script): a later run with the same inputs skips provisioning
  entirely, and `--refresh-podman-templates` forces a rebuild and prunes
  the stale tags. Both engines get the identical invocation (same
  absolute playbook path and cwd, `ANSIBLE_NOCOLOR=1`,
  caching/gathering env vars stripped, stdin `</dev/null`, per-engine
  `timeout` so a hang is its own result, rc 124). Raw stdout/stderr/rc
  are captured from both and diffed after a single explicit mask list.
  **Atlantic.net** (`--run-on-atlantic`, opt-in, needs the KeePass
  credential source) is the third backend: one disposable VM per module
  profile (rpm, db, containers, misc) for the modules whose happy path
  needs a real service or kernel, dispatched from the same per-module
  profile table. `--atlantic-hosts` caps how many of those VMs run at
  once.
5. **triage** — reads `results.jsonl` and produces the full report:
  divergences grouped by module + **diff signature** (changed lines with
  digits/paths/random names generalized and hashed — keyed on the ansible
  side's first `-` line when there is one, krikri's first `+` line only
  when the reference engine printed nothing different — blank changed
  lines are never counted as "first", and a bare task-status `-` line
  (just `ok:`/`fatal:` etc. plus a host) additionally keys on krikri's
  first non-blank `+` line, so different krikri failures under an
  ansible success don't merge — so N playbooks hit
  by the same root cause dedupe into one finding, sorted by descending
  count, each with an example playbook and a copy-paste repro command),
   a generator-quality section (per module, how many happy-path playbooks
   failed on real ansible — wasted coverage — and the first error line,
   plus the batch-level happy-path success rate and the modules excluded as
   `not_applicable`), and per-module byte-identical rates.

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
to support; zero obligation for the rest. `generate`'s default module list
follows that rule: without `--modules`, it scans every installed
`ansible.builtin.*` module only; community modules join the default only
when deliberately promoted into
`src/krikri_playbook_generator/data/module_dependencies.yml: supported` and
requested with `--supported-community` (promoting one is a data-file
commit). `--all-modules` scans every installed module instead.

## Build

    just install     # shards install
    just build       # crystal build into bin/krikri-playbook-generator
    just spec        # crystal spec (minitest.cr)
    just lint        # ameba (bin/ameba, built once)
    just fmt         # crystal tool format

    just hello       # generate --modules debug --count 1 --out playbooks/
    just generate    # fused generate + --run-on-podman (apt,copy,user,cron x 500)
    just run         # run playbooks/ through podman
    just report      # report ~/scratch/kpg-results
    just version

## Usage

The full pipeline is implemented end to end, as three separate steps:

    krikri-playbook-generator generate --modules apt,copy,user,cron --seed 42 \
      --count 500 --chaos-percentage 3 --out playbooks/

    krikri-playbook-generator run playbooks/ --results-dir ~/scratch/kpg-results

    krikri-playbook-generator report ~/scratch/kpg-results

`generate`'s default module list is every installed `ansible.builtin.*`
module (short names, sorted); `--modules` narrows it explicitly,
`--supported-community` appends the promoted community modules from
`module_dependencies.yml`, and `--all-modules` scans every installed
module, collections included (the three are mutually exclusive).

...or fused into one call with `--run-on-podman` (needs `podman`): builds
the playbooks (still written to `--out` for later review either way),
immediately runs them against both engines inside throwaway containers
(a fresh pair per playbook), prints `[DIVERGENT]`/`[IDENTICAL]`/
`[ERROR] <path>` per playbook as it goes, then the full report. **Exit
code is 2 iff divergences exist, 1 when the tool itself failed.**

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
- **Generator quality** — the batch happy-path success rate (how many
  generated happy-path playbooks real ansible actually ran), per module how
  many failed on real ansible (wasted coverage) and the first error line,
  plus the modules excluded as intentionally failing or `not_applicable`.
- **Per-module byte-identical rate** — masked-comparison identical/total
  per module.

### Happy-path success gate

A batch whose happy-path playbooks mostly fail on the reference engine is
measuring almost nothing (there is no success-path comparison to make), so
`report` and a `generate` that runs a backend accept
`--min-happy-success PCT`:

    krikri-playbook-generator report ~/scratch/kpg-results --min-happy-success 90

When the measured rate is below the threshold, the tool prints the rate to
stderr and exits **1** — distinct from 2 (krikri diverges) and from an
engine/provisioning failure, so a wrapper can tell "the fuzzer's own
coverage regressed, fix `module_overrides.yml`" from "a real divergence was
found". A batch with no happy-path playbooks passes the gate.

`report` works on any results directory, including one produced by
`generate --run-on-podman`. Add `--json` to print ONE JSON object on
stdout instead of the human report — `results_dir`, `total`/`errored`/
`divergent` counts, `findings` grouped by module + diff signature (each
with its playbooks and an example carrying chaos/mutations, the masked
diff and ansible's first error), `errors`, `not_applicable` (modules a
single-task local playbook cannot exercise), `happy_coverage` (attempted/
failed/succeeded/`success_percent`), and per-module `rates`. Exit code is
unchanged (0 none, 2 divergences, 1 gate/failure); warnings stay on stderr.

Every `run` also writes `versions.txt` next to `results.jsonl` — a
best-effort provenance record (tool version, run start time, krikri
binary path/mtime/`--version`/git commit + subject, ansible-playbook
version, control flag) parsed by krikri-role-triager, including a
warning line when the krikri binary is older than its checkout's last
commit touching build inputs.

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
ansible-playbook 2.19.11 in isolated container pairs.

As of v0.0.11 the happy path is measured rather than assumed: a mixed
`ansible.builtin` batch now dispatches each playbook to the template pair
its module needs (Debian vs Rocky), the remaining non-runnable core modules
carry an explicit override instead of silently wasting coverage, generated
values can be templated (`--chaos-kinds jinja`), and
`--min-happy-success` fails a batch whose happy paths mostly fail on the
reference engine. See `AGENTS.md`'s "Known gaps" for what's deliberately
not built yet (multi-task playbooks, non-builtin
module scope).

## Version

    krikri-playbook-generator --version
    krikri-playbook-generator version
    krikri-playbook-generator -v

Prints `krikri-playbook-generator <VERSION>` and exits 0 without needing a subcommand.

Runs log timestamped progress to **stderr** (stdout stays parseable):

    04:58:45 [runner] starting 1 playbook(s) (backend=local, results=...)
    04:58:45 [runner] executing 1 playbook(s) (local) ...
    04:58:45 [runner] executing 1 playbook(s) (local) done in 0.6s (started 04:58:45)
    04:58:45 [runner] batch complete: 1 playbook(s), 0 divergent, 0 errored

The podman backend logs each template step (`starting ...`, `installing ... packages`, `committing ...`, `ready`) with the same `Log.phase` start/done stamping (`src/krikri_playbook_generator/log.cr` — the only diagnostic channel for run/provision paths).
