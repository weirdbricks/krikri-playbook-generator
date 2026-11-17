require "./cmd"
require "./run_context"
require "./plugin_shapes"

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

    # The unprivileged account the `--user-profile nonroot` axis runs the
    # engines as. Provisioned into every isolated host by IDENTITY_SCRIPT
    # (podman template and microVM golden), with passwordless sudo so a
    # playbook's own `become` still works.
    UNPRIVILEGED_USER = "kpg"
    UNPRIVILEGED_HOME = "/home/kpg"

    # Idempotent, so a golden/template rebuilt from a cache that already
    # has the account keeps working. `sudo` itself comes from the package
    # union (deb_modules/rpm both lists); the sudoers file is written
    # regardless so a host that later gains sudo still gets the rule.
    IDENTITY_SCRIPT = <<-BASH
      id -u #{UNPRIVILEGED_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash #{UNPRIVILEGED_USER}
      chmod 0755 #{UNPRIVILEGED_HOME}
      mkdir -p /etc/sudoers.d
      printf '%s\\n' '#{UNPRIVILEGED_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/#{UNPRIVILEGED_USER}
      chmod 0440 /etc/sudoers.d/#{UNPRIVILEGED_USER}
      BASH

    # The SSH transport profile's target: one generated keypair, installed
    # for both accounts an engine row may run as, sshd listening on
    # SSH_PORT. The key lives under the (unsnapshotted) fixture root and
    # each account gets its own 0600 copy, because ssh refuses a world
    # readable private key. Host keys are generated once into the committed
    # template, and every per-playbook container starts with the same
    # server identity; ANSIBLE_HOST_KEY_CHECKING=False keeps the engines
    # from needing a known_hosts entry for it.
    SSH_PORT   = 2222
    SSH_KEY    = "#{FIXTURE_ROOT}/ssh/kpg_id"
    SSH_SCRIPT = <<-BASH
      set -e
      mkdir -p #{FIXTURE_ROOT}/ssh /run/sshd
      chmod 0755 #{FIXTURE_ROOT}/ssh
      if [ ! -f #{SSH_KEY} ]; then
        ssh-keygen -q -t ed25519 -N '' -C kpg -f #{SSH_KEY}
      fi
      chmod 0600 #{SSH_KEY}
      chmod 0644 #{SSH_KEY}.pub
      install_key() {
        home="$1"
        owner="$2"
        install -d -m 0700 -o "$owner" -g "$owner" "$home/.ssh"
        cp #{SSH_KEY} "$home/.ssh/kpg_id"
        cp #{SSH_KEY}.pub "$home/.ssh/kpg_id.pub"
        chown "$owner:$owner" "$home/.ssh/kpg_id" "$home/.ssh/kpg_id.pub"
        chmod 0600 "$home/.ssh/kpg_id"
        chmod 0644 "$home/.ssh/kpg_id.pub"
        touch "$home/.ssh/authorized_keys"
        chown "$owner:$owner" "$home/.ssh/authorized_keys"
        chmod 0600 "$home/.ssh/authorized_keys"
        grep -qxF "$(cat #{SSH_KEY}.pub)" "$home/.ssh/authorized_keys" 2>/dev/null || \
          cat #{SSH_KEY}.pub >> "$home/.ssh/authorized_keys"
      }
      install_key /root root
      install_key #{UNPRIVILEGED_HOME} #{UNPRIVILEGED_USER}
      ssh-keygen -A >/dev/null
      /usr/sbin/sshd -p #{SSH_PORT} -o PermitRootLogin=yes -o PasswordAuthentication=no \
        -o UsePAM=no -o PidFile=/run/sshd-kpg.pid || true
      BASH

    # OpenSSH refuses a locked account (`!` in /etc/shadow) even for public
    # key auth, and useradd leaves the provisioned account locked. `*` is
    # "no usable password" without being locked, which is exactly the
    # key-only account the SSH rows need. Run before the first snapshot,
    # so it is baseline state rather than a mutation either engine made.
    SSH_PREPARE_COMMAND = "usermod -p '*' #{UNPRIVILEGED_USER}"

    # The key path an engine row running as `user` can read.
    def self.ssh_key_path(user : UserProfile) : String
      user.nonroot? ? "#{UNPRIVILEGED_HOME}/.ssh/kpg_id" : "/root/.ssh/kpg_id"
    end

    # Starts sshd in a container that may have been built before the
    # package layer got openssh-server; silently a no-op there. Used by
    # the per-playbook bootstrap in both backend scripts.
    SSH_BOOTSTRAP = <<-BASH
      mkdir -p /run/sshd; /usr/sbin/sshd -p #{SSH_PORT} -o PermitRootLogin=yes -o PasswordAuthentication=no -o UsePAM=no -o PidFile=/run/sshd-kpg.pid >/dev/null 2>&1 || true;
      BASH

    # The fixture roots are seeded once into the shared image as root, so
    # the writable half has to be re-owned for whichever identity the row
    # runs as. Doing it per run (before the first snapshot) keeps both
    # engines' hosts identical without baking a profile-specific image.
    #
    # It also re-creates the read-only and unusual-mode destinations
    # (RESTORE_UNUSUAL_SCRIPT), so every row and both engines start from
    # the same destination state even when an earlier run replaced or
    # rewrote one of them: the modes are part of the input under test, not
    # residue from the previous comparison.
    def self.ownership_command(user : UserProfile) : String
      owner = user.nonroot? ? "#{UNPRIVILEGED_USER}:#{UNPRIVILEGED_USER}" : "root:root"
      "chown -R #{owner} #{WORK_ROOT} && chmod 0755 #{WORK_ROOT} && " \
      "chown -R root:root #{READONLY_DIR} && chmod -R a+rX #{FIXTURE_ROOT} && " \
      "#{RESTORE_UNUSUAL_SCRIPT}"
    end

    # Content shapes production playbooks actually copy: a binary file (NUL
    # bytes, not text - copy must not translate line endings and --diff
    # output differs from a text diff), a file without a trailing newline,
    # and a template with literal text, expressions, a comment and a
    # statement block.
    BINARY_FILE     = "#{FIXTURE_ROOT}/binary.bin"
    NO_NEWLINE_FILE = "#{FIXTURE_ROOT}/no-newline.txt"
    RICH_TEMPLATE   = "#{FIXTURE_ROOT}/rich.j2"

    # A tree with files AND directories at several depths, so find/stat and
    # recursive copy have an ordering shape to compare (a flat tree cannot
    # differ in traversal order).
    MIXED_TREE = "#{WORK_ROOT}/mixed"

    SOURCE_FILES = [
      "#{FIXTURE_ROOT}/src.txt",
      "#{FIXTURE_ROOT}/src2.txt",
      "#{FIXTURE_ROOT}/template.j2",
      "#{FIXTURE_ROOT}/script.sh",
      "#{FIXTURE_ROOT}/dir/inner.txt",
      BINARY_FILE,
      NO_NEWLINE_FILE,
      RICH_TEMPLATE,
    ]

    # A task file for the import_tasks/include_tasks actions, which resolve
    # and run a playbook fragment rather than a fixture file. It lives in the
    # fixture root so it is present in both containers before any playbook
    # exists - the actions read it at play-parse/run time, and seeding it
    # here keeps the seeding out of the compared output.
    TASKS_FILE = "#{FIXTURE_ROOT}/tasks.yml"
    # A second task file, so a looped include_tasks iterates more than once.
    TASKS_FILE_2 = "#{FIXTURE_ROOT}/tasks2.yml"

    # A task file and its playbook-relative child: the include-forms axis
    # copies this directory next to the generated playbook, so the
    # playbook-relative include (`<basename>-inc/a.yml`, which itself
    # includes `b.yml` relatively) exercises the same resolution ansible
    # and krikri must agree on.
    RELATIVE_DIR   = "#{FIXTURE_ROOT}/inc"
    RELATIVE_ENTRY = "#{RELATIVE_DIR}/a.yml"
    RELATIVE_CHILD = "#{RELATIVE_DIR}/b.yml"

    # A whole play for the import_playbook form (the directive is
    # play-level, so the generated playbook gets a second top-level item).
    CHILD_PLAYBOOK = "#{FIXTURE_ROOT}/child-play.yml"

    # A real armored OpenPGP public key: apt_key's alternatives (a random
    # id, a URL) all fail before the module logic runs, and rpm_key needs a
    # key file it can hand to gpg. Same key, same path, both containers.
    PGP_KEY_PATH = "#{FIXTURE_ROOT}/pgpkey.asc"

    # A local Subversion repository, so subversion's happy path can check
    # out something real without touching the network (seeded only where
    # svnadmin is installed).
    SVN_REPO_URL = "file://#{FIXTURE_ROOT}/svnrepo"

    # A pre-seeded, already-finished async job: async_status needs a job id
    # that exists, and this tool only ever emits single-task playbooks, so
    # the job cannot be created in the same run.
    ASYNC_JOB_ID = "kpgjob"

    # A minimal role for the include_role/import_role actions, which resolve
    # and RUN a role rather than reading a single file. It is seeded into
    # both containers, and the generator names it by absolute path
    # (ROLE_PATH): a bare `name:` is a role SEARCH that depends on each
    # engine's own roles/ search path, an absolute path is a path the module
    # is handed - the same value resolves identically on both sides. Same
    # reasoning as TASKS_FILE above.
    ROLE_NAME = "kpgrole"
    # The role's own defaults/vars keys; the include-forms axis overrides
    # them with task-level `vars:` to compare precedence.
    ROLE_DEFAULT_VAR = "kpg_role_default"
    ROLE_VARS_VAR    = "kpg_role_var"
    ROLE_PATH        = "#{FIXTURE_ROOT}/roles/#{ROLE_NAME}"

    SOURCE_DIRS = [
      "#{FIXTURE_ROOT}/dir",
    ]

    # The deterministic retry fixtures: one command that succeeds only on
    # its third run (its counter lives in the writable work root, so the
    # per-playbook fresh pair starts from zero), and one that never
    # succeeds, for the never-satisfied `until:` shape.
    RETRY_SCRIPT       = "#{FIXTURE_ROOT}/retry.sh"
    RETRY_NEVER_SCRIPT = "#{FIXTURE_ROOT}/retry-never.sh"
    RETRY_COUNTER      = "#{WORK_ROOT}/retry.count"

    # Custom plugins for the extension-API axes: lookup (#25), strategy
    # (#26) and filter/expression (#27). The sources are Crystal constants
    # rather than files because the same bytes must be both seeded into
    # every isolated host and written playbook-adjacently for a
    # `--plugin-discovery relative` row, and the two copies must never
    # drift apart.
    PLUGIN_ROOT         = "#{FIXTURE_ROOT}/plugins"
    LOOKUP_PLUGIN_DIR   = "#{PLUGIN_ROOT}/lookup_plugins"
    FILTER_PLUGIN_DIR   = "#{PLUGIN_ROOT}/filter_plugins"
    STRATEGY_PLUGIN_DIR = "#{PLUGIN_ROOT}/strategy_plugins"
    CFG_DIR             = "#{FIXTURE_ROOT}/cfg"
    PLUGIN_CONFIG       = "#{CFG_DIR}/kpg-plugins.cfg"

    LOOKUP_LIST        = "kpg_list"
    LOOKUP_NONE        = "kpg_none"
    LOOKUP_UNDEFINED   = "kpg_undefined"
    LOOKUP_RAISE       = "kpg_raise"
    LOOKUP_SIDE_EFFECT = "kpg_sideeffect"
    LOOKUP_UNKNOWN     = "kpg_bogus_lookup"
    FILTER_PLUGIN_NAME = "kpg_multi"
    CUSTOM_STRATEGY    = PluginShapes::CUSTOM_STRATEGY
    SIDE_EFFECT_FILE   = "#{WORK_ROOT}/lookup-sideeffect.txt"

    LOOKUP_LIST_SOURCE = <<-PY
      from ansible.plugins.lookup import LookupBase


      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              return ['kpg-a', 'kpg-b']
      PY

    LOOKUP_NONE_SOURCE = <<-PY
      from ansible.plugins.lookup import LookupBase


      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              return None
      PY

    LOOKUP_UNDEFINED_SOURCE = <<-PY
      from ansible.plugins.lookup import LookupBase


      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              return 'undefined'
      PY

    LOOKUP_RAISE_SOURCE = <<-PY
      from ansible.errors import AnsibleError
      from ansible.plugins.lookup import LookupBase


      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              raise AnsibleError('kpg lookup exploded')
      PY

    LOOKUP_SIDE_EFFECT_SOURCE = <<-'PY'
      from ansible.plugins.lookup import LookupBase


      class LookupModule(LookupBase):
          def run(self, terms, variables=None, **kwargs):
              # A real lookup runs on the controller even in check mode, so
              # writing unconditionally would show up as a check-mode
              # mutation finding on both engines. The write is the probe
              # only in real mode, where the state oracle compares it.
              if not (variables or {}).get('ansible_check_mode'):
                  with open('/tmp/kpg-work/lookup-sideeffect.txt', 'w') as handle:
                      handle.write('kpg side effect\n')
              return ['kpg-sideeffect']
      PY

    FILTER_SOURCE = <<-PY
      def kpg_multi(*args):
          return '|'.join(str(arg) for arg in args)


      class FilterModule(object):
          def filters(self):
              return {'kpg_multi': kpg_multi}
      PY

    STRATEGY_SOURCE = <<-PY
      from __future__ import annotations

      from ansible.plugins.strategy.linear import StrategyModule as LinearStrategy
      from ansible.utils.display import Display

      display = Display()


      class StrategyModule(LinearStrategy):
          """A third-party strategy: prints its own markers around the linear
          run, so an engine that loads it runs visible code and an engine that
          substitutes linear does not."""

          def run(self, iterator, play_context):
              display.display('kpg-custom-strategy: begin')
              result = super(StrategyModule, self).run(iterator, play_context)
              display.display('kpg-custom-strategy: end')
              return result
      PY

    # Keyed by loader directory (PluginShapes::DIRS values) so lookup and
    # filter plugins can never be seeded into each other's directory.
    PLUGIN_SOURCES = {
      "lookup_plugins" => {"kpg_list.py" => LOOKUP_LIST_SOURCE, "kpg_none.py" => LOOKUP_NONE_SOURCE,
                           "kpg_undefined.py" => LOOKUP_UNDEFINED_SOURCE, "kpg_raise.py" => LOOKUP_RAISE_SOURCE,
                           "kpg_sideeffect.py" => LOOKUP_SIDE_EFFECT_SOURCE},
      "filter_plugins"   => {"kpg_filters.py" => FILTER_SOURCE},
      "strategy_plugins" => {"kpg_custom.py" => STRATEGY_SOURCE},
    }

    # The plugin sources for one plugin kind (PluginShapes::*_KIND).
    def self.plugin_sources(kind : String) : Hash(String, String)
      PLUGIN_SOURCES[PluginShapes::DIRS[kind]]? || {} of String => String
    end

    def self.plugin_dir(kind : String) : String
      "#{PLUGIN_ROOT}/#{PluginShapes::DIRS[kind]}"
    end

    # The environment a plugin row exports. Playbook-adjacent discovery
    # exports nothing: the files travel with the playbook instead (every
    # isolated backend copies them next to it).
    def self.plugin_env(discovery : PluginDiscovery, kinds : Array(String)) : Hash(String, String)
      return {} of String => String if kinds.empty?

      case discovery
      when .relative?
        {} of String => String
      when .env?
        kinds.to_h { |kind| {PluginShapes::ENV_KEYS[kind], plugin_dir(kind)} }
      else
        {"ANSIBLE_CONFIG" => PLUGIN_CONFIG}
      end
    end

    # Shell that writes every plugin source plus the ansible.cfg variant
    # into the fixture root. Generated from PLUGIN_SOURCES so a
    # relative-discovery playbook and a seeded host carry identical bytes.
    def self.plugin_seed_script : String
      String.build do |io|
        PLUGIN_SOURCES.each do |dir_name, sources|
          dir = "#{PLUGIN_ROOT}/#{dir_name}"
          io << "mkdir -p #{dir}\n"
          sources.each do |name, source|
            io << "cat > #{dir}/#{name} <<'KPG_PLUGIN_EOF'\n"
            io << source << '\n'
            io << "KPG_PLUGIN_EOF\n"
          end
        end
        io << "mkdir -p #{CFG_DIR}\n"
        io << "cat > #{PLUGIN_CONFIG} <<'KPG_PLUGIN_CFG_EOF'\n"
        io << "[defaults]\n"
        PluginShapes::DIRS.each do |kind, dir_name|
          io << "#{dir_name} = #{plugin_dir(kind)}\n"
        end
        io << "KPG_PLUGIN_CFG_EOF\n"
      end
    end

    # A destination whose parent directory is root-owned and read-only: on
    # the nonroot profile a write proves the identity axis (real ansible
    # fails with the permission error), while the root profile still runs.
    # It is seeded on every pre-existing image and restored after each
    # ownership fix, so both engines meet the same starting state.
    READONLY_DIR  = "#{WORK_ROOT}/readonly"
    READONLY_DEST = "#{READONLY_DIR}/dest.txt"

    # Existing destinations whose mode production playbooks really meet.
    # They live in the WRITABLE work root on purpose: both engines can
    # still replace a locked file through an atomic rename, so the compared
    # behavior is replace-vs-write-in-place and the resulting mode, not a
    # flat permission error (that is what READONLY_DIR above is for).
    # Restored by ownership_command before every row.
    UNUSUAL_FILES = {
      "#{WORK_ROOT}/dest-0444.txt" => "0444",
      "#{WORK_ROOT}/dest-0400.txt" => "0400",
      "#{WORK_ROOT}/dest-0440.txt" => "0440",
    }

    # Directories with unusual modes: owner-only (0600), setgid (2755) and
    # sticky (1777), so a module creating children there has to agree on
    # the inherited mode and on who may write.
    UNUSUAL_DIRS = {
      "#{WORK_ROOT}/dir-0600"   => "0600",
      "#{WORK_ROOT}/dir-setgid" => "2755",
      "#{WORK_ROOT}/dir-sticky" => "1777",
    }

    DEST_PATHS = [
      "#{WORK_ROOT}/out1.txt",
      "#{WORK_ROOT}/out2.txt",
      "#{WORK_ROOT}/out3.cfg",
      "#{WORK_ROOT}/sub",
      READONLY_DEST,
    ] + UNUSUAL_FILES.keys

    # Existing directories with an unusual mode, for chdir-style options.
    # They are deliberately NOT in DEST_PATHS: most consumers of a generic
    # destination expect a file path, and an existing directory there fails
    # the module before it exercises anything.
    WORK_DIRS = [WORK_ROOT, "#{FIXTURE_ROOT}/dir"] + UNUSUAL_DIRS.keys

    # Idempotent: recreates the locked destinations with their content and
    # modes. Shared by the one-time image seed and the per-row ownership
    # fix, so the two can never disagree about what the starting state is.
    RESTORE_UNUSUAL_SCRIPT = String.build do |io|
      UNUSUAL_FILES.each do |path, mode|
        io << "printf 'kpg locked dest\\nsecond line\\n' > #{path}\n"
        io << "chmod #{mode} #{path}\n"
      end
      UNUSUAL_DIRS.each do |path, mode|
        io << "mkdir -p #{path}\n"
        io << "chmod #{mode} #{path}\n"
      end
      io << "mkdir -p #{READONLY_DIR}\n"
      io << "printf 'kpg read-only dest\\n' > #{READONLY_DEST}\n"
      io << "chmod 0444 #{READONLY_DEST}\n"
      io << "chmod 0555 #{READONLY_DIR}\n"
    end

    # get_url/uri need a URL that actually serves something: a random URL
    # fails DNS/connection before the module logic runs, which the quality
    # report counts as wasted coverage. The podman backend starts a python
    # http.server on this fixed loopback port at container start (in every
    # fresh pair as well as the templates) serving the read-only fixture
    # root, so these URLs resolve identically on both engine sides and
    # without touching the network. The paths must stay files the seed
    # script really creates.
    HTTP_PORT = 18888

    HTTP_URLS = [
      "http://127.0.0.1:#{HTTP_PORT}/src.txt",
      "http://127.0.0.1:#{HTTP_PORT}/src2.txt",
      "http://127.0.0.1:#{HTTP_PORT}/template.j2",
      "http://127.0.0.1:#{HTTP_PORT}/dir/inner.txt",
    ]

    SEED_SCRIPT = <<-BASH
      set -e
      mkdir -p #{FIXTURE_ROOT}/dir #{WORK_ROOT}
      printf 'kpg fixture alpha\\nsecond line\\n' > #{FIXTURE_ROOT}/src.txt
      printf '\\000\\001kpg\\000binary\\377\\n' > #{BINARY_FILE}
      printf 'kpg no trailing newline' > #{NO_NEWLINE_FILE}
      cat > #{RICH_TEMPLATE} <<'KPG_RICH_TEMPLATE_EOF'
      literal line
      value: {{ 1 + 1 }}
      {# kpg comment #}
      {% if true %}kpg-true{% endif %}
      KPG_RICH_TEMPLATE_EOF
      mkdir -p #{MIXED_TREE}/one #{MIXED_TREE}/one/two #{MIXED_TREE}/three
      printf 'mixed root\\n' > #{MIXED_TREE}/root.txt
      printf 'mixed one\\n' > #{MIXED_TREE}/one/a.txt
      printf 'mixed two\\n' > #{MIXED_TREE}/one/two/b.conf
      printf 'mixed three\\n' > #{MIXED_TREE}/three/c.txt
      printf 'kpg fixture bravo\\n' > #{FIXTURE_ROOT}/src2.txt
      printf 'kpg says {{ 1 + 1 }}\\n' > #{FIXTURE_ROOT}/template.j2
      printf '#!/bin/sh\\necho kpg-fixture-script\\n' > #{FIXTURE_ROOT}/script.sh
      cat > #{RETRY_SCRIPT} <<'KPG_RETRY_EOF'
      #!/bin/sh
      count=$(cat #{RETRY_COUNTER} 2>/dev/null || echo 0)
      count=$((count + 1))
      echo "$count" > #{RETRY_COUNTER}
      [ "$count" -ge 3 ] && exit 0
      exit 1
      KPG_RETRY_EOF
      printf '#!/bin/sh\\nexit 1\\n' > #{RETRY_NEVER_SCRIPT}
      printf 'kpg_var: 1\\nkpg_list:\\n  - a\\n  - b\\n' > #{FIXTURE_ROOT}/vars.yml
      printf 'inner\\n' > #{FIXTURE_ROOT}/dir/inner.txt
      mkdir -p #{FIXTURE_ROOT}/frags #{WORK_ROOT}/tree
      printf 'frag one\n' > #{FIXTURE_ROOT}/frags/01-a.txt
      printf 'frag two\n' > #{FIXTURE_ROOT}/frags/02-b.txt
      printf 'kpg existing alpha\nsecond line\nkpg existing omega\n' > #{WORK_ROOT}/existing.txt
      printf 'key = value\nkpg setting = on\n' > #{WORK_ROOT}/existing2.txt
      mkdir -p #{READONLY_DIR}
      #{RESTORE_UNUSUAL_SCRIPT}
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
      printf '%s\\n' \
        '-----BEGIN PGP PUBLIC KEY BLOCK-----' \
        '' \
        'mQENBGrrQ70BCADS16wZb+AnRjOkZMG3U6e0dQsLnK+G+QuGDt9fhpXHZyDPdVV7' \
        'AKCiWpY0BwI6qJ7+xHOTeilCm2pfobh4sjLuxCuv6J8fYC8abvZgfdegd2naxcEh' \
        'EAY18jeKHKf0kNqbwkJszHDbYQrHVpZk1or55RUXc8zc30307oxGPxLRKd5hnnoi' \
        'lXg6H59LT+AR+NiXghjVLrIAsJXEZsruh15LORRMqnQLvnGUTyQL4lQjM1LTUtHa' \
        'qhrazg7ucbjP25aVietuqb0xA0fD2oztwvwbxT2ZqYE6JfqiLEJzd1pefuzEuPND' \
        'JvXmlidGLiINO1Tla6QXa/476pCoDnFHG4npABEBAAG0HWtwZyBmaXh0dXJlIDxr' \
        'cGdAZXhhbXBsZS5jb20+iQFOBBMBCgA4FiEE3gTTQDp7uVP8NXhuODz4JjFmy3sF' \
        'AmrrQ70CGwMFCwkIBwIGFQoJCAsCBBYCAwECHgECF4AACgkQODz4JjFmy3uktQgA' \
        '0JvhpRxYGllT4mm8ESEAZn6vrOD2XqvVE5GnhZSc13qHFKNExV820XTUrHVGSdfJ' \
        '00h7kA7rRS2lAKnd5T32t+tJKocoui9mnhNDTg4b0YEeg8Vw+bOZJ45gfiKxOZKd' \
        'UUGmpPBAFOCmsZwXYtEdBXW/08W7WqrHjzKoAld3FY7FPgrIfcoOWTtD/zmUXvgU' \
        'n7809kS0NoilLGuWsXlEhqpm/SUcP6e3eD9QzfXXd9s+arzP5zcfv6AcSsp0roVG' \
        'awWP2q+qvo/s+ISudlzJk3fizTmtLjTG05j83wvMZWVGB+XP914WleOnncQSjh0q' \
        'nKRPOjQTFN6kJ2qEsK7zgw==' \
        '=K/+b' \
        '-----END PGP PUBLIC KEY BLOCK-----' > #{FIXTURE_ROOT}/pgpkey.asc
      if command -v svnadmin >/dev/null 2>&1 && [ ! -d #{FIXTURE_ROOT}/svnrepo ]; then
        svnadmin create #{FIXTURE_ROOT}/svnrepo
      fi
      if [ "$(id -u)" = "0" ]; then
        mkdir -p /root/.ansible_async
        printf '{"ansible_job_id":"kpgjob","started":1,"finished":1,"results_file":"%s/async_result.json"}' #{FIXTURE_ROOT} > /root/.ansible_async/kpgjob
        printf '{"changed":false,"rc":0,"stdout":"kpg"}' > #{FIXTURE_ROOT}/async_result.json
      fi
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
      cat > #{TASKS_FILE_2} <<'KPG_TASKS2_EOF'
      ---
      - name: kpg fixture task two
        ansible.builtin.debug:
          msg: kpg-fixture-task-two
      KPG_TASKS2_EOF
      mkdir -p #{RELATIVE_DIR}
      cat > #{RELATIVE_ENTRY} <<'KPG_REL_A_EOF'
      ---
      - name: kpg relative include a
        ansible.builtin.debug:
          msg: kpg-relative-a
      - name: kpg relative include b
        ansible.builtin.include_tasks: b.yml
      KPG_REL_A_EOF
      cat > #{RELATIVE_CHILD} <<'KPG_REL_B_EOF'
      ---
      - name: kpg relative include b task
        ansible.builtin.debug:
          msg: kpg-relative-b
      KPG_REL_B_EOF
      cat > #{CHILD_PLAYBOOK} <<'KPG_CHILD_PLAY_EOF'
      ---
      - name: Kpg imported play
        hosts: kpg_targets
        gather_facts: false
        tasks:
          - name: Kpg imported task
            ansible.builtin.debug:
              msg: kpg-imported-play
      KPG_CHILD_PLAY_EOF
      mkdir -p #{ROLE_PATH}/tasks #{ROLE_PATH}/defaults #{ROLE_PATH}/vars #{ROLE_PATH}/handlers
      cat > #{ROLE_PATH}/tasks/main.yml <<'KPG_ROLE_TASKS_EOF'
      - name: kpg fixture role task
        ansible.builtin.debug:
          msg: "{{ kpg_role_default }}-{{ kpg_role_var }}"
      - name: kpg fixture role include
        ansible.builtin.include_tasks: inner.yml
      KPG_ROLE_TASKS_EOF
      cat > #{ROLE_PATH}/tasks/inner.yml <<'KPG_ROLE_INNER_EOF'
      - name: kpg fixture role inner task
        ansible.builtin.debug:
          msg: kpg-fixture-role-inner
      - name: kpg fixture role nested include
        ansible.builtin.include_tasks: nested.yml
      KPG_ROLE_INNER_EOF
      cat > #{ROLE_PATH}/tasks/nested.yml <<'KPG_ROLE_NESTED_EOF'
      - name: kpg fixture role nested task
        ansible.builtin.debug:
          msg: kpg-fixture-role-nested
      KPG_ROLE_NESTED_EOF
      cat > #{ROLE_PATH}/defaults/main.yml <<'KPG_ROLE_DEFAULTS_EOF'
      #{ROLE_DEFAULT_VAR}: one
      KPG_ROLE_DEFAULTS_EOF
      cat > #{ROLE_PATH}/vars/main.yml <<'KPG_ROLE_VARS_EOF'
      #{ROLE_VARS_VAR}: one
      KPG_ROLE_VARS_EOF
      cat > #{ROLE_PATH}/handlers/main.yml <<'KPG_ROLE_HANDLERS_EOF'
      - name: kpg fixture role handler
        ansible.builtin.debug:
          msg: kpg-fixture-role-handler
      KPG_ROLE_HANDLERS_EOF
      chmod 0755 #{FIXTURE_ROOT}/script.sh #{RETRY_SCRIPT} #{RETRY_NEVER_SCRIPT}
      chmod 0644 #{FIXTURE_ROOT}/src.txt #{FIXTURE_ROOT}/src2.txt #{FIXTURE_ROOT}/template.j2 #{FIXTURE_ROOT}/dir/inner.txt #{TASKS_FILE} #{BINARY_FILE} #{NO_NEWLINE_FILE} #{RICH_TEMPLATE}
      #{plugin_seed_script}
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
