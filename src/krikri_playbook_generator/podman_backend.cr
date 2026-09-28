require "./cmd"

module KrikriPlaybookGenerator
  class PodmanProvisionError < Exception
  end

  # Runs each playbook against both engines inside a pair of throwaway,
  # `--privileged` podman containers rather than on the machine running
  # this tool — the same pattern krikri's own testing/podman-diff/run.sh
  # already uses (see krikri/CLAUDE.md's "for plain systemd, podman run
  # --systemd=always remains sufficient" note). Since the containers are
  # disposable, happy-path tasks can run for real (no `--check` needed)
  # without risking the host.
  #
  # Unlike podman-diff, this installs one fixed, generic dependency set
  # rather than the dozens of per-module apt/collection installs
  # podman-diff's hand-picked case list gates on — this tool picks
  # modules randomly, so it can't know ahead of time which module-specific
  # library/binary/collection a given batch will need. A module needing
  # something outside that fixed set fails identically on both engines
  # (not a real divergence) in the common case, or — if only one engine
  # needs the missing dependency — can manufacture a false divergence;
  # documented known limitation, not silently papered over.
  class PodmanBackend
    IMAGE               = "docker.io/library/debian:bookworm-slim"
    REAL_PACKAGES       = "ansible-core python3 procps cron gnupg git"
    KRIKRI_RUNTIME_LIBS = "libxml2 libssl3 libyaml-0-2 libpcre2-8-0 python3 procps cron gnupg git"
    INVENTORY           = "target ansible_connection=local\n"

    def self.available? : Bool
      !!Process.find_executable("podman")
    end

    def initialize(@krikri_bin : String)
      suffix = "-#{Time.utc.to_unix}-#{Process.pid}"
      @name_real = "kpg-real#{suffix}"
      @name_krikri = "kpg-krikri#{suffix}"
      @started_names = [] of String
    end

    def provision : Nil
      start_container(@name_real)
      start_container(@name_krikri)

      install(@name_real, REAL_PACKAGES)
      install(@name_krikri, KRIKRI_RUNTIME_LIBS)
      stage_krikri_binary

      [@name_real, @name_krikri].each do |name|
        exec!(name, "mkdir -p /work")
        write_inventory(name)
      end
    end

    def run_playbook(playbook_path : String) : {ansible: Cmd::Result, krikri: Cmd::Result}
      basename = File.basename(playbook_path)
      copy_playbook(playbook_path, basename, @name_real)
      copy_playbook(playbook_path, basename, @name_krikri)

      ansible_result = Cmd.run("podman", ["exec", "-w", "/work", "-e", "ANSIBLE_NOCOLOR=1", @name_real,
                                          "ansible-playbook", "-i", "inventory.ini", basename])
      krikri_result = Cmd.run("podman", ["exec", "-w", "/work", "-e", "ANSIBLE_NOCOLOR=1", @name_krikri,
                                         "/opt/krikri/bin/krikri-playbook", "-i", "inventory.ini", basename])

      {ansible: ansible_result, krikri: krikri_result}
    end

    # A failed cp must stop before exec: otherwise both engines run
    # against a missing or stale playbook file and manufacture a
    # misleading "both failed identically" result instead of a clear
    # provisioning error.
    private def copy_playbook(playbook_path : String, basename : String, name : String) : Nil
      result = Cmd.run("podman", ["cp", playbook_path, "#{name}:/work/#{basename}"])
      raise PodmanProvisionError.new("podman cp #{basename.inspect} into #{name} failed: #{result.stderr}") unless Cmd.success?(result)
    end

    # Whatever actually started gets removed, even if provisioning failed
    # halfway through (e.g. the second container never came up) - otherwise
    # the already-running --privileged container would leak permanently.
    def teardown : Nil
      return if @started_names.empty?

      Cmd.run("podman", ["rm", "-f"] + @started_names)
      @started_names.clear
    end

    private def start_container(name : String) : Nil
      result = Cmd.run("podman", ["run", "-d", "--privileged", "--name", name, IMAGE, "sleep", "infinity"])
      raise PodmanProvisionError.new("podman run failed for #{name}: #{result.stderr}") unless Cmd.success?(result)
      @started_names << name
    end

    private def install(name : String, packages : String) : Nil
      exec!(name, "apt-get update -qq && apt-get install -y -qq --no-install-recommends #{packages} >/dev/null")
    end

    private def stage_krikri_binary : Nil
      plugins_dir = File.join(File.dirname(@krikri_bin), "plugins")
      exec!(@name_krikri, "mkdir -p /opt/krikri/bin")

      cp_result = Cmd.run("podman", ["cp", @krikri_bin, "#{@name_krikri}:/opt/krikri/bin/krikri-playbook"])
      raise PodmanProvisionError.new("podman cp krikri-playbook failed: #{cp_result.stderr}") unless Cmd.success?(cp_result)

      plugins_result = Cmd.run("podman", ["cp", plugins_dir, "#{@name_krikri}:/opt/krikri/bin/plugins"])
      raise PodmanProvisionError.new("podman cp plugins failed: #{plugins_result.stderr}") unless Cmd.success?(plugins_result)

      exec!(@name_krikri, "chmod +x /opt/krikri/bin/krikri-playbook /opt/krikri/bin/plugins/*")
    end

    private def write_inventory(name : String) : Nil
      result = Cmd.run("podman", ["exec", "-i", name, "bash", "-c", "cat > /work/inventory.ini"], input: INVENTORY)
      raise PodmanProvisionError.new("writing inventory.ini failed in #{name}: #{result.stderr}") unless Cmd.success?(result)
    end

    private def exec!(name : String, script : String) : Nil
      result = Cmd.run("podman", ["exec", name, "bash", "-c", script])
      raise PodmanProvisionError.new("provisioning #{name} failed: #{result.stderr}") unless Cmd.success?(result)
    end
  end
end
