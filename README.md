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
   - happy-path: valid per the schema, sometimes wrapped in Jinja.
   - chaos: per-option-slot, at probability `--chaos-percentage`, mutates
     into a typo'd/hallucinated option name, a wrong-type value, an
     off-schema choice, or a violated cross-option constraint. Every
     mutation is recorded on the generated task, never injected silently.
3. **playbook-builder** — assembles generated tasks into playbook YAML,
   one task per module per play, following the shape of krikri's own
   `testing/test-*.yml` fixtures.
4. **runner** — two backends, neither the default. **Local** runs each
   playbook against both engines on this machine (`-i localhost, -c
   local`), `--check --diff` unless `--allow-mutation` is passed, so
   happy-path tasks (real modules — apt, user, ...) can't mutate *this*
   machine by accident. **Podman** (`--run-on-podman`, opt-in, needs
   `podman`) runs both engines inside a pair of throwaway, disposable
   containers instead — real execution, no `--check` needed, faster to
   iterate with than a real host. Neither replaces `--atlantic-hosts`
   (accepted and stored for a real disposable-host backend, not yet
   built) for a wide/production batch — full reuse of
   `krikri-role-tester`'s backend/diff machinery turned out not to fit
   (it's built around installing a Galaxy role onto a provisioned host
   pair, not running a raw generated playbook) without cross-repo changes
   there, out of scope here.
5. **triage** — reads `results.jsonl` plus each divergent playbook's
   `.meta.json` sidecar and groups by module + chaos-kind + option,
   deduping N divergent playbooks hitting the same root cause into one
   finding, sorted by descending count.

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
immediately runs them against both engines inside a pair of throwaway
containers, prints `[DIVERGENT]`/`[IDENTICAL] <path>` per playbook as it
goes, then the same grouped findings `report` would print:

    krikri-playbook-generator generate --modules apt,copy,user,cron --seed 42 \
      --count 500 --chaos-percentage 3 --out playbooks/ \
      --results-dir ~/scratch/kpg-results --run-on-podman

`report` (or the tail end of `generate --run-on-podman`) prints one line
per finding — `<module> (<kind> <option> | happy-path): <count> divergent
playbook(s)`, followed by the list of playbook paths — sorted by how many
playbooks hit that same root cause.

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
`Generator` turns a schema into happy-path and chaos-mutated argument
sets, deterministic per `--seed`, every mutation tagged with which slot
and which kind. `PlaybookBuilder` turns those into real playbook YAML plus
a `.meta.json` sidecar per playbook. `Runner` runs each playbook against
both real engines — locally (check mode by default) or, with
`--run-on-podman`, inside a pair of throwaway podman containers via
`PodmanBackend` — and writes `results.jsonl`. `Triage` groups divergences
from that back to a root cause via the `.meta.json` sidecars.

A full local `generate → run → report` pass across apt/user/debug found
two genuine divergences between real ansible-playbook and
krikri-playbook, correctly attributed down to the specific mutated
option, on the first try; a separate `--run-on-podman` run found a third
(krikri erroring on a `debug` task real Ansible skips cleanly at a high
`verbosity:`). See `AGENTS.md`'s "Known gaps" for what's deliberately not
built yet (a real disposable-host execution backend for wide/production
batches, `required_if` violation, multi-task playbooks, and a default
`--modules` list).
