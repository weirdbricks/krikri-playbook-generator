# Proposal: krikri-module-fuzzer (working name)

## Problem

krikri's bug-finding to date comes from two sources:
1. Real Galaxy roles (`krikri-role-tester`, thousands of roles tried).
2. Hand-written playbooks targeting specific modules/features (`testing/test-*.yml` in
   `krikri`), plus `differential_fuzz` for Jinja `{{ }}` expression evaluation specifically.

Both are bottlenecked on human effort: Galaxy roles only exercise the option combinations
real role authors happened to use, and hand-written playbooks only exercise what someone
sat down and wrote. Neither systematically covers a module's full option surface
(type combinations, choices, mutually_exclusive/required_together/required_if
constraints) or the error paths for a module.

## Goal

A standalone tool that:
1. Scans installed Ansible module source for `DOCUMENTATION` schemas.
2. Generates random-but-schema-aware task argument sets per module ("happy path" fuzzing).
3. Optionally injects a configurable percentage of invalid/malformed/hallucinated
   arguments per option-slot ("chaos mode") to exercise error-handling/validation parity,
   not just successful-execution parity.
4. Assembles generated tasks into playbooks.
5. Executes each playbook against both real `ansible-playbook` and `krikri-playbook`,
   diffing results.
6. Reports divergences, classified by whether they came from a happy-path or chaos-mode
   generation, and further sub-classified by chaos kind.

This turns bug-finding from "wait for a human to hit the bug" into "run N thousand
generated playbooks overnight and triage the diff."

## Why a separate repo

- Mirrors the existing `krikri-role-tester` precedent: execution/diffing infrastructure
  that drives krikri already lives outside `krikri` proper, as a sibling repo.
- Different dependency footprint: this tool needs a YAML/docstring scraper over Python
  module source (Ansible's own modules + installed collections), not krikri's Crystal
  internals (parser, evaluator, plugin system).
- Independent release cadence: schema-scraping and generation logic changes on its own
  schedule, unrelated to krikri engine version bumps.
- Reuse without coupling: it should *depend on* `krikri-role-tester`'s execution/diff
  machinery (cold+warm dual-engine run, `SUMMARY|` normalization, PLAY RECAP diffing)
  rather than either repo depending on the other's unrelated internals.
- Consistent with the workspace convention in `git_work/CLAUDE.md`: `dirless-store`,
  `dirless-agent` etc. are separate repos from the platform pieces they support, wired
  together via `shard.yml` deps, not folder-nesting.

Suggested name: `krikri-module-fuzzer` (alt: `krikri-argfuzz`, `ansible-module-fuzzer` if
it should read as engine-agnostic — it fuzzes against *any* two Ansible-compatible
engines, krikri is just the one we care about).

## Architecture

```
krikri-module-fuzzer
├── schema/          scans installed ansible-core + collections' Python module source,
│                    extracts DOCUMENTATION YAML per module -> normalized option schema
│                    (type, choices, required, default, mutually_exclusive,
│                    required_together, required_if, required_one_of, elements for lists)
├── generator/        given a module's schema + RNG seed + chaos-percentage:
│                     - happy-path: builds valid arg dicts respecting types/choices/
│                       required/defaults, sometimes wraps values in Jinja
│                     - chaos: per-option-slot, with probability = chaos-percentage,
│                       mutates into one of:
│                         * typo'd option name (char swap/drop/transpose, case-style flip)
│                         * hallucinated option name (borrowed from a different module's
│                           schema, or synthesized)
│                         * wrong-type value (str where int/bool/list/dict expected)
│                         * off-schema choice (near-miss value not in `choices:`)
│                         * violated constraint (trip mutually_exclusive/required_together/
│                           required_if on purpose)
│                     each generated task carries mutation metadata (which slots, which
│                     chaos kind) for triage - never inject silently
├── playbook-builder/ assembles N generated tasks per module into playbook YAML,
│                      following the existing testing/test-*.yml fixture shape
├── runner/            thin wrapper delegating to krikri-role-tester's dual-engine
│                      execution + diffing (reused, not reimplemented)
└── triage/            groups divergences by module + chaos-kind + constraint violated;
                       dedupes to root cause the same way the krikri fix-divergence
                       workflow already does
```

## CLI surface (sketch)

```
module-fuzzer generate --modules apt,copy,user,cron --seed 42 --count 500 \
  --chaos-percentage 3 --out playbooks/

module-fuzzer run playbooks/ --atlantic-hosts 22 --results-dir ~/scratch/mfz-results

module-fuzzer report ~/scratch/mfz-results
```

- `--chaos-percentage` (default low, e.g. 1-5%): probability *per option-slot* that a
  chaos mutation is applied, not per-task. Keeps most generated tasks schema-valid so
  module *logic* still gets exercised, not just the argument-validation layer.
- `--modules` optional filter; default is every module krikri has "chosen to support"
  (reuse the same core+supported-community list the role-tester coverage bar already
  encodes, so fuzzing effort tracks the same scope decision).
- Chaos sub-kind should be independently toggleable (`--chaos-kinds typo,hallucinate,
  wrong-type,bad-choice,violate-constraint`) so a triage session can isolate "just error
  message parity" from "just type coercion parity."

## Coverage scope

Same rule as the Galaxy-role workflow (`community-module-scope-cut` in krikri's own
conventions): 100% bar for `ansible.builtin` core modules and modules krikri has
deliberately chosen to support; zero obligation for the rest. The fuzzer's default
`--modules` list should be generated from that same source of truth rather than
hand-duplicated, so the two don't drift.

## Open questions

1. **Schema source of truth**: scrape locally-installed `ansible-core`/collections
   (accurate to what's actually installed, but only covers what's installed) vs. vendor a
   snapshot of DOCUMENTATION blocks (reproducible across machines, needs a refresh
   process). Leaning toward scraping installed packages first, since the role-tester
   workflow already assumes a real `ansible-playbook` install for comparison runs.
2. **Multi-task interaction fuzzing**: v1 should be single-task-per-module playbooks (like
   `test-*-quick.yml`). Multi-task interactions (register + when chains, loops, handlers)
   are a real source of bugs but conflate two things under test at once — worth a v2,
   not v1.
3. **Execution cost**: chaos-mode failures should mostly fail fast (arg validation, no
   real host mutation), so chaos-heavy batches can likely run at higher concurrency than
   Galaxy-role batches. Happy-path batches that actually mutate host state need the same
   Atlantic.net concurrency discipline as today (cap 22, 2 reserved for Dirless).
4. **Result classification reuse**: does `krikri-role-tester`'s existing `SUMMARY|`/PLAY
   RECAP diffing suffice, or does chaos mode need a new diff dimension (error message
   text/exit code parity, not just changed/ok counts)? Likely need to extend diffing to
   compare stderr/error-message shape for chaos cases specifically, since happy-path
   diffing today is mostly counter-based.
</content>
