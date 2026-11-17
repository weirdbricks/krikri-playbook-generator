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

## Re-fuzzing after a fix

Docs live in `README.md` ("Re-fuzzing after a fix") and the cheap recipe
is `just refuzz <module> [count]`: one small batch with every adjacent
axis enabled (both delegation spellings drawn per playbook, blocks,
handlers, retries, include forms, gather_facts), run and reported.
krikri-loop's fix workflow is expected to gate a KPG-derived fix on that
checklist before closing the issue.

## Architecture

- `src/krikri_playbook_generator/schema.cr` — `OptionSchema`/`ModuleSchema`
  plus `SchemaScanner`. **Implemented**: shells out to the real, installed
  `ansible-doc -j` for each module's option schema (type/choices/required/
  default/elements/suboptions — exactly what real ansible-playbook
  validates arguments against, no YAML re-parsing of our own) and to
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
  `GeneratedTask` (args + mutation metadata + optional v2 wiring:
  `when_condition`/`loop_option`/`loop_items`/`notify`), `Generator#generate`
  and `Generator#generate_scenarios`.
  **Implemented (v0.0.8, rewritten)**: the happy path is now a *runnable*
  valid baseline, not just schema-valid: path-typed options point at
  pre-seeded fixture files (`Fixtures` — read-only sources under
  `/opt/kpg-fixtures`, writable dests under `/tmp/kpg-work`; nothing the
  generator emits touches paths outside those two roots), `mode`/`owner`/
  `group`/`validate` and other practical traps come from a per-module
  override table (`src/krikri_playbook_generator/data/module_overrides.yml`,
  where owner/group render as `{{ kpg_owner }}` / `{{ kpg_group }}`,
  resolved per run to root or the nonroot account because a non-root task
  cannot chown to root, and the mode pool includes 0440/0400/0444,
  embedded at compile time, easy to extend — kinds: `mode`, `owner`,
  `group`, `validate`, `source_path`, `work_path`, `work_dir`, `username`,
  `literal_pool`, `empty_dict`, `exclude`, plus module-level `always`,
  `free_form`, `require_one_of`, `expect_failure` and `not_applicable`;
  a dict option's suboption is keyed by its qualified name, e.g.
  `subcommands.path`, and nested options never fall back to the bare-name
  table), `choices` are respected, ints stay in sane
  ranges (0–100). `SchemaScanner` also keeps a dict option's `suboptions`
  (from `ansible-doc -j`), so a `type: dict` option and every
  `type: list`/`elements: dict` element are built as a dict of their
  required suboptions instead of a bare word (which real ansible rejected
  with "dictionary requested, could not parse JSON or key=value"); nested
  path suboptions get an element-indexed `/tmp/kpg-work` path so
  list elements stay distinct. An enum option never samples its destructive members
  while a working one exists: the documented default wins when it is a
  choice, then a constructive member (`present`, `started`, `mounted`,
  `enabled`, `running`, `latest`, `installed`, `directory`, `touch`), then
  any member that is not destructive (`absent`, `stopped`, `unmounted`,
  `disabled`, `purged`, `removed`, `uninstalled`), and only a module whose
  every choice tears state down is sampled uniformly — so a happy path no
  longer runs `state: absent` half the time. Chaos is untouched
  (`BadChoice` still picks any member). Where each argument's value came
  from (`default`/`constructive`/`override`/`random`) is recorded per task
  in the playbook sidecar as `choice_sources`, minus the slots a chaos
  mutation replaced. After value assignment, a fill never introduces a
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
  Delegation is a separate axis (`--delegation off|literal|templated|both`,
  default both): a generated task gets `delegate_to` to
  `Generator::DELEGATE_HOST` (the second inventory alias) or to the
  `{{ kpg_delegate }}` play variable, plus `delegate_facts` half the time.
  It is structural wiring, recorded in the sidecar, never a chaos
  mutation; include/import actions are left undelegated because their
  target resolves at parse time.
  Deterministic per seed (`Random::PCG32`);
  every mutation is recorded in `GeneratedTask#mutations`, never applied
  silently. `generate_scenarios(schemas, per_playbook, count)` is the v2
  multi-task entry point: per scenario it samples up to `per_playbook`
  DISTINCT module schemas that all share one host profile
  (`Dependencies.host_profile`), builds one task each through the same
  baseline+chaos
  path, then wires the chain — every task except a static import registers
  `kpg_task_<i>` (the builder writes it), tasks after a registering one get
  a `when:` on its register (`is succeeded` / `is not skipped`), a task
  whose baseline args point at a fixture source file gets that argument
  templated as `{{ item }}` with a `loop:` over the whole fixture source
  list, and tasks roll a `notify:` on a shared play-level handler. Wiring
  is structural: recorded in the sidecar as wiring, never as a chaos
  mutation. Two action families constrain that wiring: `import_tasks` /
  `import_role` are static (ansible splices their contents in at parse
  time, so a `register:` there creates no variable and the next `when:`
  would be undefined), and `include_tasks` / `include_role` reject
  `notify:` outright. `GeneratedTask#static_import?` and
  `#notify_allowed?` carry that.
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
  if that fails (e.g. `/opt` not writable). It also owns the identity
  half: `IDENTITY_SCRIPT` provisions the `kpg` account with passwordless
  sudo into every isolated host (podman template and microVM golden), and
  `ownership_command(user)` re-owns the writable work root for the row's
  identity before the first snapshot, so root and nonroot rows start from
  identical fixture state without a profile-specific image.
  Content shapes are real too: `BINARY_FILE` (a small file with NUL bytes
  and a 0xff byte, so copy/slurp/--diff meet non-text content),
  `NO_NEWLINE_FILE` (no trailing newline), `RICH_TEMPLATE` (literal text,
  `{{ }}` expression, `{# #}` comment and a `{% if %}` statement block,
  all of which the template module renders and both engines must agree
  on) and `MIXED_TREE` (files AND directories at several depths under the
  writable root, so find/stat traversal has an ordering shape). The same
  script seeds them in both containers/goldens, and they are offered
  through `SOURCE_FILES` and the copy/template/slurp/stat/find pools.
  It also seeds the destination STATE production playbooks meet:
  `UNUSUAL_FILES` (0444/0400/0440 locked files in the writable work root,
  where both engines can still replace them by atomic rename, so the
  compared behavior is replace-vs-write and the mode left behind),
  `UNUSUAL_DIRS` (0600/setgid/sticky directories reachable through
  `WORK_DIRS` for chdir-style options) and the read-only PARENT
  `READONLY_DIR` that makes a nonroot row fail with the permission error
  and its staging-file report. `RESTORE_UNUSUAL_SCRIPT` recreates all of
  them and is part of `ownership_command`, so every row and both engines
  start from the same unusual modes even after an earlier run rewrote one.
