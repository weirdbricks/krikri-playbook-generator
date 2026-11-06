# Plan: krikri-loop says hi to kpg v2 (kpg-only discovery)

Status: phases 1-2 built (2026-11-05) - kpg's `modules --json` subcommand, and the
loop's `--no-galaxy`/`--kpg-tasks` flags with the rotation sourced from that
listing (`kpg_modules_per_cycle` default bumped 3 -> 6). Phase 0 (a live v2 run
under the loop's invocation) and phases 3-4 (turning the dial, making
`--no-galaxy` the default) are still manual. Changes live in krikri-role-tester's
`src/krikri_loop/`; this doc lives in the generator repo because v2 multi-task
playbooks are what make kpg-exclusive discovery defensible.

## Why

krikri-loop (krikri-role-tester, `src/krikri_loop/loop.cr`) already runs kpg as step
"1k" before the Galaxy role rounds, and skips the role rounds for a cycle when kpg
alone files at least `min_divergences` (default 2) root causes (`kpg_discover`,
loop.cr:754). What it does not do is skip Galaxy *unconditionally*: a cycle where kpg
finds < 2 still spends the expensive role rounds (100 roles, VMs + podman). Now that
the generator's v2 multi-task shape is built (`--tasks-per-playbook N`,
register/when chains, loops, handlers — the coverage class Galaxy roles used to
provide alone), the loop can treat kpg as its primary — and only — discovery source,
with Galaxy rounds as an opt-in fallback instead of the default.

| source | root causes per run | cost |
|---|---|---|
| Galaxy role rounds | 6-8 | ~100 roles, VM/podman pools, hours |
| kpg41/kpg43 (podman, v1 shape) | 35 / 13 signatures | one-task playbooks, minutes each |
| kpg v2 (untested in the loop) | ? | N-task playbooks, same podman path |

## Current wiring (what exists)

- `Loop::Config` carries `kpg_bin`, `kpg_count` (10), `kpg_modules_per_cycle` (3),
  `kpg_chaos` (20), `kpg_modules` (a hand-duplicated 17-entry `KPG_MODULES` list,
  loop.cr:11-15), `kpg?` (true). CLI flags in `src/krikri_loop.cr`.
- `run_kpg` (loop.cr:330) invokes
  `kpg generate --modules <slice> --seed <epoch> --count N --chaos-percentage 20
  --run-on-podman --keep-going --krikri-bin <krikri>/bin/krikri-playbook`, writing to
  `kpg___<epoch>/`; the rotation offset persists in `<tester_dir>/.kpg-rotation`.
- `triage_kpg` (loop.cr:355) runs `krikri-role-triager --kpg <dir> --auto-mode`; its
  findings fold into the cycle's `min_divergences` count.
- `kpg_discover` returns early (skipping role rounds) only when kpg's group count
  reaches `min_divergences`.
- v2 exists in kpg (`--tasks-per-playbook`, default 1) but the loop never passes it,
  so every loop run is still the v1 single-task shape.

## Changes in krikri-loop

All small; no new tool, no new binary — the loop already owns fix-issues, the mask
pass, stats and pruning, and a second loop process would fight it for agent slots,
compile locks and podman/VM resources.

1. **`--no-galaxy` (kpg-only mode).** New `Config` flag (default false) + CLI flag in
   `src/krikri_loop.cr`. In `discover` (loop.cr:774), when the flag is set, skip the
   Galaxy round loop entirely after `kpg_discover` returns — regardless of how many
   root causes kpg found. Fix-issues/backlog/mask pass run exactly as today, so a
   low-yield kpg cycle is a cheap cycle, not an aborted one. `--no-galaxy` and
   `--no-kpg` together should be refused (a cycle with no discovery source).
