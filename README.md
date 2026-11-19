# krikri-playbook-generator

A standalone tool that schema-fuzzes Ansible modules to find behavioral
divergences between real `ansible-playbook` and `krikri-playbook` that
Galaxy roles and hand-written test playbooks don't happen to exercise.

## Model

1. **schema** — scans installed `ansible-core` + collection Python module
   source for `DOCUMENTATION` YAML, normalizing each module's option spec
   (type, choices, required, default, `mutually_exclusive`,
   `required_together`, `required_if`, `required_one_of`, list `elements`,
   dict `suboptions`).
2. **generator** — given a module schema, an RNG seed, and a
   chaos-percentage, builds random-but-schema-aware argument sets:
   - happy-path: a runnable, valid baseline. Path-typed options point at
     pre-seeded fixture files (`/opt/kpg-fixtures/...` read-only sources,
     `/tmp/kpg-work/...` writable dests — nothing outside those roots;
     the fixture set includes a binary file, a file without a trailing
     newline, a template with literal text/expressions/comments/a
     statement block, and a mixed file-and-directory tree),
     `mode` is a valid octal string, `owner`/`group` are `root`,
     `validate` contains the `%s` placeholder, `choices` are respected,
     ints stay in sane ranges, dict and list-of-dict options carry their
     required suboptions (nested paths stay distinct per element), and the
     baseline satisfies
     `mutually_exclusive`/`required_together`/`required_one_of`/
     `required_if`. Practical traps come from an extensible per-module
     override table (`src/krikri_playbook_generator/data/
     module_overrides.yml`, embedded at compile time), whose pools mirror
     real playbook inputs as well as schema validity: URL keys next to
     local files, RPM capability names (`libc.so.6()(64bit)`) for dnf,
     absolute `yum_repository.file` paths, tilde-prefixed pip virtualenvs,
     empty/no-trailing-newline copy content, `groups: ""` with `append:
     true`, and a task-level proxy `environment:` for get_url/uri. The
     runtime-only `require_one_of` groups keep exactly one member (src or
     content, line or regexp) and sample which, so both forms are covered.
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
   `testing/test-*.yml` fixtures. `--tasks-per-playbook N` (N >= 2)
   instead builds multi-task playbooks from distinct modules with
   `register:`/`when:` chains, `loop:` over the fixture sources and a
   play-level handler (v2). One playbook's tasks always share a host
   profile (Ubuntu vs Rocky), so a profile with fewer than N modules
   yields a shorter playbook rather than a mix no single host can run.
   `--play-shapes split,role` (opt-in) widens the layout: `split` puts the
   tasks in two plays with `meta: flush_handlers` at the boundary (handler
   timing and the register chain across plays), `role` prepends a play
   whose `roles:` entry runs the seeded fixture role (role-relative
   includes and role-param/play-var/defaults precedence). Both are recorded in the
   sidecar as `play_shapes`/`plays`.