- `src/krikri_playbook_generator/play_keywords.cr` — `PlayKeywords`,
  `PlaySetting` and `PlaySettingSampler`. **Implemented**: the play-level
  keyword axis. One keyword is drawn PER PLAYBOOK from
  `strategy`/`serial`/`throttle`/`any_errors_fatal`/`run_once`/
  `max_fail_percentage`/`gather_facts`/`connection`/`forks`, and exactly
  one is set: ansible warns that the free strategy ignores
  run_once/any_errors_fatal/max_fail_percentage, so mixing them would
  mostly test the warning. Happy paths draw a value ansible accepts; a
  chaos playbook draws a value it must reject (or a strategy/connection
  name with no plugin), so the delta under test is play-level validation.
  `forks` has no play-level spelling, so it is env-only, and `strategy`
  can arrive either as a play key or as `ANSIBLE_STRATEGY=...`; the
  sampler draws that door 50/50 so the two code paths are separate
  playbooks (a fix verified on one form must not hide the other). The
  draw is deterministic per seed but uses its own RNG, so it never shifts
  the task-argument draws (and vice versa).
- `src/krikri_playbook_generator/block_shapes.cr` — `BlockShape`,
  `BlockShapes` and `BlockShapeSampler`. **Implemented**: the block axis
  (`--blocks rescue,always,skipped,undefined`, `none` off). A shape wraps
  the generated task in `block:` with `rescue:`/`always:` debug tasks and,
  except for the `always` shape's success path, a deterministic forced
  failure (`command: /bin/false`, `changed_when: false`) so the failure
  path is part of the playbook rather than a chaos mutation. `skipped`
  gates the block on `kpg_block_gate | bool` with the play defining it
  false; `undefined` gates it on the same name with nothing defining it,
  so the conditional-error path is compared. One shape is drawn per
  single-task playbook (its own seeded RNG, so it never shifts the other
  draws) and recorded as `block` in the sidecar. Multi-task playbooks keep
  their flat list: wrapping one task would shift the register/when chain.
- `src/krikri_playbook_generator/handler_shapes.cr` — `HandlerShape`,
  `HandlerShapes` and `HandlerShapeSampler`. **Implemented**: the handler
  axis (`--handlers failing,ignoring,delegated,chained`, `none` off), one
  shape per playbook: a handler whose command exits non-zero (fails the
  play, so the recap's failed count is compared), the same failure with
  `ignore_errors: true` (the `...ignoring` line and the ignored count), a
  debug handler delegated to the second alias, or a two-handler notify
  chain. A deterministic always-changed `Kpg notifier` task
  (`command: /bin/true`, `changed_when: true`, ignored) notifies the
  handler, so it really runs whatever module the playbook exercises; the
  module task itself has no `notify:`. Shape is drawn with its own seeded
  RNG and recorded as `handlers` in the sidecar.
- `src/krikri_playbook_generator/retry_shapes.cr` — `RetryShape`,
  `RetryShapes` and `RetryShapeSampler`. **Implemented**: the retry axis
  (`--retries retried,exhausted,delegated,delegated-fact`, `none` off).
  `Fixtures::RETRY_SCRIPT` is a command that fails twice and succeeds on
  its third run (it counts attempts in `Fixtures::RETRY_COUNTER` under the
  writable work root, so a fresh pair starts at zero);
  `Fixtures::RETRY_NEVER_SCRIPT` never succeeds. The shapes add a
  registered retry task with `retries`/`delay: 0`/`until: kpg_retry.rc ==
  0` (so the RETRYING lines and the final result are compared), the
  never-satisfied variant (attempts count and failure shape), the retried
  command delegated to the second alias plus a probe of its attempts, and
  a `set_fact` retried with `delegate_to` + `delegate_facts` followed by a
  probe that reads the fact out of the delegate's hostvars. Recorded as
  `retries` in the sidecar.
- `src/krikri_playbook_generator/include_shapes.cr` — `IncludeShape`,
  `IncludeShapes` and `IncludeShapeSampler`. **Implemented**: the
  include/import axis (`--includes relative,role-vars,role-inner,loop-tasks,
  loop-role,import-playbook,import-role`, `none` off), one shape per
  playbook. `relative` writes `<playbook>-inc/a.yml` (which includes
  `b.yml` relatively) beside the playbook and includes it by a
  playbook-relative path, so every backend copies that sibling directory
  along (podman `cp`, microVM/Atlantic `scp -r`); `role-vars` includes the
  fixture role with task-level `vars:` (the role's debug prints its
  defaults/vars, so precedence is observable); `role-inner` uses
  `tasks_from: inner`, and the role's own tasks include `inner.yml` and
  `nested.yml`, so role-relative includes are exercised; `loop-tasks`
  loops `include_tasks` over two fixture task files; `loop-role` loops
  `include_role`; `import-playbook` adds a second top-level
  `ansible.builtin.import_playbook` item pointing at
  `Fixtures::CHILD_PLAYBOOK`; `import-role` uses the short `import_role`
  spelling. Recorded as `includes` in the sidecar.
- `src/krikri_playbook_generator/playbook_builder.cr` — `PlaybookBuilder`.
  **Implemented**: two shapes. v1 (the default, `build`) is
  single-task-per-module playbooks (one play, one task, `hosts: all`,
  `gather_facts: false`, `register:` + `ignore_errors: true` so a batch
  keeps going past individual failures). v2 (`--tasks-per-playbook N`,
  `build_scenarios`) assembles one play of N tasks from N DIFFERENT
  modules, every task except a static import registering `kpg_task_<i>`,
  tasks after a registering one gated by `when:` on its register, a
  fixture-source argument iterated via `loop:` + `{{ item }}`, and tasks
  that accept it `notify:`ing a shared play-level `ansible.builtin.debug`
  handler (the handlers section only appears when some task notifies) —
  the multi-task interaction fuzzing the proposal deferred to v2. Each
  `<n>-<module>-happy|chaos.yml` (v2
  names `<n>-multi-<first module>-happy|chaos.yml`) gets a sibling
  `<n>-...meta.json` (module/collection/chaos?/mutations/choice_sources) since the
  playbook YAML alone doesn't say which slots were mutated or how; a
  play-level keyword additionally appears as a typed play key (bools and
  numbers stay scalars) and, in the sidecar, as a `play` object
  (`keyword`/`value`/`source`/`env`) — an env-var variant writes NO play
  key, so the `env` map is the only place it can live. A delegated v1 task
  writes `delegate_to`/`delegate_facts`, defines `vars: {kpg_delegate:
  target2}` for the templated spelling, and appends two probe tasks
  (`debug: var=ansible_host` and `var=ansible_delegated_vars`, both
  repeating the same `delegate_to` because that variable only exists
  inside a delegated task); the sidecar records `delegate_to`/
  `delegate_facts`. v2 keeps delegation on each task itself and records
  it in that task's `wiring` instead, since extra probe tasks would shift
  the register/when chain. Every play targets the `kpg_targets` group
  (never `all`), so `HostInventory` can keep delegate-only aliases in the
  inventory without turning them into play hosts. For v2
  the sidecar keeps the FIRST task's module as top-level `module` (runner
  profile selection and Triage keep working unchanged), aggregates all
  tasks' mutations with `t<i>:` prefixes, and adds a `modules` array with
  each task's own module/chaos/mutations/choice_sources/wiring — `Triage`
  reads this back.
  The playbook YAML is rendered by `PlaybookBuilder` itself instead of
  Crystal's `YAML::Any#to_yaml`, which puts a sequence item at the same
  column as its key (`tasks:` followed by `- name:`), something ansible-lint
  reports as `yaml[indentation]`. Scalars still come from libyaml (same
  quoting and escaping; multi-line folding only gets re-indented), and every
  play/task/handler name starts with an uppercase letter for `name[casing]`
  (`HANDLER_NAME` lives in `generator.cr` so a `notify:` target and the
  handler it names can never drift apart). Linting a generated playbook
  should therefore only report what the fuzzing itself injects
  (`args[module]` for chaos mutations) plus the safety-profile heuristics
  (`risky-file-permissions`, `risky-octal`).
  Verified live: a generated chaos playbook fails against real
  `ansible-playbook --check` with exactly the mutation the generator
  recorded (a `mutually exclusive` error matching a real
  `ViolateConstraint` mutation).
