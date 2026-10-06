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

    # A task file for the import_tasks/include_tasks actions, which resolve
    # and run a playbook fragment rather than a fixture file. It lives in the
    # fixture root so it is present in both containers before any playbook
    # exists - the actions read it at play-parse/run time, and seeding it
    # here keeps the seeding out of the compared output.
    TASKS_FILE = "#{FIXTURE_ROOT}/tasks.yml"

    # A minimal role for the include_role/import_role actions, which resolve
    # and RUN a role rather than reading a single file. It is seeded into
    # both containers, and the generator names it by absolute path
    # (ROLE_PATH): a bare `name:` is a role SEARCH that depends on each
    # engine's own roles/ search path, an absolute path is a path the module
    # is handed - the same value resolves identically on both sides. Same
    # reasoning as TASKS_FILE above.
    ROLE_NAME = "kpgrole"
    ROLE_PATH = "#{FIXTURE_ROOT}/roles/#{ROLE_NAME}"

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
      printf 'kpg_var: 1\\nkpg_list:\\n  - a\\n  - b\\n' > #{FIXTURE_ROOT}/vars.yml
      printf 'inner\\n' > #{FIXTURE_ROOT}/dir/inner.txt
      mkdir -p #{FIXTURE_ROOT}/frags #{WORK_ROOT}/tree
      printf 'frag one\n' > #{FIXTURE_ROOT}/frags/01-a.txt
      printf 'frag two\n' > #{FIXTURE_ROOT}/frags/02-b.txt
      printf 'kpg existing alpha\nsecond line\nkpg existing omega\n' > #{WORK_ROOT}/existing.txt
      printf 'key = value\nkpg setting = on\n' > #{WORK_ROOT}/existing2.txt
      printf 'tree a\n' > #{WORK_ROOT}/tree/a.txt
      printf 'tree b\n' > #{WORK_ROOT}/tree/b.conf
      printf 'hidden\n' > #{WORK_ROOT}/tree/.hidden
      tar -C #{FIXTURE_ROOT}/dir -cf #{FIXTURE_ROOT}/archive.tar inner.txt
      printf -- '-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCvePHaxVbCePVK\nwW3RuUakmAUOe1ib5phPSHxCBfwAVlzIh9paEo6K/x6NjIQrWVhGXkceVlWvwMzl\nytQxIZWHkayKF+D54PMiv3zsyoPJeIy0UA7hXT9KxyKcqbAJwOY8ZefdWrqL4lA3\nqusYncNIAPeSaVsjwfCLcfzdXi9fqV1AeCTKJHHq8LA7YYOhJYJkc6SY3x3MepHD\nvPBFXSRPhNT4PkWWr2kkhjLzl4aiEp2Mu3+Io8b2NFYcvz2i85iMASiJlqg8ykPh\n5d9vcB7FXkDAO8P/6nIoaJMwbsNrD/jCHfgsHt8z/3v2LljX7IUqj9oR7JfdNAws\nXFHWI6l3AgMBAAECggEANbCPa+1qpPlmsFdr9zo188Gx9mLmU1lkrAmVP4xeNWo3\nXII43MuFwuDZo9zlSfA98tYA87bd4/ddmkgL0fahLohznxM8WqiqLC0kF73FQh15\nC+jdDLa/2W0B2aaP/wP/Tmat4cxTfN6jxcytv2vyJvNozOsgoFnEdJ5NjRw26ZFC\nJAZE1SM8mfi+nwsMGIDbuzb/cZZcPixX5OnuWKGhaJurAcWV+kVTDwyot4PVHjmz\nOg7wZhCZ41KEr9QkiRD5cxgHLMFw/AHzUNke3FAr8G7G32M7iM0S4SMoFElOn8T4\nsGe5Mitx4Wla6/eTB+LXUVJZqfpJd3dE+veJOlTQZQKBgQDlam1lg3gXoBadwK5M\nMdwXwyM7I+1Hnqh6gGO0lvnGlVZ9W/+rU8zISuvmVL91MLHUu2ebGNn/+kTqfQhH\n+DyHO0DpP3jXDQHWmR1v0EKQqjo2bbVV9VfDKm+kjLf3W54kfgqtepaFW22yLVwG\npFlJy+w7zCtrYhW5OcxXg6fB1QKBgQDDzkzd3ACBn484mKrQfdJvragIX3r2sd6m\n+N8A4mSKRduyaAdGnFYQqRf7YpXndAKh2D0XiNRkqfth6ruVNP0i5N44MbFUseS2\nmtV/9rej/iobXRAApRP5TzsKaepMWy48zk49X35Nl4v4BUO50JXdl2PyEUjyMTq5\nR9lGLQ1YGwKBgCsb+6CWustdtsJAAcCpod0JOyaS0rShmLEkTRgTQq5RQ6Zc0kdE\ngPemNHvcsvl3hAMgkBBx9A0I30hc5GB5wg37UXBDEBcBB7ZmoURwkwGSK0wtA2U6\nrBotcDswgiVGHwpmcOU2YvB+RLe1lFRfL7QRULvP2tzb2o8q0D4lrDFdAoGAFX/l\neMbbV2BJvZEl0FbAcHrE5IZ3XfcR14ukENjK6VPaV7CMe/hWiuXGOFgO1acrUtIH\ngzoG+Dah35KCnlN/KAGxVMJAEmimEFbX8oEIkP0ram3BgBCgLNPCS9ZtX4zzesG8\nXYjKuYJWYBlT4mdAzV/+HWpAdDdrl0SIWug/etkCgYEA4/nGbdmLpLpLzhdc6RKZ\nkLAc8dC3wfKdhHid5QAvocqZZBdAya2aDx/iZbl2DS9qz0lA/LTBw5FVo+ly8MVt\nno9gUXqfu2phyu65qNyG79OrWhbsFjRBmXLbGdFNXv+NM9oP35qVo0TD2J6WQEIr\n6q4Rb36gitAoJvyn7TfbbKs=\n-----END PRIVATE KEY-----\n' > #{FIXTURE_ROOT}/privatekey.pem
      printf -- '-----BEGIN PUBLIC KEY-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAr3jx2sVWwnj1SsFt0blG\npJgFDntYm+aYT0h8QgX8AFZcyIfaWhKOiv8ejYyEK1lYRl5HHlZVr8DM5crUMSGV\nh5Gsihfg+eDzIr987MqDyXiMtFAO4V0/SscinKmwCcDmPGXn3Vq6i+JQN6rrGJ3D\nSAD3kmlbI8Hwi3H83V4vX6ldQHgkyiRx6vCwO2GDoSWCZHOkmN8dzHqRw7zwRV0k\nT4TU+D5Flq9pJIYy85eGohKdjLt/iKPG9jRWHL89ovOYjAEoiZaoPMpD4eXfb3Ae\nxV5AwDvD/+pyKGiTMG7Daw/4wh34LB7fM/979i5Y1+yFKo/aEeyX3TQMLFxR1iOp\ndwIDAQAB\n-----END PUBLIC KEY-----\n' > #{FIXTURE_ROOT}/publickey.pem
      printf -- '-----BEGIN CERTIFICATE REQUEST-----\nMIICWzCCAUMCAQAwFjEUMBIGA1UEAwwLa3BnLWZpeHR1cmUwggEiMA0GCSqGSIb3\nDQEBAQUAA4IBDwAwggEKAoIBAQCvePHaxVbCePVKwW3RuUakmAUOe1ib5phPSHxC\nBfwAVlzIh9paEo6K/x6NjIQrWVhGXkceVlWvwMzlytQxIZWHkayKF+D54PMiv3zs\nyoPJeIy0UA7hXT9KxyKcqbAJwOY8ZefdWrqL4lA3qusYncNIAPeSaVsjwfCLcfzd\nXi9fqV1AeCTKJHHq8LA7YYOhJYJkc6SY3x3MepHDvPBFXSRPhNT4PkWWr2kkhjLz\nl4aiEp2Mu3+Io8b2NFYcvz2i85iMASiJlqg8ykPh5d9vcB7FXkDAO8P/6nIoaJMw\nbsNrD/jCHfgsHt8z/3v2LljX7IUqj9oR7JfdNAwsXFHWI6l3AgMBAAGgADANBgkq\nhkiG9w0BAQsFAAOCAQEAPSGjTPb8kDlJscEFovhAvPYZyRI76tSbiPIwr7sCPTYA\nkmOvreBZVnNCIpWJfgKds8GbPvfuUszbM4ECGKZ8I5AwmWgIA93was4w3kJwBEBt\nj+3tHALWAHAGsgq+dRcIu1ma/mzmaORsA4OSugKhTPs7TcMHuzcBmtjGzKfXg1As\n4DZIBnL724u22N5G9ZcgeJKxLgnh5AStrafu5eHcp8sza8owquS9yoKQitIvNulK\nMoD9eyrL5okmaAdovrO6vdVQEHOXp1622fqnQU2Iug6GJWM6G3JJC+ZpK1xvttBp\n3lzbM9i73RJObD6FghWWXImWNyH7skGAn2pbrt4LFQ==\n-----END CERTIFICATE REQUEST-----\n' > #{FIXTURE_ROOT}/csr.pem
      printf -- '-----BEGIN CERTIFICATE-----\nMIIDJTCCAg2gAwIBAgIUWAhtwfkPvHPkfz+N5/1yi83+fKgwDQYJKoZIhvcNAQEL\nBQAwFjEUMBIGA1UEAwwLa3BnLWZpeHR1cmUwHhcNMjYxMDA2MTkyNjQwWhcNMzYx\nMDAzMTkyNjQwWjAWMRQwEgYDVQQDDAtrcGctZml4dHVyZTCCASIwDQYJKoZIhvcN\nAQEBBQADggEPADCCAQoCggEBAK948drFVsJ49UrBbdG5RqSYBQ57WJvmmE9IfEIF\n/ABWXMiH2loSjor/Ho2MhCtZWEZeRx5WVa/AzOXK1DEhlYeRrIoX4Png8yK/fOzK\ng8l4jLRQDuFdP0rHIpypsAnA5jxl591auoviUDeq6xidw0gA95JpWyPB8Itx/N1e\nL1+pXUB4JMokcerwsDthg6ElgmRzpJjfHcx6kcO88EVdJE+E1Pg+RZavaSSGMvOX\nhqISnYy7f4ijxvY0Vhy/PaLzmIwBKImWqDzKQ+Hl329wHsVeQMA7w//qcihokzBu\nw2sP+MId+Cwe3zP/e/YuWNfshSqP2hHsl900DCxcUdYjqXcCAwEAAaNrMGkwHQYD\nVR0OBBYEFIiMZh1QoEfVGQhv3bXHzrEjHGOxMB8GA1UdIwQYMBaAFIiMZh1QoEfV\nGQhv3bXHzrEjHGOxMA8GA1UdEwEB/wQFMAMBAf8wFgYDVR0RBA8wDYILa3BnLmV4\nYW1wbGUwDQYJKoZIhvcNAQELBQADggEBAIC3OYHZxFYFkUK09LtMF+NdwZ6KuG4Y\nhWpe8eTzxqr4Edd+a3A6Ykrc4NPxVuTsKRUBSZVA3Rro53aK1i8n+V3qcgDP7fLH\nj39gdKxtee1GeRh1dYVD1XPCKgVICAkjkpUAPDDMNdXjg+eTK+T78nnHwp5RoikY\nKzzx7wPlagJ67Xbp6Jx5NJBXrhT1HA9uxlmA+sFTKz4LdXfDMq/VDkY/bKNOpFft\nVlQdeDEXw/AMQdp8AyJ/CnY94y12izyKpp7DUEtnRRXlaAgGa54FgcSkbIOfndQm\nSBDGxpG0OEFvJjMtyTViMG/7DSl3TiOECp4zw5xz/3oYUqSV0IK5TKA=\n-----END CERTIFICATE-----\n' > #{FIXTURE_ROOT}/cert.pem
      printf 'FROM alpine:3.20\\nRUN touch /kpg-built\\n' > #{FIXTURE_ROOT}/Dockerfile
      printf 'services:\\n  kpg-svc:\\n    image: alpine:3.20\\n    command: sleep 1\\n' > #{FIXTURE_ROOT}/compose.yml
      if command -v git >/dev/null 2>&1 && [ ! -d #{FIXTURE_ROOT}/repo.git ]; then
        export GIT_AUTHOR_NAME=kpg GIT_AUTHOR_EMAIL=kpg@example.com GIT_COMMITTER_NAME=kpg GIT_COMMITTER_EMAIL=kpg@example.com
        export GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z'
        tmp=$(mktemp -d)
        git init -q -b main "$tmp/w" && printf 'repo file\n' > "$tmp/w/f.txt" && git -C "$tmp/w" add f.txt && git -C "$tmp/w" commit -q -m init
        git clone -q --bare "$tmp/w" #{FIXTURE_ROOT}/repo.git
        rm -rf "$tmp"
      fi
      cat > #{TASKS_FILE} <<'KPG_TASKS_EOF'
      ---
      - name: kpg fixture task
        ansible.builtin.debug:
          msg: kpg-fixture-task
      KPG_TASKS_EOF
      mkdir -p #{ROLE_PATH}/tasks #{ROLE_PATH}/defaults #{ROLE_PATH}/vars #{ROLE_PATH}/handlers
      cat > #{ROLE_PATH}/tasks/main.yml <<'KPG_ROLE_TASKS_EOF'
      - name: kpg fixture role task
        ansible.builtin.debug:
          msg: kpg-fixture-role
      KPG_ROLE_TASKS_EOF
      cat > #{ROLE_PATH}/defaults/main.yml <<'KPG_ROLE_DEFAULTS_EOF'
      kpg_role_default: one
      KPG_ROLE_DEFAULTS_EOF
      cat > #{ROLE_PATH}/vars/main.yml <<'KPG_ROLE_VARS_EOF'
      kpg_role_var: one
      KPG_ROLE_VARS_EOF
      cat > #{ROLE_PATH}/handlers/main.yml <<'KPG_ROLE_HANDLERS_EOF'
      - name: kpg fixture role handler
        ansible.builtin.debug:
          msg: kpg-fixture-role-handler
      KPG_ROLE_HANDLERS_EOF
      chmod 0755 #{FIXTURE_ROOT}/script.sh
      chmod 0644 #{FIXTURE_ROOT}/src.txt #{FIXTURE_ROOT}/src2.txt #{FIXTURE_ROOT}/template.j2 #{FIXTURE_ROOT}/dir/inner.txt #{TASKS_FILE}
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