4. **runner** — two backends, neither the default. Every playbook is
  compared once per **mode** (`--check` and real) so a module that is
  right in one and wrong in the other cannot hide; each mode gets a
  fresh host pair, and a playbook whose first run succeeded on both
  engines is run a second time on the same host (the idempotency pass,
  `--no-second-run` to skip it). **Local** runs each
  playbook against both engines on this machine (`-i localhost, -c
  local`), `--check` (and `--diff`) unless `--allow-mutation` is passed, so
  happy-path tasks (real modules — apt, user, ...) can't mutate *this*
  machine by accident; local refuses community modules outside the
  promoted set (they need collection/package provisioning only the
  podman templates do). **Podman** (`--run-on-podman`, opt-in, needs
  `podman`) is where byte-parity actually holds: it provisions ONE
  template container pair per profile (Debian/Rocky) from the UNION
  dependency set in `data/module_dependencies.yml` (base lists plus the
  in-scope modules' extras, partitioned real vs krikri), asserting the
  container's ansible-core is exactly 2.21.6 and that every pinned
  collection resolves to the version in `collection_pins:` (a collection's
  argument spec ships with its version, so a floating install would
  compare krikri against a schema it does not target), failing loudly
  otherwise, commits it to images, and then starts a **fresh container
  pair per playbook** — so users, files and state created by one playbook
  never leak into the next. The committed template images are a two-level
  content-addressed cache: `kpg-base-*:<base fingerprint>` is the package
  layer (package lists, ansible-core pin, fixtures), and
  `kpg-img-*:<fingerprint>` adds the krikri binary/plugins. A run with the
  same inputs skips provisioning entirely; a run whose only change is a
  rebuilt krikri binary starts from the base pair and commits just the
  binary layer, instead of re-running apt and re-committing ~600 MB.
  `--refresh-podman-templates` forces a rebuild from the base image and
  prunes the stale tags. Both engines get the identical invocation (same
  absolute playbook path and cwd, `ANSIBLE_NOCOLOR=1`,
  caching/gathering env vars stripped, stdin `</dev/null`, per-engine
  `timeout` so a hang is its own result, rc 124). Raw stdout/stderr/rc
  are captured from both and diffed after a single explicit mask list.
  **Atlantic.net** (`--run-on-atlantic`, opt-in, needs the KeePass
  credential source) is the third backend: one disposable VM per module
  profile (rpm, db, containers, misc) for the modules whose happy path
  needs a real service or kernel, dispatched from the same per-module
  profile table. Each VM installs the same pinned `ansible-core` and
  `collection_pins:` set as the podman/microVM images, and refuses to run
  if the resolved collection versions drifted, so a community module
  compares against the argspec krikri targets. `--atlantic-hosts` caps
  how many of those VMs run at once.
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
   a state-divergence section for playbooks whose printed result matched
   but whose host state did not (state signature, example and the changed
   state lines),
   a generator-quality section (per module, how many happy-path playbooks
   failed on real ansible — wasted coverage — and the first error line,
   plus the batch-level happy-path success rate and the modules excluded as
   `not_applicable`), per-module byte-identical rates, and a batch header
   stating the modes covered, whether the second-run pass ran, and the
   batch wall time.

## Byte comparison

results.jsonl has one row per comparison: `playbook`, the `mode`
(`check` or `real`), the `run` number (1, or 2 for the idempotency pass),
`masked_identical`, `raw_identical`,
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

## Modes and idempotency

Each playbook is compared once per mode: a `--check` run and a real one.
Divergence in one half alone is the common case, so the default matrix on
an isolated backend (podman, microVM, mixed) is **both**; local runs stay
check-only unless `--allow-mutation` is explicit (real modules would
mutate *this* machine), and Atlantic runs are always real.
`--modes check|real|both` narrows or widens it. Every (playbook, mode)
gets its own fresh host/pair, so real-mode state can never leak into the
check row. Triage groups findings by module + mode + run + signature, so
a check-mode-only divergence is reported once, not twice.

Idempotency is the second axis: a playbook whose first run succeeded on
both engines is executed again on the same host pair, and the second
run's output, recap and state delta are compared engine-vs-engine. That
row carries `run: 2`, so first-run findings stay attributable; the pass
is skipped after a failed first run and on Atlantic (its playbooks share
one VM per profile). Second-run rows are excluded from the happy-path
coverage metric: they measure repeatability, not whether the reference
engine can run the task at all.

Both axes cost runtime, so the cost is visible: the report's `Batch`
section prints the modes, the idempotency flag and wall time, and
`versions.txt` records `modes:`, `user-profiles:`, `umasks:`,
`connections:`, `idempotency:` and `batch duration:`.

## Host state

Printing the same thing is not the whole comparison. On the podman and
microVM backends each engine's host is also snapshotted before and after
its run (file tree under `/etc`, `/tmp/kpg-work`, `/var/spool/cron` and
both identity homes, `/root` and `/home/kpg`, with
type/uid/gid/mode/size plus a sha256 for files under 1 MiB,
boot id, package versions, enabled systemd units, listening ports), and
the two before/after **deltas** are compared. Only deltas: the real and
krikri images start from different baselines, so comparing absolute
state would report the images themselves. A delta mismatch is a state
divergence even when stdout/stderr match exactly — `state_divergent`,
`state_signature` and `state_diff` in results.jsonl, plus each engine's
`state_after`, `state_digest` and `state_changes`. The report lists
state-only divergences in their own section (a playbook that differs on
both output and state is counted once, as an output finding). Local and
Atlantic runs have no per-engine isolated host, so they do not compare
state.

Leftover staging files are part of that same state finding. The snapshot
carries a `temps` section scanning the roots and `/tmp` for the engines'
staging prefixes (`.krikri-playbook-*`, `.ansible_tmp*`,
`ansible-moduletmp-*`, `ansible-tmp-*`), so a temp or partial write a
failed task never cleaned up is reported with the engine and the task the
run log blames (`leftover_temps` in results.jsonl), instead of being
guessed at as ordinary module output. Neither engine keeps a staging file
on any path it controls, so there is no legitimate residue to ignore
beyond `~/.ansible` and the SSH transport's own bookkeeping (krikri's
controller-side plugin cache, its `known_hosts` entry and its
ControlMaster socket directory); a destination file that both engines
create and keep identically is treated as module output.