2. **Stop hand-duplicating the module list.** `KPG_MODULES` is a 17-entry copy of a
   list kpg already owns (its default `--modules` = ansible.builtin core, plus
   `--supported-community`'s promoted FQCNs from `data/module_dependencies.yml`).
   Add a tiny kpg subcommand (`kpg modules --json`) that prints the default scope,
   and have the loop build its rotation from that instead of `KPG_MODULES` — the two
   lists must not drift. Keep `--kpg-modules` as the manual override. FQCNs stay
   FQCN (kpg cannot scan short names; loop.cr:9-10's rule survives verbatim).
3. **v2 wiring: `--kpg-tasks N`.** New loop flag forwarded as
   `--tasks-per-playbook N` in `run_kpg`'s argv. Default 1 keeps today's shape;
   the rollout plan (phases below) turns it up only after the v1 baseline is clean.
   A v2 playbook's sidecar carries `module_names` for every task, and
   `report --json` keys the finding on the primary module with a `modules` array —
   the triager and `verify_kpg` need no change beyond the runner already handling
   the shape (verified by kpg's own spec suite).
4. **Rotation cadence under the wider list.** `kpg_modules_per_cycle` (3) was tuned
   for 17 modules; over the full core set (~100+ modules) one cycle's slice gets
   thin. Bump the default (or make it a fraction of the list size) once step 2
   lands, and keep the offset file format untouched so an in-flight rotation
   survives the upgrade.
5. **`min_divergences` semantics stay.** In kpg-only mode the count is informational
   (it feeds `cycle_divergences` and the stats row), not a gate: never spin a role
   round to top up a short kpg cycle. Document the flag pair in the loop's usage
   output.

## Changes in krikri-playbook-generator (this repo)

1. **`modules --json`** (step 2 above): prints the default scope — core list plus
   promoted `supported:` FQCNs — as one JSON array. Best-effort one screen of code
   on top of `Options`' existing default-module logic.
2. **Nothing else is mandatory.** The podman path (Debian/Rocky template pairs,
   per-playbook fresh pairs, union dependency sets) already runs whatever the loop
   throws at it, including v2 multi-task playbooks.
3. **Optional, do not block on it: microvm.** Podman containers have no real init,
   so init/systemd-dependent modules (service, sysctl, hostname, mount, firewalld,
   …) have no runnable happy path there — today only `apt_key` and `reboot` are
   `not_applicable` in `data/module_overrides.yml`, and the rest likely fail
   identically on both engines (wasted coverage, not findings). Two-step answer,
   in order:
   - Extend `not_applicable` for the init-dependent modules so the exclusions are
     visible in `report`'s `not_applicable_modules` instead of silently burning
     coverage.
   - Only when that list grows past a handful: a `--run-on-microvm` backend reusing
     krikri-role-tester's `MicrovmBackend` machinery (golden image, cloud-image
     cache), seeding `Fixtures` over SSH instead of `podman cp`, identical
     invocations over SSH. Cost warning: kpg's per-playbook isolation is a hard
     requirement, and VMs provision slowly — snapshot/rollback per playbook or
     accept a per-profile VM running a sequential batch. Route per module like the
     existing Debian/Rocky profile rule; keep podman the default backend.
4. **Atlantic-profile modules stay out** until the podman yield drops off
   (KPG_INTEGRATION.md's open question, unchanged).

## Phases

0. **Live check of the v2 shape under the loop's invocation.** Run by hand:
   `kpg generate --modules <slice> --seed <epoch> --count 10 --tasks-per-playbook 3
   --run-on-podman --keep-going --krikri-bin <krikri>/bin/krikri-playbook`, then
   `krikri-role-triager --kpg <dir> --auto-mode` (dry). Confirm the sidecar's
   `module_names`, the grouped findings and the filed issue shape all survive v2.
1. **kpg `modules --json`.** Data + spec in this repo; no loop change yet.
2. **Loop flags.** `--no-galaxy`, `--kpg-tasks`, rotation sourced from `modules
   --json`. Dry-run a cycle (`krikri-loop --dry-run --no-galaxy`) against an
   existing kpg___ dir first.
3. **Turn the dial.** Run a week with Galaxy rounds still enabled and
   `--kpg-tasks 1`; compare kpg's root-cause yield per cycle against the stats
   table's role accuracy. Then flip `--kpg-tasks 3` (v2 findings join the same
   signature grouping) and watch the noise share — v2's chained `when:`/`loop:`
   tasks multiply the places an engine can diverge, some of which will be new mask
   material for the kpg mask pass.
4. **Make `--no-galaxy` the loop's default**, with `--galaxy` as the opt-in
   fallback. Galaxy stays available for the coverage class kpg cannot emit (a role
   exercising dozens of modules against shared state in one play).

## Open questions

- **Issue granularity for v2.** A multi-task finding keys on the primary module;
  should the issue body list every task's module (like `Affected:` playbooks do), so
  `KrikriFixIssues` agents see the whole chain? Probably yes — the playbook fence
  already carries it.
- **Duplicates between shapes.** The same krikri bug found by a v1 and a v2 playbook
  gets two signatures; accept it (same answer as KPG_INTEGRATION.md's duplicates
  question — the fix closes one, the other verifies clean next pass).
- **Mask pass on v2 diffs.** The kpg mask pass prompt (loop.cr:437) walks the
  generator repo; multi-task diffs are longer but structurally identical, so likely
  no prompt change — verify with a few real v2 findings before assuming.
- **Chaos percentage for v2.** 20% per option-slot on 3 chained tasks yields more
  chaos per playbook than 20% on one task; consider lowering `--kpg-chaos` when
  `--kpg-tasks > 1` instead of filing three times the noise.