- `src/krikri_playbook_generator/host_state.cr` — `HostState`. **Implemented**:
  the state half of the oracle. `SNAPSHOT_SCRIPT` (GNU find/`sha256sum`,
  LC_ALL=C sorts, no timestamps) lists `/etc`, `/tmp/kpg-work`,
  `/var/spool/cron` and `/root` with type/uid/gid/mode/size plus a sha256
  for files under 1 MiB, the boot id, dpkg/rpm package versions, enabled
  systemd units and listening sockets from `/proc/net/*`; containers and
  VMs both run it as root, so no extra tooling is needed. `Snapshot.parse`
  tolerates a truncated capture; `canonical` is the deterministic stored
  form and `changes` turns a before/after pair into one sorted line per
  added/removed/changed file, hash, package, unit or port (plus
  `boot rebooted`). Only changes are compared: the real and krikri images
  start from different baselines (`/root/.ansible`, pip caches), so
  comparing absolute state would flag the images themselves.
  `EXCLUDED_PATHS` (`/etc/hostname`, `/etc/hosts`, `/etc/resolv.conf`,
  `/etc/machine-id`) are per-host files each container/VM regenerates for
  itself; excluding them is the documented blind spot, same discipline as
  `ByteDiff::MASKS` (a module that edits one is invisible to this oracle).
  `check_mode_changes` applies the `--check` contract on top of the same
  snapshots: each ENGINE's own delta must be empty, so two engines that
  agree on a mutation are still both reported, and the only tolerated
  residue is `CHECK_MODE_IGNORED_PATHS` (`~/.ansible`, already pruned).
  `check_mode_signature` keys those findings by the engine that broke the
  promise. A `temps` section scans the same roots plus `/tmp` for the
  engines' staging prefixes (`TEMP_PATTERNS`) and is pruned out of the
  files/hashes scans, so `leftover_temps` reports a temp or partial write
  a failed task never cleaned up exactly once, as one `temp` change.
  Neither engine keeps a staging file on any path it controls, so
  `CHECK_MODE_IGNORED_PATHS`/`~/.ansible` stays the only tolerated
  residue.
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
  `ignore_errors`). Podman and microVM runs also compare HOST STATE via
  `HostState` (`host_state.cr`): each engine's host is snapshotted before
  and after its run (file tree under `/etc`, `/tmp/kpg-work`,
  `/var/spool/cron` and `/root` with type/uid/gid/mode/size and a
  sha256 for files under 1 MiB, boot id, package list, enabled units,
  listening ports), and the two before/after DELTAS are diffed — only
  deltas, because the real and krikri images' absolute state differs by
  construction. A delta mismatch is `state_divergent` with its own
  `state_signature` (`state:`-prefixed) and `state_diff`; per engine
  results.jsonl keeps `state_after`, `state_digest` and `state_changes`.
  A check-mode row also records `check_mode_mutated` and
  `check_mode_diff` (each engine's unexpected check-mode delta, engine
  labelled) and counts as divergent on its own: `--check` must not change
  the host even when both engines change it the same way. Every row also
  records `leftover_temps` when an engine left a staging file behind:
  the file plus `(task: <name>)` from `Runner.last_failed_task` (the last
  `TASK [...]` that printed a `fatal:` line, since `ignore_errors: true`
  keeps the batch going). A matched delta with a survivor on either side
  still becomes a state finding, using the leftover text as its diff.
  Local and Atlantic runs capture no state (locally the two engines share
  one live host, so a delta cannot be attributed to one engine).
  Every playbook is compared once per MODE (`RunMode::Check` and
  `RunMode::Real`): both by default on an isolated backend, check-only
  locally unless `--allow-mutation`, always real on Atlantic. It is also
  compared once per identity, umask and host count (`--user-profile`,
  `--umask`, `--hosts`): each row gets its own fresh host/pair and records
  `user`, `umask` and `hosts` in results.jsonl, and the context is part of
  the progress/summary labels; local rows are always the invoking account
  and Atlantic rows are always root. The `--limit` axis (`off`/`none`/
  `one`/`group`/`unreachable`/`negative`, default off) runs each row with
  its ansible pattern on both engines; for any row of that axis the
  inventory's play group also contains `kpg_unreachable` (loopback with a
  closed port, so contact is refused instantly), which is how an
  out-of-limit host being contacted becomes observable, including during
  implicit fact gathering (`--gather-facts`). Rows record `limit` in
  results.jsonl and Triage groups and repro-pins it. The host-count axis
  (`HostInventory`, 1/2/3) writes an inventory whose `kpg_targets` group
  holds that many LOCAL aliases (`target`, `target2`, `target3`); the
  remaining aliases stay in the inventory as delegate-only hosts, so a
  delegated task resolves even on a one-host row. It is written into the
  fresh pair — podman and
  microVM rebuild it per row, Atlantic once per VM (so it takes a single
  count), and local passes a temp inventory file (a one-host row keeps the
  historical implicit `localhost,` invocation). All aliases are the same
  machine, so the axis compares per-host task execution, recap host lists
  and `included:` grouping, not a second host's state. Each
  (playbook, mode) gets its own fresh host/pair, so real-mode state can
  never leak into the check row; each row records its `mode` in
  results.jsonl, and Triage groups by module + mode + run + signature so a
  check-mode-only divergence is reported once, not twice. When the first
  run of a (playbook, mode) succeeded on BOTH engines
  (`HostState.succeeded?`), the backends run it a SECOND time on the same
  host/pair: the idempotency pass, whose comparison is its own row with
  `run: 2` so first-run findings stay attributable. `--no-second-run`
  disables it; local does the same on its shared host, while Atlantic
  skips it (playbooks share one VM per profile). `Runner.in_parallel` is
  generic over the block's result so the mode matrix can return several
  rows per playbook.
  Backends: local (`--check` by default unless
  `--allow-mutation`; engines wrapped in `timeout`; fixtures seeded
  best-effort on the host), podman (`--run-on-podman`, fresh container
  pair per playbook via committed template images; REAL by default,
  `--check` appends `--check` and every batch passes `--diff` unless
  `--no-diff`, identically on both engines) and Atlantic.net
  (`--run-on-atlantic`, one disposable VM per module profile, always
  real - it refuses `--check` - and `--diff` like the other backends).
  Every backend strips the same engine environment
  (`KrikriPlaybookGenerator::ENGINE_ENV_STRIP`: no ANSIBLE_GATHERING, no
  fact-cache plugin/connection, ANSIBLE_NOCOLOR=1) — local runs included,
  because an inherited `ANSIBLE_GATHERING=smart` plus a populated cache
  silently skips implicit gathering on the real engine and would turn a
  machine-local cache into a finding.
  A playbook's env-var play keyword (ANSIBLE_STRATEGY/ANSIBLE_FORKS) is
  read from its sidecar `play.env` and exported identically for both
  engines by every backend (podman/microVM/Atlantic command construction,
  local's inner bash); results.jsonl and the repro command carry it too,
  since the playbook file cannot.
  `MetaInfo` carries `module_names` (every task's module for a v2
  multi-task playbook, falling back to just the primary one for v1
  sidecars) and `env` (the sidecar's play-level env mapping): podman picks
  the Rpm profile when ANY task needs it, the
  Atlantic grouping requires a profile for EVERY task's module, the local
  supported-community check covers every task, and the podman
  dependency-union list includes every task's fqcn. results.jsonl gains a
  `modules` array for multi-task playbooks (`module` stays the primary).
  `--keep-going` turns
  per-playbook failures into errored results instead of aborting the
  batch; errored results are never counted as divergent.
  `--atlantic-hosts` caps how many Atlantic VMs run concurrently.
  `--podman-parallel N` runs that many playbooks at once on the podman
  path (`Runner.in_parallel`): Cmd.run yields while podman works, so the
  fresh container pairs overlap without threads; each playbook is still
  one isolated pair, results come back in batch order, and a failure
  without `--keep-going` stops the workers from picking up more playbooks
  and is re-raised after they have all stopped, so teardown still runs.
  On this workspace 2 nearly halves the wall time of a 4-playbook debug
  batch (51s serial vs 30s, both with the template cache hit).
- `src/krikri_playbook_generator/versions.cr` — `Versions`. **Implemented**:
  writes `<results_dir>/versions.txt` (called from `Runner#run`, right
  after results.jsonl) — a best-effort provenance record parsed by
  krikri-role-triager, which splits each line on the first `": "`. One
  `key: value` line each: tool version, run start (RFC3339 UTC), krikri
  binary path/mtime/`--version`/git commit (+ ` (dirty)`)/commit subject,
  ansible-playbook version, `control`, `modes:` (the mode matrix, e.g.
  `check,real`), `idempotency:` (whether the second-run pass was on),
  `diff:` (whether both engines got `--diff`) and `batch duration:`. `check: true` appears only when the batch ran check
  mode and nothing else, keeping the old contract for
  krikri-role-triager (how it tells a `--check` repro run from a real
  one) while a mixed-mode batch is no longer mislabeled. Plus, only when
  the krikri
  binary's mtime is older than the committer date of the checkout's last
  commit touching `src lib plugins scripts shard.yml shard.lock
  build.sh`, the exact line `warning: krikri binary is older than its
  checkout's last build-input commit`. Every probe is best-effort (30s
  timeout, `"unavailable"` on failure, never fails the run); the command
  runner is injectable as a `Proc` so the spec can fake it.
- `src/krikri_playbook_generator/microvm_backend.cr` — `MicrovmBackend`.
  **Implemented**: the local KVM backend for modules a plain container
  cannot host (db, docker/podman, zfs/snap/rabbitmq/libvirt/nsupdate,
  firewalld/SELinux). It bakes ONE golden per OS — Ubuntu 24.04 minimal
  and Rocky 10 cloud images — keyed by the dependency table's package
  union plus the profile prep (`fingerprint`), installs the pinned
  ansible-core and the collections the real engine needs (`collection_pins:`
  in `module_dependencies.yml` decides their versions, and the bake asserts
  the resolved copy matches, the same way the ansible-core version is
  asserted), then boots two
  throwaway qcow2 overlays per playbook (one VM per engine, so no state
  can leak between the engine runs) on `127.90.<slot>.1/.2` with sshd
  published on 2422 and stages the krikri binary over scp. A slot is
  reserved across processes with an `flock(2)` on
  `<microvm dir>/slots/<slot>.lock`, held for as long as the pair is up
  (`MicrovmBackend#acquire_slot`): the number used to be a per-process
  counter starting at 0, so two kpg processes (a fix-issues verification
  and the loop's own batch) both booted their first pair on 127.90.1.1 and
  the second qemu died on its hostfwd rule. A bake takes the same dir's
  `bake.lock` for the same reason - its boot and verify use one fixed
  address - and re-checks the golden's `.ok` marker once it holds it.
  The golden's prep also bakes the `kpg` account (`Fixtures::IDENTITY_SCRIPT`,
  part of the fingerprinted prep), and each playbook row's fixture ownership
  is fixed before the first snapshot; `--user-profile nonroot` starts the
  engine through `runuser -u kpg -- env HOME=/home/kpg bash -c ...`, and
  every engine command carries the row's umask and
  `-e kpg_owner=... -e kpg_group=...`. `--run-on-mixed`
  routes a batch here per playbook (`MicrovmBackend.microvm_only?`) and
  keeps everything else on podman; `--run-on-microvm` forces it for the
  whole batch. A golden without its `.ok` marker is discarded and re-baked
  (a bake that died leaves the file behind). The verify boot also imports
  the golden's zfs pool: its backing file lives under `/var/lib/kpg-zfs`,
  never `/tmp` (Ubuntu's tmpfiles rule empties that at every boot, which
  silently wiped the pool and made every zfs happy path fail on real
  ansible). A pool the bake never created only warns, so the rest of the
  profile still works. Missing optional packages
  warn instead of failing the bake, so one bad entry cannot cost the whole
  profile; a bake whose installs leave the root at 95% or more raises a
  disk-full error instead of letting the missing pip3 surface as a cryptic
  ansible-core install failure. The Ubuntu golden's disk is grown by
  `GOLDEN_EXTRA_GB` (8G) before its first boot because Ubuntu's minimal
  image root (2.4G) cannot hold the profile (every package from gcc on
  failed with no room left); cloud-init's growpart resizes root, and the
  per-playbook overlays inherit the grown size. Rocky's 10G cloud image
  root needs no growth, and only an OS that grows keys its fingerprint on
  the size, so it keeps an already-baked golden. The golden is never
  shared with the role tester's backend (different image set, and its bake
  lock is per process).
- `src/krikri_playbook_generator/podman_backend.cr` — `PodmanBackend`.
  **Implemented (v0.0.8, rewritten for isolation)**: provisions ONE
  template pair from `docker.io/library/debian:trixie-slim`
  (`kpg-tpl-real-<ts>-<pid>`, `kpg-tpl-krikri-<ts>-<pid>`), installs
  `ansible-core` + a runtime-lib set in one, `podman cp`'s the
  `krikri-playbook` binary and its `plugins/` dir into the other, seeds
  the identical `Fixtures` tree into both, asserts the container's
  ansible-core version equals `EXPECTED_ANSIBLE_VERSION` (2.21.6) and that
  every pinned collection resolves to its `collection_pins:` version (the
  first copy in search order, since `~/.ansible/collections` outranks
  Debian's distro tree — fails loudly otherwise, as an argument spec ships
  with the collection version), then `podman commit`s the templates into a
  two-level content-addressed cache: `kpg-base-{real,krikri}-{debian,rpm}:<base
  fingerprint>` holds the package layer (a SHA-256 over the package sets,
  ansible-core pin, inventory and fixture seed script, deliberately not the
  krikri binary), and `kpg-img-{real,krikri}-{debian,rpm}:<fingerprint>`
  adds the binary + plugins digests. A full cache hit skips provisioning
  entirely; when only the base pair exists (every loop cycle rebuilds
  `krikri-playbook`) the pair starts from it and just the binary layer is
  committed, so a 27 MB binary change no longer costs a 3-6 minute apt
  install plus a ~600 MB commit. `--refresh-podman-templates` rebuilds from
  the base image and prunes the stale tags. Every `run_playbook` call starts a
  FRESH pair from the committed images for the playbook's OWN profile
  (`kpg-real-<n>…`, `kpg-krikri-<n>…`; the per-profile image pairs are kept
  in a map, so a mixed Debian/rpm batch never runs apt modules on Rocky),
  copies the playbook into both, and execs each
  engine with the identical invocation (`bash -c "cd /work && env -u
  ANSIBLE_GATHERING -u ANSIBLE_CACHE_PLUGIN -u
  ANSIBLE_CACHE_PLUGIN_CONNECTION ANSIBLE_NOCOLOR=1 timeout <N>
  <engine> -i inventory.ini /work/<basename> </dev/null>"` - a check-mode
  run inserts `--check` and every run `--diff` (unless `--no-diff`), right
  after the engine command on both sides, so diff output is compared
  byte-for-byte like the rest of stdout); the pair is
  `podman rm -f`'d in `ensure` immediately after. The invocation also
  carries the row's umask and `-e kpg_owner=... -e kpg_group=...`; under
  `--user-profile nonroot` it runs via `podman exec --user kpg:kpg -e
  HOME=/home/kpg`, and the writable fixture root is re-owned for that row
  before the first snapshot (so the chown never shows as a mutation). The
  template bakes the `kpg` account in, and its script is part of the base
  fingerprint, so an old cache without the account is not reused.
  `teardown` removes
  remaining containers but KEEPS the committed images (they are the
  cache the next run starts from); `PodmanBackend.leak_check`
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
  playbooks by `{module, mode, run, hosts, limit, signature}` — the stable root-cause hash
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
  second-run rows (`run > 1`: repeatability, not runnability),
  `expect_failure` and `not_applicable` modules; `not_applicable_modules`
  reports the exclusions so they stay visible. `rates` gives per-module
  byte-identical counts (`masked_identical`, so a state-only divergence
  does not lower the byte rate).
  `report` only groups playbooks whose OUTPUT diverged
  (`output_divergent?`, i.e. not `masked_identical`), keyed on module +
  mode + run + identity + umask + signature (so a nonroot-only finding is
  separate); `state_report`
  groups state-only ones by their `state:`-prefixed `HostState` signature,
  so a playbook that differs on both is counted once (as an output
  finding) and one root cause never appears twice. State-only findings
  list their `state_diff` lines. The CLI prints them as their own
  `== State divergences ... ==` section and they still exit 2.
  `check_mode_report` groups rows whose `--check` run changed its host,
  by their `check-mode:`-prefixed signature (engine included, paths
  generalized); a row that also diverges on output or is already a
  state-only finding is counted there once, never twice, and the CLI
  prints a `== Check-mode mutations ... ==` section that still exits 2.
  Malformed lines and legacy lines missing `module` are skipped, a
  missing `results.jsonl` raises. `ResultLine` also keeps each line's
  masked diff (from results.jsonl's `diff.masked`) and error text, plus
  the state fields (`state_divergent`, recomputed `state_signature`,
  `state_diff`) and the check-mode fields (`check_mode_mutated`,
  `check_mode_diff`, recomputed `check_mode_signature`); a legacy line
  without `masked_identical` is treated as output-divergent.
  `report_json` renders the whole report as ONE JSON object (`report
  --json`): results_dir, total/errored/divergent/state_divergent/
  check_mode_divergent counts, findings, `state_findings` and
  `check_mode_findings` in the
  same grouping/order as `report` (each with playbooks and an example
  carrying mode/run/chaos/mutations/masked_diff/state_diff/
  leftover_temps/check_mode_diff/ansible_error and a `kind` of `output`,
  `state` or `check-mode`), a `batch` object (modes,
  duration, second-run flag read back from versions.txt), errors,
  not_applicable, happy_coverage, rates. The human report starts with the
  same `== Batch ==` line, and `Triage.repro_command` pins the finding's
  `--modes`, the identity/umask (`--user-profile nonroot`, `--umask N`)
  and the host count (`--hosts N` when above 1), plus `--no-second-run`
  for a run-1 row and `--no-diff` when the batch never compared diff
  output, and prefixes a row's env-var play keyword
  (`ANSIBLE_STRATEGY=... `) so an env variant reruns the same playbook;
  that way a repro reruns exactly
  that comparison.
- `src/krikri_playbook_generator/options.cr` — CLI parsing for the four
  subcommands (`generate`, `run`, `report`, `modules`), plus `--check`
  (run only the check-mode half; conflicts with `--run-on-atlantic` and
  `--allow-mutation`), `--modes check|real|both` (the mode matrix;
  default both on isolated backends, check locally unless
  `--allow-mutation`; `Options.effective_modes` refuses real mode
  locally without `--allow-mutation` and check mode on Atlantic),
  `--user-profile root|nonroot|both` and `--umask LIST` (the identity and
  umask matrix, default root/022; `--user-profile` needs an isolated
  backend, Atlantic takes one umask), `--no-second-run` (skip the
  idempotency pass, on by default),
  `--diff`/`--no-diff` (both engines get `--diff` by default, on every
  backend, because diff output is user-visible behavior; nothing about it
  is masked),
  `--keep-going`,
  `--engine-timeout` (per-engine timeout in seconds; a hung engine is
  recorded with rc 124), `--json` (valid only with `report` or `modules`;
  error
  otherwise), `--min-happy-success PCT` (the happy-path success gate;
  valid with `report`, or a `generate` that runs a backend),
  `--podman-parallel N` (playbooks run N at a time on podman, each in its
  own container pair; default 1 = the serial batch; needs
  `--run-on-podman`) and
  `--tasks-per-playbook N` (v2 multi-task playbooks; default 1 = the v1
  single-task shape; needs at least 2 scanned modules, otherwise
  `generate` falls back to single-task with a logged warning) and a seed
  that is RANDOM by default — the default was fixed at 42, which meant
  every seedless batch replayed identical playbooks forever; the
  playbook files are the repro artifact anyway, so each one now carries
  `# krikri-playbook-generator seed=<N>` as its first line and the log
  echoes the effective seed, with `--seed N` still forcing a known one. Both
  `run <dir>` and `report <dir>` accept that
  directory as a positional argument (falling back to `--out`/
  `--results-dir` otherwise), and `run <file.yml>` accepts a single
  playbook path (the repro form Triage prints), matching the CLI sketch
  in `KRIKRI_PLAYBOOK_GENERATOR.md`. `--chaos-kinds` accepts
  `typo`, `hallucinate`, `wrong-type`, `bad-choice`, `violate-constraint`
  and `jinja`. `--hosts LIST` (1/2/3, default 1) is the host-count
  matrix; `--play-keywords LIST` selects the play-level keyword axis
  (`none` disables it); `--delegation off|literal|templated|both` is the
  delegate_to axis; `--blocks LIST` wraps single-task playbooks in a
  block shape; `--handlers LIST` picks the handler shape; `--retries LIST`
  picks the retry shape; `--includes LIST` picks the include/import form.
  All six are generate-only.
- `src/krikri_playbook_generator.cr` — entrypoint, dispatches on
  `Options.parse(ARGV).command`. `Command::Report` prints the full
  report: divergences grouped by module + mode + run + identity + umask +
  diff signature (with count, mutations, example playbook and repro
  command pinning `--user-profile`/`--umask`), the state-only
  divergences (state signature, example and the changed state lines),
  the check-mode mutations (engine-labelled signature, example, repro and
  the mutated paths),
  the generator-quality
  section (batch happy-path success rate, per-module failures on real
  ansible with first error line, expected-failure and not-applicable
  exclusions), and per-module byte-identical rates. `Command::Generate` fuses the
  whole pipeline into one call when `--run-on-podman` is passed: after
  building the playbooks (still written to `--out` for later review
  either way), it immediately runs them via `Runner` with
  `run_on_podman: true`, prints one `[DIVERGENT]`/`[ERROR] <path>`
  line per failing playbook (an identical one already shows `(ok)` in
  the runner's completion line, so it is not repeated), then the full
  report. Exit code is
  2 iff divergences exist (for `generate --run-on-podman`, `run`,
  and `report`); a `--min-happy-success` gate violation exits 1, as do
  tool errors. Plain `run` still supports
  `--run-on-podman` on its own, for re-running an already-generated
  `--out` directory; `--run-on-microvm` does the same with the local KVM
  backend, and `--run-on-mixed` splits the batch (podman unless a module
  needs a service/kernel). `Command::Modules` prints the default scope —
  ansible.builtin core plus the promoted `supported:` FQCNs, read from
  the same installed `ansible-doc` listing `scan` uses (`SchemaScanner.default_module_names`)
  — as one name per line, or one JSON array with `--json`. With
  `--scope-from-krikri` the listing also includes every module the
  `--krikri-bin` binary reports through its own `--list-modules`, filtered
  to what `ansible-doc` can actually scan; that is the scope krikri-loop
  uses, so the rotation follows the engine's registry instead of a
  hand-kept list. Modules the harness can never exercise (AWS credentials,
  macOS homebrew, krikri's internal `py_module`, and `import_playbook`,
  which is a play-level directive ansible does not accept inside a task
  list) are dropped by `SCOPE_EXCLUDED`; the bare `virt_net` alias is
  mapped to `community.libvirt.virt_net` by `SCOPE_ALIASES` so ansible-doc
  can find it.
  Exit code 0 (a failed `ansible-doc --list` is a tool error, exit 1).

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
- **Collection pin discipline**: `data/module_dependencies.yml`'s
  `collection_pins:` is the one place a collection version is chosen; both
  the podman and microVM paths normalize requirements to
  `name:==version`, put the string in the image/golden fingerprint, and
  assert the resolved copy after the galaxy install. A collection that is
  not pinned stays floating and unasserted — promote it there only when
  krikri's plugins target that exact spec, never to silence a divergence.
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
  The podman backend is the mirror image: real by default (it is
  disposable), and `--check` opts IN to check mode there — the check
  repro pass runs each playbook once real and once `--check` into
  separate results dirs, the check run marked by `check: true` in its
  versions.txt.
- **Podman is opt-in (`--run-on-podman`), never the default** — even
  though it's disposable and therefore safer than local mutation, it's
  slower to provision than a plain local `--check` run and needs `podman`
  installed; the person running this tool chooses when that tradeoff is
  worth it. Don't make `PodmanBackend.available?` alone flip the default.
- **Per-playbook isolation on the microVM path is a hard requirement too** —
  every playbook gets a fresh overlay per engine derived from the profile
  golden. Never reuse one VM for both engines: the first engine's files
  and services would be visible to the second, which turns an idempotent
  module into a false divergence. The goldens are keyed by the dependency
  fingerprint, so changing a module's packages or the prep rebakes exactly
  once; never bake per batch, or a six-module rotation pays minutes of
  bake per cycle.
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
  happy path, so widening that coverage means adding a profile. The local
  microVM backend (`--run-on-microvm`/`--run-on-mixed`) now hosts exactly
  those service modules for free, so Atlantic is only needed for
  infrastructure this machine cannot virtualize.
- Atlantic.net has no collection provisioning at all (only the pinned
  ansible-core), so its batches cover core modules and nothing that needs
  a collection; the pin/assert discipline described above lives in the
  podman and microVM backends. Widening Atlantic means installing the
  playbook's collections there with the same pins first.
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
- A playbook whose SHAPE deliberately fails (rescued forced failure,
  undefined block condition, failing/ignoring handler, never-satisfied
  retry) is marked `structural_failure` in the sidecar and excluded from
  the happy-path quality metric: that failure is the comparison under
  test, not wasted coverage. Its byte/state findings are still reported.
  A genuine module-task failure inside such a playbook is therefore not
  counted by the gate either - the divergence report is where it shows.
- The state oracle only runs on the podman and microVM backends. Local
  runs share one live host between the two engines, so a before/after
  delta cannot be attributed to one engine (and snapshotting the user's
  `$HOME` is not something a cheap `--check` batch should do); Atlantic
  reuses a per-profile VM across playbooks, so its state is not
  per-playbook attributable either. Widening it means giving those
  backends per-engine isolation first. The same limits apply to the
  check-mode read-only assertion, which is built on those snapshots and
  therefore also only runs on podman and microVM.
- A check-mode mutation is judged per engine against the `--check`
  contract, not against the other engine. A reference-ansible mutation
  (a module that ignores check mode) is therefore reported exactly like
  a krikri one, with the engine named in the finding's signature, rather
  than silently excused as "both did it".
- Leftover detection covers staging files (the engines' temp prefixes),
  not destination files. A destination one engine leaves and the other
  does not is caught by the ordinary state delta; a destination BOTH
  engines create and keep identically is treated as module output, since
  without per-task cleanup metadata the harness cannot tell a partial
  write from intended output. The `(task: ...)` owner is the last task
  that printed a `fatal:` line, so a module that fails several tasks can
  name the wrong one.
- The identity axis only exists on the podman and microVM backends: the
  shared local host runs as the invoking account (recorded as `local`)
  and Atlantic's VMs are only provisioned as root. The non-root HOME
  (`/home/kpg`) is outside the snapshot roots, so staging leftovers there
  are invisible to the state oracle; the writable work root is covered.
  Modules that genuinely need root (`user`, package installs) fail on the
  reference engine under the nonroot profile and show up as wasted
  coverage, not as divergences.
- The `--limit` axis proves out-of-limit contact through one pseudo-host
  with a refused loopback port; it does not model a slow network, DNS or
  authentication failure, and the per-host state oracle cannot attribute
  anything to that host (it never runs). The SSH transport profile is the
  issue that properly widens this.
- The host-count axis uses LOCAL aliases of one container/VM. It compares
  per-host task execution, recap host lists and `included:` grouping, but
  it cannot see transport, per-host state or real concurrency: all aliases
  are the same machine, serialized inside one engine process. The SSH
  transport profile is the issue that makes those real.
- Play-level keyword coverage stops at what the reference engine accepts:
  a custom `strategy_plugins/` plugin is not seeded (that is the strategy
  plugin issue), and the env variants are `ANSIBLE_STRATEGY`/`ANSIBLE_FORKS`
  only, since ansible exposes no env var for serial/throttle/
  any_errors_fatal/run_once/max_fail_percentage/gather_facts/connection.
- Multi-task interaction fuzzing (register/when chains, loops, handlers)
  is now BUILT (`--tasks-per-playbook N`) — but still one play per
  playbook (no multi-PLAY playbooks, no role plays), and the batch-level
  metadata (results.jsonl `module`, triage grouping, podman/Atlantic
  profile keys beyond the any-rpm rule) stays keyed on the FIRST task's
  module. `async_status` is only testable at all because `Fixtures` seeds
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
`play_keywords_spec.cr`, `block_shapes_spec.cr`, `handler_shapes_spec.cr`,
`retry_shapes_spec.cr`, `include_shapes_spec.cr`, `run_context_spec.cr`,
`playbook_builder_spec.cr`,
`fixtures_spec.cr`, `host_state_spec.cr`, `runner_spec.cr`,
`podman_backend_spec.cr`,
`triage_spec.cr`, `versions_spec.cr` (fakes the command runner as a Proc). `schema_spec.cr` shells out to
the real, locally-installed `ansible-doc`/`python3` — no fakes, since
tracking whatever ansible-core is actually installed is the entire point —
but skips exercising unfiltered discovery (`SchemaScanner.new.scan`, no
`--modules`), which would spawn two subprocesses per one of ~9000+
installed modules; verify that path live. `generator_spec.cr` also covers the delegation axis (off/literal/
templated/both, include/import skipped, never recorded as a mutation) and
builds a
small hand-written `ModuleSchema` fixture rather than going through
`SchemaScanner`, so it stays fast and doesn't depend on any particular
module's real constraints; it also covers the v2 scenarios (distinct
modules per scenario, when-chain register naming, the fixture-source
loop wiring, determinism, and the two ArgumentError guards).
`playbook_builder_spec.cr` parses the written
YAML back with `YAML.parse` and the sidecar with `JSON.parse` rather than
string-matching the file, including the v2 shape (register names,
when/loop/notify wiring, the conditional handlers section, the sidecar's
aggregated `t<i>:` mutations and per-task `modules` array, each task's
`choice_sources`) and writes
the generator's seed as a first-line comment when one is passed (the
random-by-default seed needs the file itself to carry it). Two specs guard
the lint-clean rendering: every play/task name starts uppercase, and a
nested sequence is indented under its key (the text is matched there, since
the rule is about layout rather than meaning).
`runner_spec.cr` unit-tests `Recap`/
`PlaybookResult#divergent?` directly, plus real integration cases (a
single-task `ansible.builtin.debug` — always safe/fast/idempotent — and a
v2 debug+stat multi-task playbook) that run both real
engines end to end and check `results.jsonl`'s shape — not a fake, same
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
chain end to end yet). `triage_spec.cr` also covers the state-only
findings, the check-mode findings (separate section, "counted once" rule,
engine-labelled signature grouping and the JSON kind), the "counted once"
rule and legacy lines without
`masked_identical`. `host_state_spec.cr` builds hand-written snapshot
fixtures and covers parsing/canonicalization (including a truncated
capture), the change list (mode, owner-visible fields, leftover file,
hash/content, package, unit, port and reboot), delta-vs-delta diffing,
the check-mode policy (per-engine delta, control-state keeper filtering,
signature stability) and the snapshot script's roots/exclusions,
`#temps` section and staging prefixes. `runner_spec.cr` covers the
leftover policy (the surviving file, the task the log blames, the
matched-delta fallback), `last_failed_task` itself, the umask matrix
rows + their `user`/`umask`/`limit` results fields, a real two-host row (both
engine outputs name `target2`, the recap has the host, the row records
`hosts: 2`) and an env-var play keyword reaching the engine (bogus
`ANSIBLE_STRATEGY` fails on real ansible, proving the export happened)
and landing in results.jsonl. `fixtures_spec.cr` covers the
role/HTTP fixtures plus `IDENTITY_SCRIPT`, `ownership_command`, the
unusual-mode destinations/directories, `RESTORE_UNUSUAL_SCRIPT`'s
idempotency, the retry fixtures' attempt counting, the include/import
fixtures and the content fixtures (binary NUL bytes, missing trailing
newline, rich template syntax, nested tree). `play_keywords_spec.cr` covers the kind list, valid vs
chaos value pools, determinism, env-only `forks` and the 50/50 env door;
`block_shapes_spec.cr`, `handler_shapes_spec.cr` and
`retry_shapes_spec.cr` and `include_shapes_spec.cr` cover the shape
lists, parsing and the seeded samplers, and `playbook_builder_spec.cr`
covers each shape's YAML (handler failure/ignoring/delegation/chain, the
notifier task, the v2 application, and no handlers when off)
(forced failure, rescue/always bodies, the block gate and its play var,
and the flat list when the axis is off);
`run_context_spec.cr` covers `HostInventory`'s aliases, the
`kpg_targets` group, delegate-only hosts and the unreachable host added
only for limit rows. `options_spec.cr` covers the identity/umask defaults, parsing,
normalization and target restrictions, the `--hosts` matrix/validation
(and Atlantic's single value), `--limit`'s symbols/patterns (and
Atlantic's single value), `--gather-facts`, and `--play-keywords`
(`none`, unknown values, generate-only); `triage_spec.cr` groups by
identity, umask and host count and pins them in the repro, and prefixes
an env-var keyword there. `podman_backend_spec.cr`
runs a real playbook as the provisioned nonroot account under umask 077
and asserts the observed file mode.
`masks_spec.cr` unit-tests the mask list, the
LCS diff and signature stability. `generator_spec.cr` also covers the
Jinja kind (the templated value must be equivalent to the baseline
value), the `empty_dict` override, the dict/list-of-dict suboption builds
(required keys present, per-element nested paths distinct),
`schema_spec.cr` the real `suboptions` parse (skipped when
community.general is absent), the mutually-exclusive-safe fills, and
the enum choice preference (documented default, then constructive, never
destructive while something else exists, plus the recorded
`choice_sources`).
`podman_backend_spec.cr` provisions BOTH profiles in its regression case
and asserts a Debian playbook still runs on the Debian image after the rpm
template was provisioned last (apt-get exists only there).
`overrides_spec.cr` covers `not_applicable` parsing. All temp-dir specs use `File.tempname`,
cleaned up in `ensure`.

`ameba` (1.7.0) is a dev dependency; run `crystal build lib/ameba/src/cli.cr
-o bin/ameba && ./bin/ameba` after `shards install` (no prebuilt binary is
shipped). Keep it clean — `crystal tool format .` first fixes most findings.