## Check mode is read-only

`--check` promises to change nothing, so each **engine's own** before/after
delta is also judged against that promise on an isolated backend. Two
engines agreeing on the same mutation still both break check mode, which
the delta-vs-delta comparison cannot see. Anything left behind in a check
run is a `check-mode-mutation` finding (`check_mode_mutated` and
`check_mode_diff` in results.jsonl) with its own report section; the only
tolerated residue is engine control-side state (`~/.ansible` and the SSH
transport's cache/socket bookkeeping, already pruned from the snapshot,
plus the pip happy path's tilde virtualenv, whose compiled bytecode is
not byte-deterministic between two separately created venvs). A playbook
that also differs on printed output
is counted once, as an output finding.

## Identity and umask

Root hides permission bugs, so an isolated backend also has an identity
axis: `--user-profile root|nonroot|both` (default `root`) runs the engine
process as a provisioned unprivileged account (`kpg`, passwordless sudo)
instead of root, and `--umask LIST` (default `022`; `002`, `022`, `077`)
sets the umask both engines start under. Every (identity, umask) pair gets
its own fresh host/pair, so a non-root row can never share state with a
root one; each row records `user` and `umask` in results.jsonl and triage
groups by them, so a non-root-only divergence is reported separately and
the repro command pins both.

The writable fixture root is re-owned for the row's identity before the
first snapshot, so both engines still start from identical state. The
generated `owner`/`group` options template to `{{ kpg_owner }}` /
`{{ kpg_group }}`, resolved by the invocation to root or to the
unprivileged account, because a non-root task cannot chown to root and
would otherwise fail on the reference engine. The state oracle scans that
account's HOME too (with the same per-home control-side exclusions), so a
leftover or mode change under `/home/kpg` is not invisible. Local runs
stay the invoking account and Atlantic runs stay root; both still honor
`--umask`.

## Transport

Every row above uses `ansible_connection=local` unless asked otherwise.
`--connection local|ssh|both` adds a real transport axis on an isolated
backend: the template image gets an sshd plus a generated keypair for
root and for the provisioned `kpg` account, so both engines connect over
SSH to their own host. `both` expands to local plus every SSH variant, and
the variants differ only in where the connection settings arrive:

| Variant | User / key / port arrive through |
| ------- | -------------------------------- |
| `ssh` | the inventory (`ansible_user`, `ansible_private_key_file`, `ansible_port`) |
| `ssh-cli` | `-u` / `--private-key` flags, port in the inventory |
| `ssh-hostport` | a `host:port` inventory entry, user/key as flags |
| `ssh-env-key` | `ANSIBLE_PRIVATE_KEY_FILE` |
| `ssh-env-user` | `ANSIBLE_REMOTE_USER` |

