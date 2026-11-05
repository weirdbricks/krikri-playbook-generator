# krikri-playbook-generator — see README.md for the full model + usage.

BIN := "bin/krikri-playbook-generator"

# Print the available recipes (just with no arguments).
default:
    @just --list

# Install shard dependencies.
install:
    shards install

# Build the generator binary into bin/.
build: install
    mkdir -p bin
    crystal build src/krikri_playbook_generator.cr -o {{BIN}}

# Run the minitest suite (spec/ via crystal spec).
spec: install
    crystal spec

# Lint with ameba (built once into bin/ameba; no prebuilt binary ships).
lint: install
    test -x bin/ameba || crystal build lib/ameba/src/cli.cr -o bin/ameba
    ./bin/ameba

# Format every Crystal source file.
fmt:
    crystal tool format .

# Run the hello-world: generate one debug playbook into playbooks/.
hello: build
    {{BIN}} generate --modules debug --count 1 --out playbooks/

# Generate a batch, then run it inside throwaway podman containers.
generate MODULES="apt,copy,user,cron" COUNT="500" CHAOS="3" RUN_ARGS="--run-on-podman --keep-going":
    {{BIN}} generate --modules {{MODULES}} --seed 42 --count {{COUNT}} \
      --chaos-percentage {{CHAOS}} --out playbooks/ \
      --results-dir ~/scratch/kpg-results {{RUN_ARGS}}

# Run an already-generated batch (directory or single file).
run TARGET="playbooks/" RUN_ARGS="--run-on-podman":
    {{BIN}} run {{TARGET}} --results-dir ~/scratch/kpg-results {{RUN_ARGS}}

# Print the triage report for a results directory.
report DIR="~/scratch/kpg-results":
    {{BIN}} report {{DIR}}

# Print the tool version.
version:
    {{BIN}} --version
