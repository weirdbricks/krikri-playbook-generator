require "digest"
require "./cmd"
require "./dependencies"
require "./fixtures"
require "./log"

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
  # pair is removed in `ensure`, teardown removes whatever containers are
  # left, and `leak_check` verifies at the end that no kpg-* container
  # survived.
  #
  # The committed template images are a content-addressed CACHE, not
  # throwaways: each is tagged `<stable-name>:<fingerprint>`, where the
  # fingerprint is a SHA-256 over everything the template's content depends
  # on (profile, base image, package sets, expected ansible-core version,
  # krikri binary + plugins digests, the fixture seed script). When both
  # images for a profile's current fingerprint already exist, provisioning
  # is skipped entirely and the pair is started from the cached images;
  # only `--refresh-podman-templates` forces a rebuild (and then prunes
  # every other tag of the stable names). The version/binary assertions
  # still ran inside whatever build produced that tag, because a fingerprint
  # covers exactly the inputs those assertions check.
  #
  # Unlike podman-diff, this installs a UNION dependency set (the base
  # lists plus Dependencies#supported's extras) once per profile rather
  # than dozens of per-module installs gated on a hand-picked case
  # list - a randomly fuzzed batch can't gate per case, and two images
  # are far cheaper to provision than one per module. A module needing
  # something outside that union still fails identically on both
  # engines in the common case, or - if only one engine needs the
  # missing dependency - manufactures a false divergence; that residual
  # is a known limitation, fixed by promoting the module with its
  # dependency entry, never silently papered over.
  #
  # IMAGE's glibc must be new enough for whatever host built `krikri_bin`
  # (a plain `crystal build` - the default here, not `--static` - links
  # dynamically against the build host's glibc/openssl/pcre2/yaml/zstd).
  # trixie-slim matches this workspace's actual build hosts and still has
  # ansible-core packaged.
  class PodmanBackend
    IMAGE                    = "docker.io/library/debian:trixie-slim"
    EXPECTED_ANSIBLE_VERSION = "2.19.11"
    INVENTORY                = "target ansible_connection=local\n"
    ENGINE_ENV_STRIP         = "env -u ANSIBLE_GATHERING -u ANSIBLE_CACHE_PLUGIN -u ANSIBLE_CACHE_PLUGIN_CONNECTION ANSIBLE_NOCOLOR=1"
    OWNER_LABEL              = "krikri-owner-pid"

    # The rpm-family modules (dnf, dnf5, yum...) need rpm tooling and python
    # dnf bindings the Debian template can never have; they run against a
    # Rocky template pair instead, mirroring AtlanticBackend's "rpm" VM
    # profile (same Rocky major, same package set, same import-probe
    # behavior). Rocky 10's glibc (2.39) runs the trixie-built krikri
    # binary - AtlanticBackend stages the same binary onto its Rocky-10 VMs.
    IMAGE_RPM        = "quay.io/rockylinux/rockylinux:10"
    RPM_PACKAGES     = "python3 python3-pip python3-dnf python3-dnf-plugin-versionlock libyaml pcre2 openssl libxml2 zstd gmp gnupg2"
    ANSIBLE_CORE_PIN = "ansible-core==#{EXPECTED_ANSIBLE_VERSION}"

    enum Profile
      Debian
      Rpm
    end

    # Stable repository names for the content-addressed template image
    # cache: the fingerprint (a SHA-256 over the template's inputs) is the
    # tag, so an existing tag proves the image was built from exactly
    # today's package lists, binary and fixtures.
    IMAGE_NAME_REAL_DEBIAN   = "kpg-img-real-debian"
    IMAGE_NAME_KRIKRI_DEBIAN = "kpg-img-krikri-debian"
    IMAGE_NAME_REAL_RPM      = "kpg-img-real-rpm"
    IMAGE_NAME_KRIKRI_RPM    = "kpg-img-krikri-rpm"

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

    # Startup cleanup: every kpg-* container name ends in `-<unix>-<pid>`
    # (the naming suffix), so a leftover from a killed run can be
    # attributed to its owner pid and removed when that pid is no longer
    # alive - without the previous runs' ERROR noise in every later run.
    # Containers whose pid cannot be parsed are left alone (leak_check
    # still reports them); a live run's containers are never touched.
    def self.cleanup_stale : Array(String)
      stale = stale_containers(leak_check)
      return stale if stale.empty?

      Cmd.run("podman", ["rm", "-f"] + stale, timeout: 180.0)
      Log.info("podman", "startup: removed #{stale.size} stale container(s) from dead run(s): #{stale.join(", ")}")
      stale
    end

    # Visible for specs: filters the kpg-* names down to the ones whose
    # owner pid is dead (or unparseable names are kept out of removal).
    def self.stale_containers(names : Array(String)) : Array(String)
      names.select do |name|
        pid = name.split("-").last.to_i?
        pid && !Process.exists?(pid)
      end
    end

    def self.image_names(profile : Profile, fingerprint : String) : {String, String}
      if profile.debian?
        {"#{IMAGE_NAME_REAL_DEBIAN}:#{fingerprint}", "#{IMAGE_NAME_KRIKRI_DEBIAN}:#{fingerprint}"}
      else
        {"#{IMAGE_NAME_REAL_RPM}:#{fingerprint}", "#{IMAGE_NAME_KRIKRI_RPM}:#{fingerprint}"}
      end
    end

    def initialize(@krikri_bin : String, @engine_timeout : Int32 = 120, @control : Bool = false,
                   @module_fqcns : Array(String) = [] of String, @dependencies : Dependencies = Dependencies.load,
                   @refresh_templates : Bool = false)
      @suffix = "-#{Time.utc.to_unix}-#{Process.pid}"
      @name_real = ""
      @name_krikri = ""
      @images = {} of Profile => {String, String}
      @started_names = [] of String
      @run_index = 0
      @provisioned_profiles = [] of Profile
      @cache_hits = [] of Profile
      @stale_cleaned = false
    end

    def provision(profile : Profile = Profile::Debian) : Nil
      cleanup_stale_once
      label = profile.debian? ? "debian" : "rpm"
      Log.phase("podman", "#{label} template provisioning start") do
        provision_inner(profile)
      end
    end

    # Runs once per backend instance, right before the first provision -
    # before any container of this run exists, so this run's own
    # containers can never be swept by it.
    private def cleanup_stale_once : Nil
      return if @stale_cleaned

      @stale_cleaned = true
      PodmanBackend.cleanup_stale
    end

    private def provision_inner(profile : Profile) : Nil
      label = profile.debian? ? "debian" : "rpm"
      fingerprint = fingerprint(profile)
      real_image, krikri_image = PodmanBackend.image_names(profile, fingerprint)

      if !@refresh_templates && image_exists?(real_image) && image_exists?(krikri_image)
        Log.info("podman", "#{label} template cache hit (#{fingerprint}) - skipping provisioning")
        @images[profile] = {real_image, krikri_image}
        @provisioned_profiles << profile
        @cache_hits << profile
        return
      end

      @name_real = "kpg-tpl-real#{@suffix}"
      @name_krikri = "kpg-tpl-krikri#{@suffix}"
      sets = package_sets
      case profile
      when Profile::Debian
        Log.info("podman", "#{label} template: starting #{@name_real} + #{@name_krikri} (image #{IMAGE})")
        start_container(@name_real)
        start_container(@name_krikri)
        Log.info("podman", "#{label} template: installing #{sets.real_debian.size + sets.krikri_debian.size} packages " \
                           "(real #{sets.real_debian.size}, krikri #{sets.krikri_debian.size})")
        install(@name_real, sets.real_debian.join(" "))
        install(@name_krikri, sets.krikri_debian.join(" "))
      when Profile::Rpm
        @name_real = "kpg-rpmtpl-real#{@suffix}"
        @name_krikri = "kpg-rpmtpl-krikri#{@suffix}"
        Log.info("podman", "#{label} template: starting #{@name_real} + #{@name_krikri} (image #{IMAGE_RPM})")
        start_container(@name_real, IMAGE_RPM)
        start_container(@name_krikri, IMAGE_RPM)
        install_rpm(@name_real, with_ansible: true, packages: sets.real_rpm.join(" "))
        install_rpm(@name_krikri, with_ansible: false, packages: sets.krikri_rpm.join(" "))
      end
      unless sets.python.empty?
        Log.info("podman", "#{label} template: pip installing #{sets.python.join(" ")} (real side)")
        install_python(@name_real, sets.python)
      end
      unless sets.collections.empty?
        Log.info("podman", "#{label} template: galaxy installing #{sets.collections.join(" ")} (real side)")
        install_collections(@name_real, sets.collections)
      end

      Log.info("podman", "#{label} template: staging krikri-playbook binary")
      stage_krikri_binary
      Log.info("podman", "#{label} template: seeding fixtures (identical on both sides)")
      seed_fixtures
      Log.info("podman", "#{label} template: preparing /work + inventory")
      prepare_workdir
      Log.info("podman", "#{label} template: asserting ansible-core == #{EXPECTED_ANSIBLE_VERSION} / krikri binary")
      assert_ansible_version!
      assert_krikri_binary!
      Log.info("podman", "#{label} template: committing #{real_image} + #{krikri_image}")
      commit_templates(real_image, krikri_image)
      drop_templates
      if @refresh_templates
        prune_other_tags(real_image)
        prune_other_tags(krikri_image)
      end
      Log.info("podman", "#{label} template: ready (#{real_image})")
      @images[profile] = {real_image, krikri_image}
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

      # Per-profile images: a mixed batch provisions both templates, and a
      # playbook must run on the profile that matches its module (an apt
      # module can never pass on the Rocky pair).
      real_image, krikri_image = @images[profile]
      @run_index += 1
      real = "kpg-real-#{@run_index}#{@suffix}"
      krikri = "kpg-krikri-#{@run_index}#{@suffix}"
      created = [] of String

      begin
        start_from_image(real_image, real)
        created << real
        # --control: the "krikri" side is a second real-ansible container, so any
        # divergence is run-to-run noise or a harness asymmetry, never krikri.
        start_from_image(@control ? real_image : krikri_image, krikri)
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
    # The committed template images are deliberately KEPT: they are the
    # content-addressed cache the next run provision (or the next batch)
    # starts from, not results worth cleaning up.
    def teardown : Nil
      return if @started_names.empty?

      Log.info("podman", "teardown: removing #{@started_names.size} leftover container(s)")
      Cmd.run("podman", ["rm", "-f"] + @started_names, timeout: 180.0)
      @started_names.clear
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
    private def install_rpm(name : String, with_ansible : Bool, packages : String = RPM_PACKAGES) : Nil
      script = "dnf makecache -q 2>/dev/null || dnf makecache; " \
               "dnf install -y -q #{packages} >/dev/null"
      script += " && pip3 install --quiet #{ANSIBLE_CORE_PIN}" if with_ansible
      exec!(name, script, 900.0)
    end

    private def install_python(name : String, packages : Array(String)) : Nil
      exec!(name, "pip3 install --quiet #{packages.join(" ")}", 900.0)
    end

    private def install_python_rpm(name : String, packages : Array(String)) : Nil
      install_python(name, packages)
    end

    private def install_collections(name : String, collections : Array(String)) : Nil
      exec!(name, "ansible-galaxy collection install #{collections.join(" ")} >/dev/null 2>&1", 900.0)
    end

    private def package_sets : Dependencies::PackageSets
      selected = @module_fqcns.empty? ? @dependencies.supported : @module_fqcns
      @dependencies.package_sets(selected)
    end

    # Visible for specs: proves the union model computes the intended
    # template package set for a batch's modules.
    def package_sets_for_test : Dependencies::PackageSets
      package_sets
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

    private def commit_templates(real_image : String, krikri_image : String) : Nil
      [{@name_real, real_image}, {@name_krikri, krikri_image}].each do |(container, image)|
        result = Cmd.run("podman", ["commit", container, image], timeout: 600.0)
        raise PodmanProvisionError.new("podman commit #{container} -> #{image} failed: #{result.stderr}") unless Cmd.success?(result)
      end
    end

    # Only called in --refresh mode: a deliberate rebuild drops every other
    # tag of the stable repository name, so the cache resets to exactly the
    # freshly built fingerprint instead of accumulating stale ones.
    private def prune_other_tags(image : String) : Nil
      repository = image.split(":").first
      result = Cmd.run("podman", ["images", "--filter", "reference=#{repository}:*",
                                  "--format", "{{.Repository}}:{{.Tag}}"], timeout: 60.0)
      return unless Cmd.success?(result)

      stale = result.stdout.lines.reject!(&.blank?).uniq!.reject { |ref| ref == image }
      stale.each do |ref|
        Cmd.run("podman", ["rmi", ref], timeout: 300.0)
      end
    end

    private def image_exists?(reference : String) : Bool
      Cmd.success?(Cmd.run("podman", ["image", "exists", reference], timeout: 60.0))
    end

    # The cache key: a SHA-256 over every input the template's CONTENT
    # depends on. A change in any of them (package lists in
    # module_dependencies.yml, the ansible-core pin, the krikri binary or
    # plugins, the fixture seed script) yields a new tag and forces a
    # rebuild; everything else hits. Visible for specs - it is pure
    # computation, no podman involved.
    def fingerprint_for_test(profile : Profile = Profile::Debian) : String
      fingerprint(profile)
    end

    # Visible for specs: which profiles were satisfied from the image
    # cache rather than freshly provisioned.
    def cache_hit?(profile : Profile) : Bool
      @cache_hits.includes?(profile)
    end

    private def fingerprint(profile : Profile) : String
      sets = package_sets
      parts = [
        profile.to_s,
        profile.debian? ? IMAGE : IMAGE_RPM,
        EXPECTED_ANSIBLE_VERSION,
        ANSIBLE_CORE_PIN,
        sets.real_debian.join(","), sets.krikri_debian.join(","),
        sets.real_rpm.join(","), sets.krikri_rpm.join(","),
        sets.python.join(","), sets.collections.join(","),
        INVENTORY,
        content_digest(@krikri_bin),
        plugins_digest,
        Digest::SHA256.hexdigest(Fixtures::SEED_SCRIPT),
      ]
      Digest::SHA256.hexdigest(parts.join("\n"))[0, 16]
    end

    private def content_digest(path : String) : String
      Digest::SHA256.hexdigest(File.read(path))
    rescue e : Exception
      raise PodmanProvisionError.new("cannot fingerprint #{path.inspect}: #{e.message}")
    end

    # The krikri plugins dir is staged next to the binary; a missing one is
    # a provisioning error later, but the fingerprint just hashes what is
    # (or would be) staged.
    private def plugins_digest : String
      plugins_dir = File.join(File.dirname(@krikri_bin), "plugins")
      files = Dir.glob("#{plugins_dir}/*").select! { |path| File.file?(path) }.sort!
      files.join("\n") { |path| "#{File.basename(path)}:#{content_digest(path)}" }
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
