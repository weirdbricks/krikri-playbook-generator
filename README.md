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
4. **runner** — delegates to `krikri-role-tester`'s dual-engine
   execution/diffing (cold+warm, `SUMMARY|` normalization, PLAY RECAP
   diffing) rather than reimplementing it.
5. **triage** — groups divergences by module + chaos-kind + constraint
   violated, deduping to root cause.

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

`generate` is implemented end to end — it produces real playbook YAML
(plus a `.meta.json` sidecar per playbook) you can hand straight to
`ansible-playbook`/`krikri-playbook` yourself already. `run`/`report`
bodies are not implemented yet.

    krikri-playbook-generator generate --modules apt,copy,user,cron --seed 42 \
      --count 500 --chaos-percentage 3 --out playbooks/

    krikri-playbook-generator run playbooks/ --atlantic-hosts 22 \
      --results-dir ~/scratch/kpg-results

    krikri-playbook-generator report ~/scratch/kpg-results

## Status

`generate`/`run` refuse to proceed unless both `ansible-playbook` and
`krikri-playbook` are resolvable (`Preflight`). `SchemaScanner` scans
real, installed modules via `ansible-doc -j` for option schemas and via a
small embedded Python AST scanner for cross-option constraints.
`Generator` turns a schema into happy-path and chaos-mutated argument
sets, deterministic per `--seed`, every mutation tagged with which slot
and which kind. `PlaybookBuilder` turns those into real playbook YAML plus
a `.meta.json` sidecar per playbook — verified live against real
`ansible-playbook --check`. `Runner` and `Triage` still raise "not yet
implemented" until their bodies are written.
