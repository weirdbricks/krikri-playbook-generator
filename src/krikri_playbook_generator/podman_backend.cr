require "./cmd"
require "./fixtures"

module KrikriPlaybookGenerator
  class PodmanProvisionError < Exception
  end

  # Runs each playbook against both engines inside throwaway, `--privileged`
  # podman containers rather than on the machine running this tool - the
  # same pattern krikri's own testing/podman-diff/run.sh already uses.
  #
  # Provisioning is done ONCE: a template container pair gets the runtime
  # dependencies, the krikri binary, the inventory and the identical
  # Fixtures tree seeded into it, its ansible-core version is asserted to
  # be EXPECTED_ANSIBLE_VERSION (byte-parity comparisons are meaningless
  # across engine versions - fail loudly instead of silently comparing
  # against the wrong one), and both containers are `podman commit`ed into
  # images. Every playbook then gets a FRESH pair started from those
  # images, so nothing leaks between playbooks: users created by playbook
  # N don't exist for playbook N+1, /tmp/kpg-work starts empty every time,
  # and a hang or crash can't poison the next comparison. Each per-playbook
  # pair is removed in `ensure`, teardown removes whatever is left plus
  # the committed images, and `leak_check` verifies at the end that no
  # kpg-* container survived.
  #
  # Unlike podman-diff, this installs one fixed, generic dependency set
  # rather than the dozens of per-module apt/collection installs
  # podman-diff's hand-picked case list gates on - this tool picks
  # modules randomly, so it can't know ahead of time which module-specific
  # library/binary/collection a given batch will need. A module needing
  # something outside that fixed set fails identically on both engines
  # (not a real divergence) in the common case, or - if only one engine
  # needs the missing dependency - can manufacture a false divergence;
  # documented known limitation, not silently papered over.
  #
  # IMAGE's glibc must be new enough for whatever host built `krikri_bin`
  # (a plain `crystal build` - the default here, not `--static` - links
  # dynamically against the build host's glibc/openssl/pcre2/yaml/zstd).
  # trixie-slim matches this workspace's actual build hosts and still has
  # ansible-core packaged.
  class PodmanBackend
    IMAGE                    = "docker.io/library/debian:trixie-slim"
    EXPECTED_ANSIBLE_VERSION = "2.19.11"
    REAL_PACKAGES            = "ansible-core python3 procps cron gnupg git openssh-client python3-apt python3-debian debconf-utils"
    KRIKRI_RUNTIME_LIBS      = "libxml2 libssl3 libyaml-0-2 libpcre2-8-0 python3 procps cron gnupg git openssh-client python3-apt python3-debian debconf-utils"
    INVENTORY                = "target ansible_connection=local\n"
    ENGINE_ENV_STRIP         = "env -u ANSIBLE_GATHERING -u ANSIBLE_CACHE_PLUGIN -u ANSIBLE_CACHE_PLUGIN_CONNECTION ANSIBLE_NOCOLOR=1"

    def self.available? : Bool
      !!Process.find_executable("podman")
    end

    # Any kpg-* container still listed by `podman ps -a` after teardown is
    # a leak - reported to the caller, never left silent.
    def self.leak_check : Array(String)
      result = Cmd.run("podman", ["ps", "-a", "--filter", "name=kpg-", "--format", "{{.Names}}"], timeout: 60.0)
      return [] of String unless Cmd.success?(result)

      result.stdout.lines.reject(&.blank?)
    end

    def initialize(@krikri_bin : String, @engine_timeout : Int32 = 120)
      @suffix = "-#{Time.utc.to_unix}-#{Process.pid}"
      @name_real = "kpg-tpl-real#{@suffix}"
      @name_krikri = "kpg-tpl-krikri#{@suffix}"
      @image_real = "kpg-img-real#{@suffix}"
      @image_krikri = "kpg-img-krikri#{@suffix}"
      @started_names = [] of String
      @run_index = 0
      @provisioned = false
    end

    def provision : Nil
      start_container(@name_real)
      start_container(@name_krikri)

      install(@name_real, REAL_PACKAGES)
      install(@name_krikri, KRIKRI_RUNTIME_LIBS)
      stage_krikri_binary
      seed_fixtures
      prepare_workdir

      assert_ansible_version!
      commit_templates
      drop_templates

      @provisioned = true
    end

    # Runs one playbook in a fresh container pair started from the
    # committed template images. Both engines get the identical invocation:
    # same absolute playbook path (/work/<basename>), same cwd (-w /work),
    # ANSIBLE_NOCOLOR=1, the caching/gathering env vars stripped, stdin
    # </dev/null, and a per-engine `timeout` so a hang is its own result
    # (rc 124) instead of wedging the batch.
    def run_playbook(playbook_path : String) : {ansible: Cmd::Result, krikri: Cmd::Result}
      raise PodmanProvisionError.new("provision was never called") unless @provisioned

      @run_index += 1
      real = "kpg-real-#{@run_index}#{@suffix}"
      krikri = "kpg-krikri-#{@run_index}#{@suffix}"
      created = [] of String

      begin
        start_from_image(@image_real, real)
        created << real
        start_from_image(@image_krikri, krikri)
        created << krikri

        copy_playbook(playbook_path, real)
        copy_playbook(playbook_path, krikri)

        {ansible: exec_engine(real, "ansible-playbook", playbook_path),
         krikri:  exec_engine(krikri, "/opt/krikri/bin/krikri-playbook", playbook_path)}
      ensure
        unless created.empty?
          Cmd.run("podman", ["rm", "-f"] + created, timeout: 180.0)
          created.each { |name| @started_names.delete(name) }
        end
      end
    end

    # Whatever actually started gets removed, even if provisioning failed
    # halfway through (e.g. the second container never came up) - otherwise
    # the already-running --privileged container would leak permanently.
    # The committed images are removed too: they're just frozen templates,
    # not results worth keeping.
    def teardown : Nil
      unless @started_names.empty?
        Cmd.run("podman", ["rm", "-f"] + @started_names, timeout: 180.0)
        @started_names.clear
      end

      [@image_real, @image_krikri].each do |image|
        Cmd.run("podman", ["rmi", "-f", image], timeout: 180.0)
      end
    end

    private def start_container(name : String) : Nil
      result = Cmd.run("podman", ["run", "-d", "--privileged", "--name", name, IMAGE, "sleep", "infinity"], timeout: 300.0)
      raise PodmanProvisionError.new("podman run failed for #{name}: #{result.stderr}") unless Cmd.success?(result)
      @started_names << name
    end

    private def start_from_image(image : String, name : String) : Nil
      result = Cmd.run("podman", ["run", "-d", "--privileged", "--name", name, image, "sleep", "infinity"], timeout: 300.0)
      raise PodmanProvisionError.new("podman run failed for #{name}: #{result.stderr}") unless Cmd.success?(result)
      @started_names << name
    end

    private def install(name : String, packages : String) : Nil
      exec!(name, "apt-get update -qq && apt-get install -y -qq --no-install-recommends #{packages} >/dev/null", 900.0)
    end

    private def stage_krikri_binary : Nil
      plugins_dir = File.join(File.dirname(@krikri_bin), "plugins")
      raise PodmanProvisionError.new("krikri plugins dir #{plugins_dir.inspect} not found next to #{@krikri_bin.inspect}") unless File.exists?(plugins_dir)

      exec!(@name_krikri, "mkdir -p /opt/krikri/bin")

      cp_result = Cmd.run("podman", ["cp", @krikri_bin, "#{@name_krikri}:/opt/krikri/bin/krikri-playbook"], timeout: 300.0)
      raise PodmanProvisionError.new("podman cp krikri-playbook failed: #{cp_result.stderr}") unless Cmd.success?(cp_result)

      plugins_result = Cmd.run("podman", ["cp", plugins_dir, "#{@name_krikri}:/opt/krikri/bin/plugins"], timeout: 300.0)
      raise PodmanProvisionError.new("podman cp plugins failed: #{plugins_result.stderr}") unless Cmd.success?(plugins_result)

      exec!(@name_krikri, "chmod +x /opt/krikri/bin/krikri-playbook /opt/krikri/bin/plugins/*")
    end

    # Fixtures must be seeded identically into BOTH containers here, before
    # any playbook exists - never via playbook tasks, which would make the
    # seeding itself part of the compared output.
    private def seed_fixtures : Nil
      [@name_real, @name_krikri].each do |name|
        result = Cmd.run("podman", ["exec", "-i", name, "bash", "-s"], input: Fixtures::SEED_SCRIPT, timeout: 120.0)
        raise PodmanProvisionError.new("seeding fixtures into #{name} failed: #{result.stderr}") unless Cmd.success?(result)
      end
    end

    private def prepare_workdir : Nil
      [@name_real, @name_krikri].each do |name|
        exec!(name, "mkdir -p /work")
        write_inventory(name)
      end
    end

    private def write_inventory(name : String) : Nil
      result = Cmd.run("podman", ["exec", "-i", name, "bash", "-c", "cat > /work/inventory.ini"], input: INVENTORY, timeout: 60.0)
      raise PodmanProvisionError.new("writing inventory.ini failed in #{name}: #{result.stderr}") unless Cmd.success?(result)
    end

    private def assert_ansible_version! : Nil
      result = Cmd.run("podman", ["exec", @name_real, "ansible-playbook", "--version"], timeout: 120.0)
      unless Cmd.success?(result)
        raise PodmanProvisionError.new("ansible-playbook --version failed in container: #{result.stderr}")
      end

      version = result.stdout.match(/core (\d+\.\d+\.\d+)/).try(&.[1])
      unless version == EXPECTED_ANSIBLE_VERSION
        raise PodmanProvisionError.new(
          "container ansible-core is #{version.inspect}, expected #{EXPECTED_ANSIBLE_VERSION} - " \
          "byte-parity comparisons against a different engine version are meaningless; " \
          "install the expected version or update EXPECTED_ANSIBLE_VERSION deliberately")
      end
    end

    private def commit_templates : Nil
      [{@name_real, @image_real}, {@name_krikri, @image_krikri}].each do |(container, image)|
        result = Cmd.run("podman", ["commit", container, image], timeout: 300.0)
        raise PodmanProvisionError.new("podman commit #{container} -> #{image} failed: #{result.stderr}") unless Cmd.success?(result)
      end
    end

    private def drop_templates : Nil
      [@name_real, @name_krikri].each do |name|
        Cmd.run("podman", ["rm", "-f", name], timeout: 180.0)
        @started_names.delete(name)
      end
    end

    # A failed cp must stop before exec: otherwise both engines run
    # against a missing or stale playbook file and manufacture a
    # misleading "both failed identically" result instead of a clear
    # provisioning error.
    private def copy_playbook(playbook_path : String, name : String) : Nil
      basename = File.basename(playbook_path)
      result = Cmd.run("podman", ["cp", playbook_path, "#{name}:/work/#{basename}"], timeout: 120.0)
      raise PodmanProvisionError.new("podman cp #{basename.inspect} into #{name} failed: #{result.stderr}") unless Cmd.success?(result)
    end

    private def exec_engine(name : String, engine_cmd : String, playbook_path : String) : Cmd::Result
      basename = File.basename(playbook_path)
      script = "cd /work && #{ENGINE_ENV_STRIP} timeout #{@engine_timeout} " \
               "#{engine_cmd} -i inventory.ini /work/#{basename} </dev/null"
      Cmd.run("podman", ["exec", "-w", "/work", name, "bash", "-c", script], timeout: @engine_timeout + 60.0)
    end

    private def exec!(name : String, script : String, timeout : Float64 = 120.0) : Nil
      result = Cmd.run("podman", ["exec", name, "bash", "-c", script], timeout: timeout)
      raise PodmanProvisionError.new("provisioning #{name} failed: #{result.stderr}") unless Cmd.success?(result)
    end
  end
end
