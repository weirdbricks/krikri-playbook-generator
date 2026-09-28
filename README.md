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
4. **runner** — runs each playbook against both engines locally
   (`-i localhost, -c local`), `--check --diff` by default so happy-path
   tasks (real modules — apt, user, ...) can't mutate *this* machine;
   `--allow-mutation` opts out. Full reuse of `krikri-role-tester`'s
   backend/diff machinery turned out not to fit (it's built around
   installing a Galaxy role onto a provisioned host pair, not running a
   raw generated playbook) without cross-repo changes there — out of
   scope here; `--atlantic-hosts` is accepted and stored for whoever wires
   up a real disposable-host backend later.
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

The full pipeline is implemented end to end:

    krikri-playbook-generator generate --modules apt,copy,user,cron --seed 42 \
      --count 500 --chaos-percentage 3 --out playbooks/

    krikri-playbook-generator run playbooks/ --results-dir ~/scratch/kpg-results

    krikri-playbook-generator report ~/scratch/kpg-results

`report` prints one line per finding — `<module> (<kind> <option> |
happy-path): <count> divergent playbook(s)`, followed by the list of
playbook paths — sorted by how many playbooks hit that same root cause.

`run` defaults to Ansible `--check` mode (no real host mutation) since
happy-path tasks are real modules that would otherwise install packages,
create users, etc. on the machine running this tool; pass
`--allow-mutation` to run for real once you have a disposable host to
point it at.

## Status

`generate`/`run` refuse to proceed unless both `ansible-playbook` and
`krikri-playbook` are resolvable (`Preflight`). `SchemaScanner` scans
real, installed modules via `ansible-doc -j` for option schemas and via a
small embedded Python AST scanner for cross-option constraints.
`Generator` turns a schema into happy-path and chaos-mutated argument
sets, deterministic per `--seed`, every mutation tagged with which slot
and which kind. `PlaybookBuilder` turns those into real playbook YAML plus
a `.meta.json` sidecar per playbook. `Runner` runs each playbook against
both real engines locally (check mode by default) and writes
`results.jsonl`. `Triage` groups divergences from that back to a root
cause via the `.meta.json` sidecars.

A full `generate → run → report` pass across apt/user/debug found two
genuine divergences between real ansible-playbook and krikri-playbook,
correctly attributed down to the specific mutated option, on the first
try. See `AGENTS.md`'s "Known gaps" for what's deliberately not built yet
(a real disposable-host execution backend, `required_if` violation,
multi-task playbooks, and a default `--modules` list).
