require "./cmd"

module KrikriPlaybookGenerator
  # The fixture tree the generator's happy-path values point at, seeded
  # identically into BOTH podman containers by PodmanBackend before any
  # playbook runs (never via playbook tasks - tasks that seeded their own
  # fixtures would show up in the compared output as engine differences).
  #
  # Read-only sources live under FIXTURE_ROOT; everything a task is allowed
  # to create or mutate lives under WORK_ROOT, which is empty at the start
  # of every playbook because PodmanBackend runs each playbook in a fresh
  # container pair. No generated happy-path value may reference any path
  # outside these two roots.
  module Fixtures
    FIXTURE_ROOT = "/opt/kpg-fixtures"
    WORK_ROOT    = "/tmp/kpg-work"

    SOURCE_FILES = [
      "#{FIXTURE_ROOT}/src.txt",
      "#{FIXTURE_ROOT}/src2.txt",
      "#{FIXTURE_ROOT}/template.j2",
      "#{FIXTURE_ROOT}/script.sh",
      "#{FIXTURE_ROOT}/dir/inner.txt",
    ]

    SOURCE_DIRS = [
      "#{FIXTURE_ROOT}/dir",
    ]

    DEST_PATHS = [
      "#{WORK_ROOT}/out1.txt",
      "#{WORK_ROOT}/out2.txt",
      "#{WORK_ROOT}/out3.cfg",
      "#{WORK_ROOT}/sub",
    ]

    SEED_SCRIPT = <<-BASH
      set -e
      mkdir -p #{FIXTURE_ROOT}/dir #{WORK_ROOT}
      printf 'kpg fixture alpha\\nsecond line\\n' > #{FIXTURE_ROOT}/src.txt
      printf 'kpg fixture bravo\\n' > #{FIXTURE_ROOT}/src2.txt
      printf 'kpg says {{ 1 + 1 }}\\n' > #{FIXTURE_ROOT}/template.j2
      printf '#!/bin/sh\\necho kpg-fixture-script\\n' > #{FIXTURE_ROOT}/script.sh
      printf 'inner\\n' > #{FIXTURE_ROOT}/dir/inner.txt
      chmod 0755 #{FIXTURE_ROOT}/script.sh
      chmod 0644 #{FIXTURE_ROOT}/src.txt #{FIXTURE_ROOT}/src2.txt #{FIXTURE_ROOT}/template.j2 #{FIXTURE_ROOT}/dir/inner.txt
      BASH

    # Best-effort for local (non-podman) runs: the local backend defaults to
    # --check mode and fixture creation there is a convenience, not a
    # requirement - a machine where /opt isn't writable just sees the
    # corresponding warning, and podman runs (the byte-parity path) are
    # unaffected.
    def self.seed_local : Nil
      result = Cmd.run("bash", ["-c", SEED_SCRIPT], timeout: 60.0)
      unless Cmd.success?(result)
        STDERR.puts "warning: couldn't seed local fixtures (#{result.stderr.strip}): local runs may fail on path-typed options"
      end
    end
  end
end
