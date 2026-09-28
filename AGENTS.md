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
  plus `SchemaScanner`. **Implemented**: shells out to the real, installed
  `ansible-doc -j` for each module's option schema (type/choices/required/
  default/elements — exactly what real ansible-playbook validates
  arguments against, no YAML re-parsing of our own) and to
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

`Generator`, `PlaybookBuilder`, `Runner`, and `Triage` are still stubs that
raise "not yet implemented" — `Options`, `Preflight`, and `SchemaScanner`
are the only implemented pieces so far.

## Conventions and gotchas

- Follow `krikri-role-tester`'s conventions where they apply here too:
  no comments unless explaining a non-obvious why; external commands go
  through `Cmd.run` (`src/krikri_playbook_generator/cmd.cr`), not a bare
  `Process.run`.
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

`minitest.cr` (`ysbaddaden/minitest.cr`, ~> 1.6), run through `crystal spec`
— matches the workspace-wide migration off `crystal spec`'s built-in
`.should` matchers. `spec/spec_helper.cr` is just `require
"minitest/autorun"`; each spec file requires the source file it tests
directly rather than relying on a blanket require. Use `describe`/`it`
blocks with `assert_equal`/`assert_raises`/`assert`/`refute` (no
`.should`), and avoid `not_nil!` (ameba's `Lint/NotNil` flags it) — prefer
`x || default` or `x.as(T)` after a `refute_nil` check. `spec/options_spec.cr`, `spec/preflight_spec.cr`, and `spec/schema_spec.cr`
exist so far, following `krikri-role-tester`'s one-file-per-module pattern.
`schema_spec.cr` shells out to the real, locally-installed
`ansible-doc`/`python3` — no fakes, since tracking whatever ansible-core is
actually installed is the entire point — but skips exercising unfiltered
discovery (`SchemaScanner.new.scan`, no `--modules`), which would spawn two
subprocesses per one of ~9000+ installed modules; verify that path live.

`ameba` (1.7.0) is a dev dependency; run `crystal build lib/ameba/src/cli.cr
-o bin/ameba && ./bin/ameba` after `shards install` (no prebuilt binary is
shipped). Keep it clean — `crystal tool format .` first fixes most findings.