Each row records `connection` in results.jsonl, Triage groups and
repro-pins it, and `versions.txt` records the applied list. First-run
rows on a fresh pair are the cold plugin-cache transport; the default
second run on the same pair is the warm one. `become: true` (the
`become` play keyword) is the escalate-with-no-play-level-user form over
the same transport. See `KRIKRI_PLAYBOOK_GENERATOR.md` in this repo for
the full proposal, open questions, and rationale for a separate repo.

## Distro profiles

A module whose happy path is installable on both images is marked
`profiles: [debian, rocky]` in `module_overrides.yml` (currently
`package`, whose `name: bash` exists everywhere). Every other module keeps
its one image. A marked playbook is run once per image as its own result
row: the report's byte-identical rates are per module AND per image, and
`package` therefore exercises apt on the Debian template and dnf on the
Rocky one. `apt`/`dnf`/`yum` cannot be promoted (the other image cannot
install them), and `service`/`systemd` wait for unit names that exist on
both distros.

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
    just corpus      # replay krikri's divergence corpus (podman, release/nightly gate)
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

`krikri-playbook-generator modules --json` prints that same default
scope (core + promoted FQCNs) without scanning it — one JSON array on
stdout, one name per line without `--json`; krikri-loop builds its kpg
module rotation from it so the two lists cannot drift.

...or fused into one call with `--run-on-podman` (needs `podman`): builds
the playbooks (still written to `--out` for later review either way),
immediately runs them against both engines inside throwaway containers
(a fresh pair per playbook), prints `[DIVERGENT]`/`[ERROR] <path>` per
failing playbook as it goes, then the full report. **Exit
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

### Re-fuzzing after a fix

Most follow-up findings in the production history were an earlier fix
verified only on the shape that reported it: literal `delegate_to` but
not `{{ var }}`, local but not delegated, one attempt but not under
retries, one include form but not the looped one, one package channel
but not the other. A fix is therefore not done until the touched module
has been re-fuzzed along the axis the fix sits on. The recipe is cheap on
purpose: one module, a small count, the existing template images, and the
adjacent axes in one batch.

    just refuzz copy 10   # generate + run + report, podman, own out/results dirs

The axis checklist (all of these, not just the reported one):

| Axis | Flags / command | Follow-up class it catches |
| ---- | --------------- | -------------------------- |
| delegation spelling | `--delegation literal` and `--delegation templated` (or `both`, one batch) | a fix that only covers the literal or only the templated target |
| local vs delegated | `--hosts 1` (delegate outside the play) and `--hosts 2` (delegate is a play host) | `delegate_facts`/`ansible_delegated_vars` only working for one shape |
| retries | `--retries retried,exhausted,delegated` | `until:`/`attempts` under delegation, never-satisfied conditions |
| failure/cleanup | `--blocks rescue,always --handlers failing,ignoring,chained` | ignored-failure accounting, `always`, rescue, handler order |
| include forms | `--includes relative,role-inner,loop-tasks,import-playbook,import-role` | playbook-relative vs role-relative resolution, looped includes |
| host scope | `--limit one` vs `--limit none` with `--gather-facts` | fact gathering and out-of-limit contact |
| mode matrix | default `--modes check,real` (never `--check` alone) | a fix that only holds in one mode |
| distro / package channel | the Debian and Rocky templates (`--run-on-podman`, `--run-on-mixed` for service modules) | apt vs dnf paths, the "other package formula" follow-ups |
| play keywords | default `--play-keywords` (linear/free/serial/...) | a fix that assumes one strategy or no serial |
| plugin loading | `--lookups`/`--expressions` (default all), `--plugin-discovery relative,env,config`, `--strategy-plugins` | a lookup returning null, a filter/expression rendered differently in `var:` vs `msg:`, a third-party strategy, or a plugin only found through the env/cfg path |
| custom module API | `--library-modules all` (or `check-mode,dict-arg,...`) | argument-spec validation, check-mode support, warning/error/traceback plumbing, `_verbosity`, collection imports |
| module_utils surface | `--module-utils all` (or one import path) | a custom module importing a module_utils module or public name krikri's shim lacks |
| reference version | `--reference-core-version 2.20.1 --run-on-podman` (repeatable) | a divergence that only exists on the version the production playbooks actually run |
| transport | `--connection both` | user/key/port plumbing, plugin upload and daemon reuse over the wire, `become` with no user set |
| play layout | `--play-shapes split,role` | a fix that only holds inside one play: handler flush timing, role-param/play-var precedence through `roles:`, registers carried across plays |

