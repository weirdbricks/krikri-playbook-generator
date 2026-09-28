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
  plus `SchemaScanner`, which is meant to scan installed ansible-core +
  collection Python source for `DOCUMENTATION` blocks. **Not implemented.**
- `src/krikri_playbook_generator/generator.cr` — `ChaosKind` enum,
  `GeneratedTask` (args + mutation metadata), `Generator#generate`.
  **Not implemented.**
- `src/krikri_playbook_generator/playbook_builder.cr` — `PlaybookBuilder`,
  turns `GeneratedTask`s into playbook YAML files. **Not implemented.**
- `src/krikri_playbook_generator/runner.cr` — `Runner`, thin wrapper
  around krikri-role-tester's execution/diff machinery. **Not implemented.**
- `src/krikri_playbook_generator/triage.cr` — `Triage`, groups/dedupes
  divergences by module + chaos-kind + constraint. **Not implemented.**
- `src/krikri_playbook_generator/options.cr` — CLI parsing for the three
  subcommands (`generate`, `run`, `report`). Implemented.
- `src/krikri_playbook_generator.cr` — entrypoint, dispatches on
  `Options.parse(ARGV).command`.

Everything past `Options` is currently a stub that raises "not yet
implemented" — this repo is at the scaffold stage, not feature-complete.

## Conventions and gotchas

- Follow `krikri-role-tester`'s conventions where they apply here too:
  no comments unless explaining a non-obvious why; external commands
  should go through a `Cmd`-style wrapper (not yet added — add one under
  `src/krikri_playbook_generator/cmd.cr` mirroring
  `krikri-role-tester/src/krikri_role_tester/cmd.cr` before shelling out
  to anything).
- **Coverage scope**: 100% bar for `ansible.builtin` core + krikri's
  chosen community modules; zero obligation for the rest. The default
  `--modules` list should be derived from the same source of truth the
  role-tester coverage bar uses, not hand-duplicated (see
  `community-module-scope-cut` convention in krikri's own memory).
- **Chaos mutations must always carry metadata** (`GeneratedTask#mutations`)
  — never inject a chaos mutation silently, or triage can't distinguish
  "found a real bug" from "found an artifact of our own fuzzing."
- Once `Runner` is implemented, it should depend on
  `../krikri-role-tester`'s execution/diff code rather than reimplementing
  cold+warm dual-engine runs, `SUMMARY|` normalization, or PLAY RECAP
  diffing.

## Tests

Crystal's built-in `spec` framework. `spec/spec_helper.cr` requires
`../src/krikri_playbook_generator/**`. Only `spec/options_spec.cr` exists
so far; add one spec file per source module as bodies get implemented,
following `krikri-role-tester`'s one-file-per-module pattern.
