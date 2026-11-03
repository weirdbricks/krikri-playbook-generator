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
    # python3-pexpect: expect's real-ansible reference imports it; without
    # it every expect playbook is a harness gap rather than a test. Krikri's
    # own expect implementation needs it too (it shells to python pexpect),
    # so KRIKRI_RUNTIME_LIBS carries it as well.
    REAL_PACKAGES       = "ansible python3 python3-pexpect procps cron gnupg git openssh-client python3-apt python3-debian debconf-utils rsync sudo python3-idna"
    KRIKRI_RUNTIME_LIBS = "libxml2 libssl3 openssl libyaml-0-2 libpcre2-8-0 python3-cryptography python3-pexpect python3 procps cron gnupg git openssh-client python3-apt python3-debian debconf-utils rsync sudo"
    INVENTORY           = "target ansible_connection=local\n"
    ENGINE_ENV_STRIP    = "env -u ANSIBLE_GATHERING -u ANSIBLE_CACHE_PLUGIN -u ANSIBLE_CACHE_PLUGIN_CONNECTION ANSIBLE_NOCOLOR=1"
    OWNER_LABEL         = "krikri-owner-pid"

    # The rpm-family modules (dnf, dnf5, yum...) need rpm tooling and python
    # dnf bindings the Debian template can never have; they run against a
    # Rocky template pair instead, mirroring AtlanticBackend's "rpm" VM
    # profile (same Rocky major, same package set, same import-probe
    # behavior). Rocky 10's glibc (2.39) runs the trixie-built krikri
    # binary - AtlanticBackend stages the same binary onto its Rocky-10 VMs.
    IMAGE_RPM = "quay.io/rockylinux/rockylinux:10"
    # python3-dnf-plugin-versionlock mirrors the Atlantic rpm profile;
    # versionlock IS in Rocky's repos. dnf5's python bindings do not exist
    # in Rocky 10's repos, so real ansible's dnf5 fails its import probe -
    # that failure is still comparable byte-for-byte (krikri probes the
    # same python path), only the dnf5 happy paths count as wasted coverage.
    RPM_PACKAGES     = "python3 python3-pip python3-dnf python3-dnf-plugin-versionlock libyaml pcre2 openssl libxml2 zstd gmp"
    ANSIBLE_CORE_PIN = "ansible-core==#{EXPECTED_ANSIBLE_VERSION}"

    enum Profile
      Debian
      Rpm
    end

    def self.available? : Bool
      !!Process.find_executable("podman")
    end

    # Every container this tool starts carries `OWNER_LABEL=<pid>` so external
    # tooling can tell a live kpg run's containers from abandoned ones, and
    # boots the fixture http.server (Fixtures::HTTP_PORT) before sleeping:
    # get_url/uri happy paths need a URL that resolves identically on both
    # engine sides. The template containers start it before python3 is
    # installed - the background job just fails there, and every container
    # started FROM the committed images (python3 installed) gets a live
    # server.
    def self.run_args(image : String, name : String) : Array(String)
      bootstrap = "python3 -m http.server #{Fixtures::HTTP_PORT} --bind 127.0.0.1 --directory #{Fixtures::FIXTURE_ROOT} >/dev/null 2>&1 & exec sleep infinity"
      ["run", "-d", "--privileged", "--label", "#{OWNER_LABEL}=#{Process.pid}", "--name", name, image, "sh", "-c", bootstrap]
    end

    # Any kpg-* container still listed by `podman ps -a` after teardown is
    # a leak - reported to the caller, never left silent.
    def self.leak_check : Array(String)
      result = Cmd.run("podman", ["ps", "-a", "--filter", "name=kpg-", "--format", "{{.Names}}"], timeout: 60.0)
      return [] of String unless Cmd.success?(result)

      result.stdout.lines.reject(&.blank?)
    end

    def initialize(@krikri_bin : String, @engine_timeout : Int32 = 120, @control : Bool = false)
      @suffix = "-#{Time.utc.to_unix}-#{Process.pid}"
      @name_real = ""
      @name_krikri = ""
      @image_real = ""
      @image_krikri = ""
      @started_names = [] of String
      @run_index = 0
      @provisioned_profiles = [] of Profile
      @committed_images = [] of String
    end

    def provision(profile : Profile = Profile::Debian) : Nil
      case profile
      when Profile::Debian
        @name_real = "kpg-tpl-real#{@suffix}"
        @name_krikri = "kpg-tpl-krikri#{@suffix}"
        @image_real = "kpg-img-real#{@suffix}"
        @image_krikri = "kpg-img-krikri#{@suffix}"
        start_container(@name_real)
        start_container(@name_krikri)
        install(@name_real, REAL_PACKAGES)
        install(@name_krikri, KRIKRI_RUNTIME_LIBS)
      when Profile::Rpm
        @name_real = "kpg-rpmtpl-real#{@suffix}"
        @name_krikri = "kpg-rpmtpl-krikri#{@suffix}"
        @image_real = "kpg-img-real-rpm#{@suffix}"
        @image_krikri = "kpg-img-krikri-rpm#{@suffix}"
        start_container(@name_real, IMAGE_RPM)
        start_container(@name_krikri, IMAGE_RPM)
        install_rpm(@name_real, with_ansible: true)
        install_rpm(@name_krikri, with_ansible: false)
      end

      stage_krikri_binary
      seed_fixtures
      prepare_workdir
      assert_ansible_version!
      assert_krikri_binary!
      commit_templates
      drop_templates

      @provisioned_profiles << profile
    end

    # Runs one playbook in a fresh container pair started from the
    # committed template images. Both engines get the identical invocation:
    # same absolute playbook path (/work/<basename>), same cwd (-w /work),
    # ANSIBLE_NOCOLOR=1, the caching/gathering env vars stripped, stdin
    # </dev/null, and a per-engine `timeout` so a hang is its own result
    # (rc 124) instead of wedging the batch.
    def run_playbook(playbook_path : String, profile : Profile = Profile::Debian) : {ansible: Cmd::Result, krikri: Cmd::Result}
      raise PodmanProvisionError.new("provision was never called for profile #{profile}") unless @provisioned_profiles.includes?(profile)

      @run_index += 1
      real = "kpg-real-#{@run_index}#{@suffix}"
      krikri = "kpg-krikri-#{@run_index}#{@suffix}"
      created = [] of String

      begin
        start_from_image(@image_real, real)
        created << real
        # --control: the "krikri" side is a second real-ansible container, so any
        # divergence is run-to-run noise or a harness asymmetry, never krikri.
        start_from_image(@control ? @image_real : @image_krikri, krikri)
        created << krikri

        copy_playbook(playbook_path, real)
        copy_playbook(playbook_path, krikri)

        {ansible: exec_engine(real, "ansible-playbook", playbook_path),
         krikri:  exec_engine(krikri, @control ? "ansible-playbook" : "/opt/krikri/bin/krikri-playbook", playbook_path)}
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

      @committed_images.each do |image|
        Cmd.run("podman", ["rmi", "-f", image], timeout: 180.0)
      end
    end

    private def start_container(name : String, image : String = IMAGE) : Nil
      result = Cmd.run("podman", PodmanBackend.run_args(image, name), timeout: 300.0)
      raise PodmanProvisionError.new("podman run failed for #{name}: #{result.stderr}") unless Cmd.success?(result)
      @started_names << name
    end

    private def start_from_image(image : String, name : String) : Nil
      result = Cmd.run("podman", PodmanBackend.run_args(image, name), timeout: 300.0)
      raise PodmanProvisionError.new("podman run failed for #{name}: #{result.stderr}") unless Cmd.success?(result)
      @started_names << name
    end

    private def install(name : String, packages : String) : Nil
      # The `ansible` package's postinst byte-compiles collection files whose
      # names exceed the filesystem limit (pyc "File name too long"); neutralize
      # py3compile first so the install (and the collections) succeed.
      prep = packages.split.includes?("ansible") ? "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --no-install-recommends python3-minimal >/dev/null && dpkg-divert --local --rename --add /usr/bin/py3compile >/dev/null && ln -sf /bin/true /usr/bin/py3compile && " : "export DEBIAN_FRONTEND=noninteractive; "
      exec!(name, "#{prep}apt-get update -qq && apt-get install -y -qq --no-install-recommends #{packages} >/dev/null", 900.0)
    end

    # The rpm template pair shares one prep: dnf packages everywhere, the
    # pinned ansible-core only where the real engine runs (the version
    # assertion below would fail on a distro ansible-core otherwise).
    private def install_rpm(name : String, with_ansible : Bool) : Nil
      script = "dnf makecache -q 2>/dev/null || dnf makecache; " \
               "dnf install -y -q #{RPM_PACKAGES} >/dev/null"
      script += " && pip3 install --quiet #{ANSIBLE_CORE_PIN}" if with_ansible
      exec!(name, script, 900.0)
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

    # The krikri container shares the template pair's OS, and the binary was
    # linked on the build host - a smoke check here catches a glibc/lib
    # mismatch at provision time instead of as 10 mysterious engine errors.
    private def assert_krikri_binary! : Nil
      result = Cmd.run("podman", ["exec", @name_krikri, "/opt/krikri/bin/krikri-playbook", "--version"], timeout: 120.0)
      unless Cmd.success?(result)
        raise PodmanProvisionError.new("staged krikri binary fails to run in the container (glibc/lib mismatch?): #{result.stderr}")
      end
    end

    private def commit_templates : Nil
      [{@name_real, @image_real}, {@name_krikri, @image_krikri}].each do |(container, image)|
        result = Cmd.run("podman", ["commit", container, image], timeout: 300.0)
        raise PodmanProvisionError.new("podman commit #{container} -> #{image} failed: #{result.stderr}") unless Cmd.success?(result)
        @committed_images << image
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