krikri-loop's fix workflow should gate on this: after a KPG-derived fix,
run the table above for the touched module (and its sibling module when
the fix is a shared helper) before closing the issue. The historical
follow-ups this exists for are exactly the "verified on the minimal repro"
class - literal vs templated `delegate_to`, local vs SSH delegation,
with vs without `retries`, the other package formula, and one more
missing `module_utils` import.

### Corpus replay (past divergence repros)

A curated corpus of repros from earlier divergences is a regression gate,
and it lives in krikri's own checkout
(`../krikri/test/fixtures/divergence/`, one directory per case):

    <case>/playbook.yml   the repro, or a role layout (tasks/main.yml,
                          defaults/main.yml, ... and no playbook.yml)
    <case>/expected.out   the exact normalized transcript real ansible-core
                          printed when the case was recorded
    <case>/NOTES.md       why the case exists (carried into results.jsonl,
                          never compared)
    <case>/flags.txt      optional: extra CLI flags, one per line (e.g.
                          `--check`, or `-e` followed by `name=value`)
    <case>/inventory.ini  optional: the case's own inventory, usually a
                          [local] host pinning ansible_python_interpreter
    live/cases.txt        cases that need a REAL host (package, service,
                          crontab or pip mutation), one name per line

`run --replay-corpus DIR` replays every case through both engines and
classifies the three comparisons per case:

| Comparison | Question it answers |
| ---------- | ------------------- |
| krikri vs real ansible | do the engines agree (the fuzzer's own question) |
| krikri vs `expected.out` | did a fix regress? |
| real ansible vs `expected.out` | has the recording drifted from the pinned ansible-core? |

They collapse into one status per case: the engines disagree ->
**regressed** (a corpus case exists because they disagreed once, so they
must agree now); they agree but the transcript no longer matches the
recording -> **drifted** (re-record it; krikri is not at fault); all three
agree -> **pass**. An engine that could not run at all, or a case with no
recording, is **failed-to-run** rather than a silent pass.

    krikri-playbook-generator run --replay-corpus ../krikri/test/fixtures/divergence \
      --results-dir ~/scratch/kpg-corpus --run-on-podman

The invocation is the one the RECORDING was made with: the case's own
`inventory.ini` when it ships one, its `flags.txt` (so a check-mode case
replays with `--check`), no `--diff`, and the runner's environment
(`ANSIBLE_NOCOLOR=1`, gathering/cache env vars stripped, stdin closed, a
per-engine `timeout`, raw stdout/stderr/rc). The batch-level `--check`/
`--modes` are refused - it is the case, not the gate, that decides those.
Cases listed in `live/cases.txt` are skipped with a `needs live host` row
(never run: they mutate the host) and a case that is listed but has no
directory still gets that row. Every case runs in a staged COPY of its
directory (the corpus itself is never written to), with `HOME` inside that
copy, so a `~/...` path cannot reach the developer's home. Locally each
engine gets its own fresh copy, so the engine that ran first cannot leave
files the second one then reports as already-present. The copy's path (each
engine's own directory locally, `/work` in a podman container) is rewritten
to the `<WORK>` the recording uses before comparing, so the transcripts
line up byte for byte, and a whole case tree (roles, `files/`,
`templates/`, a file the playbook reads) travels with it. A role-layout case is run through a synthesized entry play
(`hosts: kpg_targets`, `gather_facts: false`, `roles: [<case>]`) at one
absolute path both engines share; when a case ships no inventory of its
own, both backends hand the engines the same fallback inventory, so a
repro targeting `localhost` (how they were written) or the generated
`kpg_targets` group matches exactly one host either way.

The three input conventions are krikri's own (`Krikri::DivergenceCase`/
`DivergenceTranscript`, used by the in-process replay in
`test/integration/divergence_corpus_test.cr`): a recording normalizes its
scratch directory to `<WORK>`, a case can select `--check`/extra args via
`flags.txt`, and a case can pin its interpreter via `inventory.ini`. This
runner reads all three, so a case recorded faithfully replays as `pass`
here as well.

