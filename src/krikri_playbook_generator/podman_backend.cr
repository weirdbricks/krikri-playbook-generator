require "digest"
require "./cmd"
require "./dependencies"
require "./fixtures"
require "./host_state"
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
  # The committed template images are a two-level content-addressed CACHE,
  # not throwaways. The BASE pair (`kpg-base-*:<base fingerprint>`) carries
  # everything the package layer depends on (profile, base image, package
  # sets, expected ansible-core version, fixtures, inventory) and is built by
  # an apt/dnf install, so it changes only when one of those lists does. The
  # FULL pair (`kpg-img-*:<fingerprint>`) is the base plus the staged krikri
  # binary and plugins. When both full images exist, provisioning is skipped
  # and the pair is started from them; when only the base exists, the pair is
  # started from it and just the binary layer is committed. That second case
  # is the common one: every cycle's fix passes rebuild `krikri-playbook`, and
  # keying the package install on its digest cost an apt install plus a
  # ~600 MB commit per cycle (220-350 s measured) for a 27 MB binary change.
  # Only `--refresh-podman-templates` forces a rebuild from the base image (a
  # build also caps each stable name at the newest MAX_CACHED_TEMPLATES tags).
  # The version/binary assertions still ran inside whatever build produced
  # that tag, because a fingerprint covers exactly the inputs those
  # assertions check.
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
    EXPECTED_ANSIBLE_VERSION = "2.21.6"
    INVENTORY                = "target ansible_connection=local\n"
    ENGINE_ENV_STRIP         = KrikriPlaybookGenerator::ENGINE_ENV_STRIP
    OWNER_LABEL              = "krikri-owner-pid"

    # The rpm-family modules (dnf, dnf5, yum...) need rpm tooling and python
    # dnf bindings the Debian template can never have; they run against a
    # Rocky template pair instead, mirroring AtlanticBackend's "rpm" VM
    # profile (same Rocky major, same package set, same import-probe
    # behavior). Rocky 10's glibc (2.39) runs the trixie-built krikri
    # binary - AtlanticBackend stages the same binary onto its Rocky-10 VMs.
    IMAGE_RPM = "quay.io/rockylinux/rockylinux:10"
    # libxcrypt-compat provides libcrypt.so.1, which the host-built krikri
    # binary links (Crystal pulls it for crypt(3)) and Rocky 10's default
    # package set no longer ships - the staged binary died with "cannot
    # open shared object file" right after the version assertion without
    # it (found launching the first 2.21.6 batch).
    RPM_PACKAGES     = "python3 python3-pip python3-dnf python3-dnf-plugin-versionlock libyaml pcre2 openssl libxml2 zstd gmp gnupg2 libxcrypt-compat"
    ANSIBLE_CORE_PIN = "ansible-core==#{EXPECTED_ANSIBLE_VERSION}"

    enum Profile
      Debian
      Rpm
    end

    # Stable repository names for the content-addressed template image
    # cache: the fingerprint (a SHA-256 over the template's inputs) is the
    # tag, so an existing tag proves the image was built from exactly
    # today's package lists, binary and fixtures. The cache is capped at
    # MAX_CACHED_TEMPLATES newest tags per stable name.
    IMAGE_NAME_REAL_DEBIAN   = "kpg-img-real-debian"
    IMAGE_NAME_KRIKRI_DEBIAN = "kpg-img-krikri-debian"
    IMAGE_NAME_REAL_RPM      = "kpg-img-real-rpm"
    IMAGE_NAME_KRIKRI_RPM    = "kpg-img-krikri-rpm"

    # The binary-free package layer the full images are built on top of. Its
    # fingerprint deliberately excludes the krikri binary and plugins, so a
    # rebuilt engine reuses this pair instead of re-running apt/dnf.
    IMAGE_NAME_BASE_REAL_DEBIAN   = "kpg-base-real-debian"
    IMAGE_NAME_BASE_KRIKRI_DEBIAN = "kpg-base-krikri-debian"
    IMAGE_NAME_BASE_REAL_RPM      = "kpg-base-real-rpm"
    IMAGE_NAME_BASE_KRIKRI_RPM    = "kpg-base-krikri-rpm"
    MAX_CACHED_TEMPLATES          = 10

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

    def self.base_image_names(profile : Profile, fingerprint : String) : {String, String}
      if profile.debian?
        {"#{IMAGE_NAME_BASE_REAL_DEBIAN}:#{fingerprint}", "#{IMAGE_NAME_BASE_KRIKRI_DEBIAN}:#{fingerprint}"}
      else
        {"#{IMAGE_NAME_BASE_REAL_RPM}:#{fingerprint}", "#{IMAGE_NAME_BASE_KRIKRI_RPM}:#{fingerprint}"}
      end
    end

    # Visible for specs: the identical bash script both engines exec.
    # `--diff` is on by default (see Options#diff): diff output is a large
    # part of user-visible behavior, it is compared byte-for-byte like the
    # rest of stdout, and it is masked by nothing - a formatting gap is a
    # finding, not a reason to switch the flag off.
    #
    # The umask and the fixture owner/group are part of the invocation so
    # both sides see the same environment; `kpg_owner`/`kpg_group` are the
    # values the generator's owner/group options template to, defaulting
    # to root for the root profile and to the unprivileged account for
    # `--user-profile nonroot` (a non-root task cannot chown to root).
    def self.engine_script(engine_cmd : String, playbook_basename : String, engine_timeout : Int32,
                           check : Bool, diff : Bool = true, umask : String = DEFAULT_UMASK,
                           owner : String = "root", group : String = "root",
                           env : Hash(String, String) = {} of String => String,
                           limit : String? = nil) : String
      limit_flag = limit.try { |pattern| " --limit #{Process.quote(pattern)}" } || ""
      "umask #{umask} && cd /work && #{ENGINE_ENV_STRIP} #{KrikriPlaybookGenerator.env_prefix(env)}timeout #{engine_timeout} " \
      "#{engine_cmd}#{check ? " --check" : ""}#{diff ? " --diff" : ""}#{limit_flag} " \
      "-e kpg_owner=#{owner} -e kpg_group=#{group} " \
      "-i inventory.ini /work/#{playbook_basename} </dev/null"
    end

    def initialize(@krikri_bin : String, @engine_timeout : Int32 = 120, @control : Bool = false,
                   @module_fqcns : Array(String) = [] of String, @dependencies : Dependencies = Dependencies.load,
                   @refresh_templates : Bool = false, @check_mode : Bool = false,
                   @diff : Bool = true)
      @suffix = "-#{Time.utc.to_unix}-#{Process.pid}"
      @name_real = ""
      @name_krikri = ""
      @images = {} of Profile => {String, String}
      @started_names = [] of String
      @run_index = 0
      @provisioned_profiles = [] of Profile
      @cache_hits = [] of Profile
      @base_cache_hits = [] of Profile
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

      base_fingerprint = base_fingerprint(profile)
      base_real, base_krikri = PodmanBackend.base_image_names(profile, base_fingerprint)
      @name_real = profile.debian? ? "kpg-tpl-real#{@suffix}" : "kpg-rpmtpl-real#{@suffix}"
      @name_krikri = profile.debian? ? "kpg-tpl-krikri#{@suffix}" : "kpg-rpmtpl-krikri#{@suffix}"

      base_hit = !@refresh_templates && image_exists?(base_real) && image_exists?(base_krikri)
      if base_hit
        # The package layer is the expensive half, and it is the half the
        # krikri binary never touches: start from the cached base pair and
        # commit only the staged binary on top of it.
        Log.info("podman", "#{label} template base cache hit (#{base_fingerprint}) - " \
                           "starting #{@name_real} + #{@name_krikri} from #{base_real}")
        start_from_image(base_real, @name_real)
        start_from_image(base_krikri, @name_krikri)
        @base_cache_hits << profile
      else
        build_package_layer(profile, label)
      end

      Log.info("podman", "#{label} template: asserting ansible-core == #{EXPECTED_ANSIBLE_VERSION}")
      assert_ansible_version!
      unless base_hit
        Log.info("podman", "#{label} template: committing base #{base_real} + #{base_krikri}")
        commit_and_prune(base_real, base_krikri)
      end

      Log.info("podman", "#{label} template: staging krikri-playbook binary")
      stage_krikri_binary
      assert_krikri_binary!
      Log.info("podman", "#{label} template: committing #{real_image} + #{krikri_image}")
      commit_and_prune(real_image, krikri_image)
      drop_templates
      Log.info("podman", "#{label} template: ready (#{real_image})")
      @images[profile] = {real_image, krikri_image}
      @provisioned_profiles << profile
    end

    # The expensive half of the template: the union dependency set installed
    # into a fresh pair from the base image, then fixtures and the inventory.
    # Everything the krikri binary does not touch, so its result is worth
    # committing on its own as the base pair.
    private def build_package_layer(profile : Profile, label : String) : Nil
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
        # Debian trixie's apt ansible-core is 2.19.x, and the version
        # assertion below demands EXPECTED_ANSIBLE_VERSION - byte-parity
        # comparisons against a different core are meaningless. Pip
        # provides the pinned core over the distro one (/usr/local/bin
        # shadows /usr/bin); trixie's pip is PEP 668 externally-managed,
        # hence --break-system-packages.
        exec!(@name_real, "export DEBIAN_FRONTEND=noninteractive; " \
                          "apt-get install -y -qq --no-install-recommends python3-pip >/dev/null && " \
                          "pip3 install --quiet --break-system-packages --ignore-installed #{ANSIBLE_CORE_PIN}", 900.0)
      when Profile::Rpm
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
        assert_collection_versions!(sets.collections)
      end

      Log.info("podman", "#{label} template: provisioning the #{Fixtures::UNPRIVILEGED_USER} account")
      [@name_real, @name_krikri].each { |name| exec!(name, Fixtures::IDENTITY_SCRIPT) }
      Log.info("podman", "#{label} template: seeding fixtures (identical on both sides)")
      seed_fixtures
      Log.info("podman", "#{label} template: preparing /work + inventory")
      prepare_workdir
    end

    private def commit_and_prune(real_image : String, krikri_image : String) : Nil
      commit_templates(real_image, krikri_image)
      prune_other_tags(real_image)
      prune_other_tags(krikri_image)
    end

    # Runs one playbook in a fresh container pair started from the
    # committed template images. Both engines get the identical invocation:
    # same absolute playbook path (/work/<basename>), same cwd (-w /work),
    # ANSIBLE_NOCOLOR=1, the caching/gathering env vars stripped, stdin
    # </dev/null, and a per-engine `timeout` so a hang is its own result
    # (rc 124) instead of wedging the batch.
    #
    # Each engine's host is also snapshotted before and after its run, so
    # Runner can compare what the two engines actually changed (the state
    # oracle); the pair is isolated per playbook, so the before/after delta
    # belongs to that engine alone.
    #
    # Every call gets a fresh pair, so the mode matrix (check vs real)
    # simply calls this once per mode. `second_run` re-runs the playbook on
    # the SAME pair after the first run succeeded on both engines (the
    # idempotency pass); each pass is returned separately.
    def run_playbook(playbook_path : String, profile : Profile = Profile::Debian,
                     check : Bool? = nil, second_run : Bool = false,
                     diff : Bool? = nil, user : UserProfile = UserProfile::Root,
                     umask : String = DEFAULT_UMASK, hosts : Int32 = 1,
                     env : Hash(String, String) = {} of String => String,
                     limit : String? = nil,
                     include_unreachable : Bool = false) : Array(HostState::Comparison)
      raise PodmanProvisionError.new("provision was never called for profile #{profile}") unless @provisioned_profiles.includes?(profile)

      # Per-profile images: a mixed batch provisions both templates, and a
      # playbook must run on the profile that matches its module (an apt
      # module can never pass on the Rocky pair).
      real_image, krikri_image = @images[profile]
      @run_index += 1
      real = "kpg-real-#{@run_index}#{@suffix}"
      krikri = "kpg-krikri-#{@run_index}#{@suffix}"
      created = [] of String
      effective_check = check.nil? ? @check_mode : check
      effective_diff = diff.nil? ? @diff : diff
      krikri_engine = @control ? "ansible-playbook" : "/opt/krikri/bin/krikri-playbook"

      begin
        start_from_image(real_image, real)
        created << real
        # --control: the "krikri" side is a second real-ansible container, so any
        # divergence is run-to-run noise or a harness asymmetry, never krikri.
        start_from_image(@control ? real_image : krikri_image, krikri)
        created << krikri

        copy_playbook(playbook_path, real)
        copy_playbook(playbook_path, krikri)
        # The writable fixture root is re-owned for this row's identity
        # before the first snapshot, so both engines start identical and
        # the chown itself never shows up as a mutation.
        ownership = Fixtures.ownership_command(user)
        exec!(real, ownership)
        exec!(krikri, ownership)
        # The host-count axis rebuilds the inventory per pair: both engines
        # must see the same N local aliases, and the committed template's
        # one-host inventory cannot express a per-row count.
        inventory = HostInventory.render(hosts, include_unreachable)
        write_inventory(real, inventory)
        write_inventory(krikri, inventory)

        runs = [] of HostState::Comparison
        runs << comparison(real, krikri, playbook_path, krikri_engine, effective_check, effective_diff,
          user, umask, env, limit)
        if second_run && HostState.succeeded?(runs.first[:ansible]) &&
           HostState.succeeded?(runs.first[:krikri])
          runs << comparison(real, krikri, playbook_path, krikri_engine, effective_check, effective_diff,
            user, umask, env, limit)
        end
        runs
      ensure
        unless created.empty?
          Cmd.run("podman", ["rm", "-f"] + created, timeout: 180.0)
          created.each { |name| @started_names.delete(name) }
        end
      end
    end

    private def comparison(real : String, krikri : String, playbook_path : String,
                           krikri_engine : String, check : Bool, diff : Bool,
                           user : UserProfile, umask : String,
                           env : Hash(String, String) = {} of String => String,
                           limit : String? = nil) : HostState::Comparison
      {ansible: observe(real, "ansible-playbook", playbook_path, check, diff, user, umask, env, limit),
       krikri:  observe(krikri, krikri_engine, playbook_path, check, diff, user, umask, env, limit)}
    end

    private def observe(name : String, engine_cmd : String, playbook_path : String,
                        check : Bool, diff : Bool, user : UserProfile,
                        umask : String,
                        env : Hash(String, String) = {} of String => String,
                        limit : String? = nil) : HostState::Observation
      before = snapshot_state(name)
      result = exec_engine(name, engine_cmd, playbook_path, check, diff, user, umask, env, limit)
      HostState::Observation.new(result, before, snapshot_state(name))
    end

    # Best-effort: a failed snapshot costs the state half of the oracle for
    # this playbook, never the playbook's stdout comparison.
    private def snapshot_state(name : String) : HostState::Snapshot?
      result = Cmd.run("podman", ["exec", "-i", name, "sh", "-s"], input: HostState::SNAPSHOT_SCRIPT, timeout: 180.0)
      return HostState::Snapshot.parse(result.stdout) if Cmd.success?(result)

      Log.info("podman", "warning: state snapshot failed in #{name}: #{result.stderr.lines.last?}")
      nil
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

    private def write_inventory(name : String, content : String = INVENTORY) : Nil
      result = Cmd.run("podman", ["exec", "-i", name, "bash", "-c", "cat > /work/inventory.ini"], input: content, timeout: 60.0)
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

    # A collection's argument spec ships with the installed version, so a
    # floating install silently changes what real ansible considers valid
    # and turns every argspec difference into a false divergence. The pins
    # live in module_dependencies.yml; a mismatch fails provisioning the
    # same way a wrong ansible-core does, including the distro-collection
    # case (a second installed copy with another version).
    private def assert_collection_versions!(requirements : Array(String)) : Nil
      return unless requirements.any? { |requirement| Dependencies.split_collection(requirement)[1] }

      result = Cmd.run("podman", ["exec", @name_real, "ansible-galaxy", "collection", "list", "--format", "json"], timeout: 180.0)
      unless Cmd.success?(result)
        raise PodmanProvisionError.new("ansible-galaxy collection list failed in container: #{result.stderr}")
      end

      installed = Dependencies.installed_collection_versions(result.stdout)
      mismatches = Dependencies.collection_version_mismatches(requirements, installed)
      return if mismatches.empty?

      raise PodmanProvisionError.new(
        "container collections do not match module_dependencies.yml: #{mismatches.join("; ")} - " \
        "argspec checks would compare the engine against a collection set krikri does not target; " \
        "fix the pin there (or bump it deliberately)")
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

    # Only called after a template build. In --refresh mode a deliberate
    # rebuild drops every other tag of the stable repository name, so the
    # cache resets to exactly the freshly built fingerprint instead of
    # accumulating stale ones. Otherwise the cache is capped: every build
    # prunes the tags beyond the MAX_CACHED_TEMPLATES newest, so a run of
    # input changes can't leave hundreds of stale fingerprints behind.
    private def prune_other_tags(image : String) : Nil
      repository = image.split(":").first
      result = Cmd.run("podman", ["images", "--filter", "reference=#{repository}:*",
                                  "--format", "{{.Repository}}:{{.Tag}} {{.CreatedAt}}"], timeout: 60.0)
      return unless Cmd.success?(result)

      keep = @refresh_templates ? 1 : MAX_CACHED_TEMPLATES
      candidates = PodmanBackend.prune_candidates(result.stdout, image, keep)
      return unless candidates
      candidates.each do |ref|
        Cmd.run("podman", ["rmi", ref], timeout: 300.0)
      end
    end

    # Visible for specs: the tags a prune of `image`'s repository removes, oldest
    # first beyond the kept count. `{{.Created}}` renders as "6 hours ago", which
    # parses as 0 for every tag and once made the eviction pick arbitrary tags,
    # including the just-committed image this same run was about to start from.
    # `{{.CreatedAt}}` is RFC3339; an age that does not parse aborts the prune,
    # because a cache cap that cannot order the tags must not guess.
    def self.prune_candidates(listing : String, image : String, keep : Int) : Array(String)?
      tags = listing.lines.compact_map do |line|
        ref, created = line.split(" ", 2)
        next unless created
        begin
          {ref, Time.parse_rfc3339(created)}
        rescue Time::Format::Error
          nil
        end
      end
      return if tags.size != listing.lines.count { |line| !line.blank? }
      tags.sort_by! { |(_, created)| -created.to_unix }
      # The image names carry no localhost/ prefix while podman lists the full
      # reference, so the self match has to normalize the prefix away too.
      tags.reject! { |(ref, _)| ref == image || ref.lchop("localhost/") == image }
      tags.skip(keep - 1).map(&.first)
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

    # Visible for specs: the tag the package layer is cached under. It must
    # stay equal across two builds whose krikri binary differs, or the base
    # images can never be reused.
    def base_fingerprint_for_test(profile : Profile = Profile::Debian) : String
      base_fingerprint(profile)
    end

    # Visible for specs: which profiles were satisfied from the image
    # cache rather than freshly provisioned.
    def cache_hit?(profile : Profile) : Bool
      @cache_hits.includes?(profile)
    end

    # Visible for specs: which profiles were rebuilt from a cached base pair
    # (package layer reused) rather than from the vanilla base image.
    def base_cache_hit?(profile : Profile) : Bool
      @base_cache_hits.includes?(profile)
    end

    private def fingerprint(profile : Profile) : String
      parts = base_fingerprint_parts(profile) + [content_digest(@krikri_bin), plugins_digest]
      Digest::SHA256.hexdigest(parts.join("\n"))[0, 16]
    end

    # The key for the expensive half of the template: everything an apt/dnf
    # install put in the image, and nothing the krikri binary does. The loop
    # rebuilds `krikri-playbook` before most runs, so keying the install on
    # the binary's digest re-downloaded and re-committed ~600 MB of packages
    # for a 27 MB change; this lets that change start from the cached pair.
    private def base_fingerprint(profile : Profile) : String
      Digest::SHA256.hexdigest(base_fingerprint_parts(profile).join("\n"))[0, 16]
    end

    private def base_fingerprint_parts(profile : Profile) : Array(String)
      sets = package_sets
      [
        profile.to_s,
        profile.debian? ? IMAGE : IMAGE_RPM,
        EXPECTED_ANSIBLE_VERSION,
        ANSIBLE_CORE_PIN,
        sets.real_debian.join(","), sets.krikri_debian.join(","),
        sets.real_rpm.join(","), sets.krikri_rpm.join(","),
        sets.python.join(","), sets.collections.join(","),
        INVENTORY,
        Digest::SHA256.hexdigest(Fixtures::SEED_SCRIPT),
        Digest::SHA256.hexdigest(Fixtures::IDENTITY_SCRIPT),
      ]
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

      # A playbook-relative include needs its child files beside it.
      include_dir = PlaybookBuilder.include_dir(playbook_path)
      return unless Dir.exists?(include_dir)

      copied = Cmd.run("podman", ["cp", include_dir, "#{name}:/work/"], timeout: 120.0)
      raise PodmanProvisionError.new("podman cp #{File.basename(include_dir)} into #{name} failed: #{copied.stderr}") unless Cmd.success?(copied)
    end

    private def exec_engine(name : String, engine_cmd : String, playbook_path : String,
                            check : Bool = @check_mode, diff : Bool = @diff,
                            user : UserProfile = UserProfile::Root,
                            umask : String = DEFAULT_UMASK,
                            env : Hash(String, String) = {} of String => String,
                            limit : String? = nil) : Cmd::Result
      owner = user.nonroot? ? Fixtures::UNPRIVILEGED_USER : "root"
      script = PodmanBackend.engine_script(engine_cmd, File.basename(playbook_path), @engine_timeout,
        check, diff, umask, owner, owner, env, limit)
      args = ["exec", "-w", "/work"]
      if user.nonroot?
        args += ["--user", "#{Fixtures::UNPRIVILEGED_USER}:#{Fixtures::UNPRIVILEGED_USER}",
                 "-e", "HOME=#{Fixtures::UNPRIVILEGED_HOME}"]
      end
      args += [name, "bash", "-c", script]
      Cmd.run("podman", args, timeout: @engine_timeout + 60.0)
    end

    private def exec!(name : String, script : String, timeout : Float64 = 120.0) : Nil
      result = Cmd.run("podman", ["exec", name, "bash", "-c", script], timeout: timeout)
      raise PodmanProvisionError.new("provisioning #{name} failed: #{result.stderr}") unless Cmd.success?(result)
    end
  end
end