`--run-on-podman` gives each case a **fresh container pair** (the same
isolation the fuzz batches get, and the reason a recording is
reproducible at all). Without it the replay runs on this machine, where
the two engines share one host: a case whose transcript includes
pre-existing state can legitimately differ between them, so the local
backend is a smoke gate, not the release gate. The disposable-VM backends
(Atlantic, microVM, mixed) are not wired for replay yet and are refused
rather than silently collapsed onto one of the two.

Results look like a fuzz batch's: `results.jsonl` rows in the same shape
(`module` carries the CASE NAME, `mode` is `replay`) plus
`corpus_status`/`corpus_reason`/`corpus_notes` and `diff.expected`/
`diff.drift` next to the engine-vs-engine diff, `versions.txt` provenance
including the corpus path and case counts, and the report's sections -
a `== Corpus replay ==` summary (counts, one line per non-pass case with
its diff signature and a `--replay-corpus <case>` repro, cases sharing a
signature named as one root cause), then the usual divergences/quality
sections. `report DIR` prints the same corpus section for a replay
results dir, and replay rows are kept out of the happy-path coverage
metric and the per-module rates (a corpus case is not a generated happy
path). Exit code: **2** when a case regressed (a krikri bug, the same
meaning as a fuzz divergence), **1** when the corpus itself needs
attention (a drifted recording, a case that could not run, or a directory
with no cases in it), **0** when every case passed or was skipped as live.

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
`divergent` counts, a `batch` object (modes, duration, second-run flag),
`findings` grouped by module + mode + run + diff signature (each
with its playbooks and an example carrying mode/run, chaos/mutations, the
masked diff and ansible's first error), `state_divergent`/`state_findings` for
state-only divergences (kind `state`, with the state diff), `errors`, `not_applicable` (modules a
single-task local playbook cannot exercise), `happy_coverage` (attempted/
failed/succeeded/`success_percent`), and per-module `rates`. Exit code is
unchanged (0 none, 2 divergences, 1 gate/failure); warnings stay on stderr.

Every `run` also writes `versions.txt` next to `results.jsonl` — a
best-effort provenance record (tool version, run start time, krikri
binary path/mtime/`--version`/git commit + subject, ansible-playbook
version, control flag, modes, idempotency flag, batch duration) parsed
by krikri-role-triager, including a warning line when the krikri binary
is older than its checkout's last commit touching build inputs.

Without `--run-on-podman`, `run` executes locally and defaults to Ansible
`--check` mode (no real host mutation) since happy-path tasks are real
modules that would otherwise install packages, create users, etc. on the
machine running this tool; pass `--allow-mutation` to run for real
without podman, once you have your own disposable host to point it at.
`--run-on-podman` also works on `run` alone, to re-run an
already-generated `--out` directory. `run --replay-corpus DIR` replays a
curated corpus of past divergence repros instead of a fuzz batch (see
"Corpus replay" below). `--modes` chooses the mode matrix
and `--no-second-run` skips the idempotency pass; Triage's repro command
pins `--modes` (and `--no-second-run` for a run-1 finding) so it
reproduces exactly the row it reports.

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
per playbook via `PodmanBackend` (ansible-core 2.21.6 and the pinned
collection versions asserted) — and
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
reference engine. v0.0.12 added cached podman template images, and the
v2 multi-task generator (`--tasks-per-playbook`, register/when chains,
loops, handlers) shipped on top. See `AGENTS.md`'s "Known gaps" for
what's deliberately not built yet (non-builtin module scope).

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
