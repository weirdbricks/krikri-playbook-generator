require "digest/sha256"
require "file_utils"
require "./cmd"
require "./dependencies"
require "./fixtures"
require "./log"

module KrikriPlaybookGenerator
  class MicrovmProvisionError < Exception
  end

  # Local KVM microVM backend: both engines run inside fresh cloud-image VMs
  # on this machine, one VM per engine, so the byte-for-byte comparison keeps
  # the fresh-host guarantee podman gives without needing a service daemon,
  # a real kernel module or a cloud server.
  #
  # The module profile that the podman path cannot host (mariadb, postgres,
  # docker, podman, zfs, snap, rabbitmq, libvirt, bind, firewalld, selinux)
  # becomes the golden image's own state: one Ubuntu 24.04 and one Rocky 9
  # golden, baked once per dependency fingerprint, with the profile's
  # packages installed and its services prepared. Every playbook then boots
  # two throwaway qcow2 overlays on top (ansible on one, krikri on the
  # other), so no state can leak from one engine run into the other - the
  # reason the podman path uses a fresh pair per playbook and the Atlantic
  # path can only run a profile's playbooks sequentially.
  #
  # The goldens are keyed by the union of the dependency table's packages
  # plus the profile prep, not by the batch: a batch of six rotating modules
  # would otherwise rebake a golden (minutes) every cycle. A module added to
  # data/module_dependencies.yml therefore changes the fingerprint and
  # triggers exactly one rebake.
  class MicrovmBackend
    SSH_PORT     = 2422
    VM_MEM_MB    = 1024
    VM_CPUS      = 2
    BOOT_SECS    = 240
    BAKE_SECS    = 900
    DOWNLOAD_SECS = 900
    ANSIBLE_CORE_VERSION = "2.21.6"
    ANSIBLE_CORE_PIN     = "ansible-core==#{ANSIBLE_CORE_VERSION}"

    # Same rule as the podman and Atlantic backends: byte parity is only
    # meaningful against the core krikri targets.
    INVENTORY        = "target ansible_connection=local\n"
    ENGINE_ENV_STRIP = "env -u ANSIBLE_GATHERING -u ANSIBLE_CACHE_PLUGIN -u ANSIBLE_CACHE_PLUGIN_CONNECTION ANSIBLE_NOCOLOR=1"

    # Separate address space from the role tester's 127.77 podman/microvm
    # slots, so a kpg batch and a role round can run at the same time.
    ADDR_PREFIX = "127.90"
    BAKE_ADDR   = "127.90.0.1"
    MAX_SLOTS   = 200

    DEFAULT_DIR = File.expand_path("~/.local/share/krikri-playbook-generator/microvm", home: true)

    # Rocky 10, not 9: the goldens carry the same pinned ansible-core the
    # podman rpm template and Atlantic's rpm profile use, and Rocky 9's
    # Python 3.9 cannot install it. Rocky 10 is also the release those two
    # backends already run, so an rpm module's behaviour matches.
    CLOUD_IMAGES = {
      "ubuntu" => "https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img",
      "rocky"  => "https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2",
    }

    BASE_PACKAGES = {
      "ubuntu" => %w[python3 python3-pip rsync locales],
      "rocky"  => %w[python3 python3-pip rsync],
    }

    # Modules that need rpm tooling or an SELinux-enabled kernel: no Debian
    # or Ubuntu golden can host them. Everything else runs on Ubuntu (zfs
    # included - Debian 13's shipping kernel has no matching zfs-dkms
    # headers, the same reason the Atlantic misc profile is Ubuntu).
    # Modules whose happy path needs a service daemon, a kernel module or a
    # container runtime: podman's plain containers cannot host them, so the
    # mixed backend routes their playbooks here. The RPM family is
    # deliberately absent - podman's Rocky template already satisfies it.
    MICROVM_ONLY = Set{
      "mysql_db", "mysql_user", "mysql_info", "mysql_query", "mysql_variables",
      "postgresql_db", "postgresql_user", "postgresql_privs", "postgresql_query",
      "docker_container", "docker_image", "docker_image_build", "docker_login",
      "docker_network", "docker_network_info", "docker_compose_v2",
      "podman_container", "podman_image", "current_container_facts",
      "zfs", "snap", "rabbitmq_plugin", "rabbitmq_user", "virt_net", "nsupdate",
      "firewalld", "firewalld_info", "selinux", "seboolean", "sefcontext", "seport",
    }

    ROCKY_MODULES = Set{
      "dnf", "dnf5", "yum", "yum_repository", "rpm_key", "dnf_versionlock", "yum_versionlock",
      "selinux", "seboolean", "sefcontext", "seport", "firewalld", "firewalld_info",
    }

    SERVICE_PACKAGES = {
      "ubuntu" => %w[
        mariadb-server python3-pymysql postgresql python3-psycopg2
        docker.io podman python3-docker iptables docker-compose-v2
        zfsutils-linux snapd rabbitmq-server python3-pika
        libvirt-daemon-system libvirt-clients python3-libvirt bind9 python3-dnspython
      ],
      "rocky" => %w[
        python3-dnf python3-dnf-plugin-versionlock gnupg2
        firewalld python3-firewall policycoreutils python3-libselinux
      ],
    }

    UBUNTU_PREP = <<-'PREP'
      systemctl enable --now mariadb 2>/dev/null || true
      systemctl enable --now postgresql 2>/dev/null || true
      PGHBA=$(ls /etc/postgresql/*/main/pg_hba.conf 2>/dev/null | head -1)
      if [ -n "$PGHBA" ]; then
        sed -i '1i local all all trust\\nhost all all 127.0.0.1/32 trust\\nhost all all ::1/128 trust' "$PGHBA" || true
        systemctl reload postgresql 2>/dev/null || true
        su postgres -c "psql -tAc \\"SELECT 1 FROM pg_database WHERE datname='kpgdb'\\" | grep -q 1 || psql -c 'CREATE DATABASE kpgdb'" 2>/dev/null || true
        su postgres -c "psql -tAc \\"SELECT 1 FROM pg_roles WHERE rolname='kpguser'\\" | grep -q 1 || psql -c 'CREATE USER kpguser'" 2>/dev/null || true
      fi
      systemctl enable --now docker 2>/dev/null || true
      docker pull alpine:3.20 >/dev/null 2>&1 || true
      docker pull busybox:latest >/dev/null 2>&1 || true
      # The minimal cloud image ships no kernel modules outside its own
      # set; zfs needs the matching linux-modules-extra (the same reason the
      # Atlantic misc profile uses Ubuntu), and $(uname -r) is safe here
      # because prep runs in the guest's shell.
      apt-get install -y -qq --no-install-recommends "linux-modules-extra-$(uname -r)" >/dev/null 2>&1 || true
      depmod -a 2>/dev/null || true
      modprobe zfs 2>/dev/null || true
      if command -v zpool >/dev/null 2>&1 && ! zpool list kpgpool >/dev/null 2>&1; then
        mkdir -p /tmp/kpg-zfs
        truncate -s 128M /tmp/kpg-zfs/pool.img
        zpool create -f kpgpool /tmp/kpg-zfs/pool.img >/dev/null 2>&1 || true
      fi
      systemctl enable --now snapd.socket 2>/dev/null || true
      systemctl enable --now rabbitmq-server 2>/dev/null || true
      systemctl enable --now libvirtd 2>/dev/null || true
      cat > /etc/bind/named.conf.local <<'KPG_BIND_EOF'
      zone "kpg-test.zone" {
          type master;
          file "/etc/bind/db.empty";
          allow-update { any; };
      };
      KPG_BIND_EOF
      systemctl enable --now named 2>/dev/null || true
      PREP

    ROCKY_PREP = <<-'PREP'
      systemctl enable --now firewalld 2>/dev/null || true
      PREP

    record Profile, os : String, packages : Array(String), collections : Array(String), prep : String

    getter dir : String

    def initialize(@krikri_bin : String, @engine_timeout : Int32 = 120,
                   @dir : String = DEFAULT_DIR, @qemu : String = "qemu-system-x86_64",
                   @control : Bool = false, @check_mode : Bool = false,
                   @work_dir : String? = nil)
    end

    def self.available?(qemu : String = "qemu-system-x86_64") : Bool
      Cmd.run(qemu, ["--version"], timeout: 30.0).rc == 0 &&
        File.exists?("/dev/kvm") && File::Info.readable?("/dev/kvm")
    end

    # The VM a playbook runs on: rpm/SELinux modules need the Rocky golden,
    # anything else the Ubuntu one. A multi-task playbook takes Rocky when
    # any of its tasks does, mirroring the podman path's per-playbook choice.
    def self.profile_for(module_names : Array(String)) : String
      module_names.any? { |name| ROCKY_MODULES.includes?(name.split(".").last) } ? "rocky" : "ubuntu"
    end

    def self.microvm_only?(module_names : Array(String)) : Bool
      module_names.any? { |name| MICROVM_ONLY.includes?(name.split(".").last) }
    end

    # The package list of a golden: the OS base, the service profile, and
    # every dependency-table entry of the modules that profile hosts, so a
    # new entry in data/module_dependencies.yml is picked up without touching
    # this file.
    def self.packages_for(os : String, deps : Dependencies) : Array(String)
      hosted = deps.installed_modules.select { |fqcn| profile_for([fqcn]) == os }
      sets = deps.package_sets(hosted)
      union = os == "rocky" ? sets.real_rpm + sets.krikri_rpm : sets.real_debian + sets.krikri_debian
      (BASE_PACKAGES[os] + SERVICE_PACKAGES[os] + union).uniq!.sort!
    end

    def self.prep_for(os : String) : String
      os == "rocky" ? ROCKY_PREP : UBUNTU_PREP
    end

    def self.collections_for(os : String, deps : Dependencies) : Array(String)
      hosted = deps.installed_modules.select { |fqcn| profile_for([fqcn]) == os }
      deps.package_sets(hosted).collections.uniq!.sort!
    end

    def self.profile(os : String, deps : Dependencies = Dependencies.load) : Profile
      Profile.new(os, packages_for(os, deps), collections_for(os, deps), prep_for(os))
    end

    # Content-addressed so one bake per (os, data) pair is all a run pays,
    # and a changed package list, prep or pinned core invalidates it.
    def self.fingerprint(os : String, packages : Array(String), collections : Array(String), prep : String) : String
      digest = Digest::SHA256.new
      {os, CLOUD_IMAGES[os]?, ANSIBLE_CORE_PIN, packages.join("\n"), collections.join("\n"), prep}.each { |part| digest.update(part.to_s) }
      digest.final.hexstring[0, 16]
    end

    def self.gold_path(dir : String, os : String, fingerprint : String) : String
      File.join(dir, "gold-#{os}-#{fingerprint}.qcow2")
    end

    def self.baked_marker(gold : String) : String
      "#{gold}.ok"
    end

    def self.baked?(gold : String) : Bool
      File.exists?(gold) && File.exists?(baked_marker(gold))
    end

    def self.cloud_path(dir : String, os : String) : String
      url = CLOUD_IMAGES[os]?
      raise MicrovmProvisionError.new("no microvm cloud image for os #{os}") unless url
      File.join(dir, "cloud", File.basename(url))
    end

    # A fixed 4G overlay truncated Rocky's 10G cloud image, so its kernel
    # could not find its root device; overlays must inherit the base size.
    # Argument vectors, not shell strings: Cmd.run execs one binary plus
    # argv (unlike krikri-role-tester's shell-backed Cmd), so a command line
    # passed as argv[0] is looked up as an executable and dies File::NotFound.
    def self.overlay_args(base : String, overlay : String) : Array(String)
      ["create", "-f", "qcow2", "-F", "qcow2", "-b", base, overlay]
    end

    def self.boot_args(name : String, overlay : String, seed : String, ip : String, port : Int32,
                       console : String, pidfile : String) : Array(String)
      ["-enable-kvm", "-M", "q35", "-cpu", "host", "-smp", VM_CPUS.to_s, "-m", VM_MEM_MB.to_s,
       "-drive", "file=#{overlay},if=virtio,format=qcow2",
       "-drive", "file=#{seed},if=virtio,format=raw,readonly=on",
       "-nic", "user,model=virtio-net-pci,hostfwd=tcp:#{ip}:#{port}-:22",
       "-display", "none", "-serial", "file:#{console}",
       "-daemonize", "-pidfile", pidfile, "-name", name]
    end

    # cloud-init NoCloud needs files named user-data/meta-data in the seed
    # filesystem, and every boot needs a unique instance-id: a boot where
    # cloud-init does not run leaves sshd's host keys and the authorized key
    # unwritten, so the VM comes up unschedulable.
    def self.seed_user_data(pub : String) : String
      <<-CLOUDINIT
        #cloud-config
        disable_root: false
        ssh_authorized_keys:
          - #{pub}
        ssh_pwauth: false
        runcmd:
          - sh -c 'mkdir -p /root/.ssh && cat /home/*/.ssh/authorized_keys >> /root/.ssh/authorized_keys 2>/dev/null; chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys 2>/dev/null; true'
        CLOUDINIT
    end

    def self.seed_meta_data(instance : String) : String
      "instance-id: #{instance}\n"
    end

    def self.ssh_options(key_path : String) : Array(String)
      ["-p", SSH_PORT.to_s, "-i", key_path, "-o", "IdentitiesOnly=yes",
       "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
       "-o", "ConnectTimeout=15", "-o", "ConnectionAttempts=6", "-o", "ServerAliveInterval=30"]
    end

    # The engine command inside the VM: identical for both engines, run from
    # /work with the same env strip the other backends use.
    def self.engine_command(binary : String, basename : String, timeout : Int32, check_mode : Bool) : String
      check = check_mode ? "--check --diff " : ""
      "cd /work && #{ENGINE_ENV_STRIP} timeout #{timeout} " \
        "#{binary} -i inventory.ini #{check}/work/#{basename} </dev/null"
    end

    # Bakes (or reuses) the golden for each OS in `oses`, then runs every
    # playbook in a fresh VM pair. The caller does the parallelism.
    def provision(os : String) : Nil
      deps = Dependencies.load
      profile = self.class.profile(os, deps)
      Dir.mkdir_p(File.join(@dir, "cloud"))
      Dir.mkdir_p(File.join(@dir, "runs"))
      ensure_bench_key
      ensure_cloud_image(os)
      fingerprint = self.class.fingerprint(os, profile.packages, profile.collections, profile.prep)
      gold = self.class.gold_path(@dir, os, fingerprint)
      bake_if_needed(gold, profile) unless self.class.baked?(gold)
      @goldens[os] = gold
    end

    # Removes the process's scratch state (packed krikri binary, seeds,
    # per-VM keys). Goldens and cloud images stay for the next run.
    def teardown : Nil
      FileUtils.rm_rf(work_dir)
      @work_dir = nil
      @krikri_tar = nil
    rescue File::Error
    end

    def run_playbook(playbook_path : String, os : String, slot : Int32) : {ansible: Cmd::Result, krikri: Cmd::Result}
      gold = @goldens[os]? || raise MicrovmProvisionError.new("profile #{os} was never provisioned")

      pair = boot_pair(gold, os, slot)
      begin
        pair.vms.each { |host| prep_vm(host, playbook_path) }
        basename = File.basename(playbook_path)
        ansible = exec_engine(pair.ansible, "ansible-playbook", basename)
        krikri = exec_engine(pair.krikri, @control ? "ansible-playbook" : "/opt/krikri/bin/krikri-playbook", basename)
        {ansible: ansible, krikri: krikri}
      ensure
        stop_pair(pair)
      end
    end

    # Anything a killed run left behind is removed; a VM whose owning pid is
    # alive is never touched (a concurrent kpg process may own it).
    def self.cleanup_stale(dir : String = DEFAULT_DIR) : Array(String)
      removed = [] of String
      Dir.glob(File.join(dir, "runs", "*.run")).each do |record|
        fields = (File.read(record) rescue "").split
        next if fields.empty?
        qemu_pid = fields[0]?.try(&.to_i?)
        owner = fields[1]?.try(&.to_i?)
        next if owner && Process.exists?(owner)
        if qemu_pid && Process.exists?(qemu_pid)
          Process.signal(Signal::TERM, qemu_pid) rescue nil
          wait_gone(qemu_pid, 10)
          Process.signal(Signal::KILL, qemu_pid) if Process.exists?(qemu_pid) rescue nil
        end
        fields[2]?.try { |overlay| File.delete?(overlay) }
        File.delete?(record)
        removed << File.basename(record)
      rescue File::Error
      end
      removed
    end

    def self.wait_gone(pid : Int32, secs : Int32) : Nil
      secs.times do
        return unless Process.exists?(pid)
        sleep 1.second
      end
    end

    private getter qemu : String

    @goldens = {} of String => String
    @bench_key : String?
    @krikri_tar : String?

    # Test/debug override: a bake that cannot reach sshd is a slow failure,
    # so the wait is tunable without rebuilding while diagnosing one.
    private def boot_secs : Int32
      ENV["KPG_MICROVM_BOOT_SECS"]?.try(&.to_i?) || BOOT_SECS
    end

    private def bake_secs : Int32
      ENV["KPG_MICROVM_BAKE_SECS"]?.try(&.to_i?) || BAKE_SECS
    end

    private def work_dir : String
      @work_dir ||= begin
        path = File.join(@dir, "work-#{Process.pid}")
        Dir.mkdir_p(path)
        path
      end
    end

    private def bench_key : String
      @bench_key ||= File.join(@dir, "bench_key")
    end

    private def ensure_bench_key : Nil
      return if File.exists?(bench_key)
      result = Cmd.run("ssh-keygen", ["-t", "ed25519", "-N", "", "-q", "-f", bench_key])
      raise MicrovmProvisionError.new("ssh-keygen failed: #{result.stderr.strip}") unless result.rc == 0
    end

    private def ensure_cloud_image(os : String) : Nil
      path = MicrovmBackend.cloud_path(@dir, os)
      return if File.exists?(path)
      url = CLOUD_IMAGES[os]
      Log.info("microvm", "downloading #{os} cloud image (first use, #{url})")
      tmp = "#{path}.part"
      result = Cmd.run("curl", ["-fSL", "--retry", "3", "-o", tmp, url], timeout: DOWNLOAD_SECS.to_f)
      unless result.rc == 0
        File.delete?(tmp)
        raise MicrovmProvisionError.new("cloud image download failed: #{result.stderr.lines.last(3).join(" | ")}")
      end
      FileUtils.mv(tmp, path)
    end

    private def bake_if_needed(gold : String, profile : Profile) : Nil
      return if MicrovmBackend.baked?(gold)
      if File.exists?(gold)
        Log.info("microvm", "discarding unverified microvm golden #{File.basename(gold)}")
        File.delete?(gold)
      end
      bake(gold, profile)
    end

    # One boot installs everything the golden carries and prepares its
    # services, then the disk itself becomes the golden (the VM is powered
    # off cleanly so the filesystem needs no journal replay on first use).
    private def bake(gold : String, profile : Profile) : Nil
      Log.info("microvm", "baking #{File.basename(gold)} (first use, a few minutes)")
      base = MicrovmBackend.cloud_path(@dir, profile.os)
      created = Cmd.run("qemu-img", MicrovmBackend.overlay_args(base, gold), timeout: 60.0)
      unless created.rc == 0
        raise MicrovmProvisionError.new("qemu-img create #{gold} failed: #{created.stderr.lines.last(3).join(" | ")}")
      end

      seed = write_seed("bake-#{profile.os}", profile.os, "kpg-bake-#{profile.os}-#{Time.utc.to_unix_ms}")
      vm = boot(gold, seed, "kpg-bake-#{profile.os}", BAKE_ADDR, File.join(work_dir, "bake"))
      begin
        wait_ssh(vm, bake_secs)
        install_golden_packages(vm, profile)
        run_prep(vm, profile)
        seed_fixtures(vm)
        stop_vm(vm)
      rescue e
        stop_vm(vm) rescue nil
        File.delete?(gold)
        raise e
      end

      verify_gold(gold, profile)
      File.write(MicrovmBackend.baked_marker(gold), "ok\n")
    end

    # A golden that has never booted is not trusted: a bake that died leaves
    # the file behind, and booting it would fail every playbook of the run.
    private def verify_gold(gold : String, profile : Profile) : Nil
      seed = write_seed("verify-#{profile.os}", profile.os, "kpg-verify-#{profile.os}-#{Time.utc.to_unix_ms}")
      vm = boot(gold, seed, "kpg-verify-#{profile.os}", BAKE_ADDR, File.join(work_dir, "verify"))
      begin
        wait_ssh(vm, boot_secs)
        assert_ansible_version(vm)
      ensure
        stop_vm(vm) rescue nil
      end
    end

    private def install_golden_packages(vm : Vm, profile : Profile) : Nil
      failures = [] of String
      # The staged binary and the per-playbook workdir are created here so
      # every boot from the golden already has them.
      run_script(vm, "mkdir -p /work /opt/krikri/bin", 60.0)
      index = profile.os == "rocky" ? "dnf makecache -q 2>/dev/null || true" : "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq"
      run_script(vm, index, 900.0)
      install_cmd = profile.os == "rocky" ? "dnf install -y -q" : "apt-get install -y -qq --no-install-recommends"
      profile.packages.each_slice(8).each do |batch|
        script = batch.map do |pkg|
          "#{install_cmd} #{pkg} >/dev/null 2>&1 || echo KPG_PKG_FAIL #{pkg}"
        end.join("\n")
        result = run_script(vm, script, 900.0)
        failures.concat(result.stdout.lines.select(&.starts_with?("KPG_PKG_FAIL ")).map(&.strip))
      end
      # A missing package is a harness gap for its module, not a reason to
      # lose every other module of the profile: warn and keep the golden.
      failures.each { |line| Log.info("microvm", "warning: golden #{profile.os}: #{line}") }
      install_ansible(vm, profile)
    end

    private def install_ansible(vm : Vm, profile : Profile) : Nil
      script = "pip3 install #{ANSIBLE_CORE_PIN} || " \
               "pip3 install --break-system-packages #{ANSIBLE_CORE_PIN}"
      result = run_script(vm, script, 1200.0)
      unless result.rc == 0
        tail = (result.stdout + result.stderr).lines.map(&.strip).reject(&.empty?).last(5).join(" | ")
        raise MicrovmProvisionError.new("installing #{ANSIBLE_CORE_PIN} on the #{profile.os} golden failed: #{tail}")
      end
      return if profile.collections.empty?

      galaxy = run_script(vm, "ansible-galaxy collection install #{profile.collections.join(" ")}", 1200.0)
      unless galaxy.rc == 0
        tail = (galaxy.stdout + galaxy.stderr).lines.map(&.strip).reject(&.empty?).last(5).join(" | ")
        raise MicrovmProvisionError.new("installing collections on the #{profile.os} golden failed: #{tail}")
      end
    end

    private def run_prep(vm : Vm, profile : Profile) : Nil
      # `|| true` inside the prep keeps one missing service from blanking
      # the whole profile - the same reason Atlantic's prep tolerates
      # per-package failures.
      run_script(vm, profile.prep, 900.0)
    end

    private def seed_fixtures(vm : Vm) : Nil
      result = run_script(vm, Fixtures::SEED_SCRIPT, 120.0)
      raise MicrovmProvisionError.new("seeding fixtures failed on #{vm.ip}: #{result.stderr}") unless result.rc == 0
      start_fixture_server(vm)
    end

    private def start_fixture_server(vm : Vm) : Nil
      script = "pkill -f 'http.server #{Fixtures::HTTP_PORT}' 2>/dev/null || true\n" \
               "nohup python3 -m http.server #{Fixtures::HTTP_PORT} --bind 127.0.0.1 --directory #{Fixtures::FIXTURE_ROOT} " \
               ">/dev/null 2>&1 &"
      run_script(vm, script, 60.0)
    end

    record Vm, ip : String, key : String, dir : String, name : String

    record Pair, ansible : Vm, krikri : Vm do
      def vms : Array(Vm)
        [ansible, krikri]
      end
    end

    private def boot_pair(gold : String, os : String, slot : Int32) : Pair
      octet = (slot % MAX_SLOTS) + 1
      ansible_ip = "#{ADDR_PREFIX}.#{octet}.1"
      krikri_ip = "#{ADDR_PREFIX}.#{octet}.2"
      ansible = boot_vm(gold, os, "kpg-real-#{slot}", ansible_ip, stage_krikri_binary: false)
      begin
        krikri = boot_vm(gold, os, "kpg-krikri-#{slot}", krikri_ip, stage_krikri_binary: true)
      rescue e
        stop_vm(ansible) rescue nil
        raise e
      end
      Pair.new(ansible, krikri)
    end

    private def boot_vm(gold : String, os : String, name : String, ip : String, stage_krikri_binary : Bool) : Vm
      dir = File.join(work_dir, "vm", name)
      FileUtils.rm_rf(dir)
      Dir.mkdir_p(dir)
      overlay = File.join(dir, "disk.qcow2")
      created = Cmd.run("qemu-img", MicrovmBackend.overlay_args(gold, overlay), timeout: 60.0)
      unless created.rc == 0
        raise MicrovmProvisionError.new("qemu-img create #{name} failed: #{created.stderr.lines.last(3).join(" | ")}")
      end
      seed = write_seed("run-#{name}", os, "#{name}-#{Time.utc.to_unix_ms}")
      vm = boot(overlay, seed, name, ip, dir)
      wait_ssh(vm, boot_secs)
      stage_krikri(vm) if stage_krikri_binary
      vm
    end

    private def boot(overlay : String, seed : String, name : String, ip : String, dir : String) : Vm
      Dir.mkdir_p(dir)
      console = File.join(dir, "console.log")
      pidfile = File.join(dir, "qemu.pid")
      result = Cmd.run(qemu, MicrovmBackend.boot_args(name, overlay, seed, ip, SSH_PORT, console, pidfile),
        timeout: 60.0)
      unless result.rc == 0
        raise MicrovmProvisionError.new("qemu start #{name} failed: #{result.stderr.lines.last(3).join(" | ")}")
      end
      pid = poll_qemu_pid(pidfile)
      raise MicrovmProvisionError.new("qemu #{name} wrote no pidfile") unless pid
      Dir.mkdir_p(File.join(@dir, "runs"))
      File.write(run_record(name), "#{pid} #{Process.pid} #{overlay}\n")
      Vm.new(ip, bench_key, dir, name)
    end

    private def poll_qemu_pid(pidfile : String) : Int32?
      20.times do
        begin
          pid = File.read(pidfile).strip.to_i?
          return pid if pid
        rescue File::Error
        end
        sleep 500.milliseconds
      end
      nil
    end

    private def run_record(name : String) : String
      File.join(@dir, "runs", "#{name}.#{Process.pid}.run")
    end

    private def write_seed(label : String, os : String, instance : String) : String
      dir = File.join(work_dir, "seed-#{label}")
      FileUtils.rm_rf(dir)
      Dir.mkdir_p(dir)
      pub = File.read("#{bench_key}.pub").strip
      File.write(File.join(dir, "user-data"), MicrovmBackend.seed_user_data(pub))
      File.write(File.join(dir, "meta-data"), MicrovmBackend.seed_meta_data(instance))
      iso = File.join(dir, "seed.iso")
      built = Cmd.run("genisoimage", ["-output", iso, "-volid", "cidata", "-joliet", "-rock",
                                      File.join(dir, "user-data"), File.join(dir, "meta-data")])
      unless built.rc == 0
        raise MicrovmProvisionError.new("seed build failed (#{label}): #{built.stderr.lines.last(3).join(" | ")}")
      end
      iso
    end

    private def wait_ssh(vm : Vm, secs : Int32) : Nil
      deadline = Time.instant + secs.seconds
      loop do
        result = Cmd.run("timeout", ["30", "ssh"] + ssh_args(vm) + ["root@#{vm.ip}", "echo up"], timeout: 60.0)
        return if result.rc == 0
        if why = stopped_reason(vm)
          raise MicrovmProvisionError.new(why)
        end
        raise MicrovmProvisionError.new("sshd never came up on #{vm.ip} after #{secs}s") if Time.instant > deadline
        sleep 2.seconds
      end
    end

    private def ssh_args(vm : Vm) : Array(String)
      MicrovmBackend.ssh_options(vm.key)
    end

    private def prep_vm(vm : Vm, playbook_path : String) : Nil
      seed_fixtures(vm)
      basename = File.basename(playbook_path)
      copy = Cmd.run("scp", ["-P", SSH_PORT.to_s, "-i", vm.key, "-o", "IdentitiesOnly=yes",
                             "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                             playbook_path, "root@#{vm.ip}:/work/#{basename}"], timeout: 120.0)
      raise MicrovmProvisionError.new("playbook upload to #{vm.ip} failed: #{copy.stderr}") unless copy.rc == 0
      inventory = run_script(vm, "mkdir -p /work && cat > /work/inventory.ini <<'KPG_INVENTORY_EOF'\n" +
        INVENTORY + "KPG_INVENTORY_EOF\n", 60.0)
      unless inventory.rc == 0
        raise MicrovmProvisionError.new("writing inventory on #{vm.ip} failed: #{inventory.stderr}")
      end
      assert_ansible_version(vm) unless @control
    end

    private def stage_krikri(vm : Vm) : Nil
      return if @control
      tar = krikri_tar
      scp = Cmd.run("scp", ["-P", SSH_PORT.to_s, "-i", vm.key, "-o", "IdentitiesOnly=yes",
                            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                            tar, "root@#{vm.ip}:/tmp/kpg-krikri.tar.gz"], timeout: 300.0)
      raise MicrovmProvisionError.new("krikri upload to #{vm.ip} failed: #{scp.stderr}") unless scp.rc == 0
      result = run_script(vm, "tar -xzf /tmp/kpg-krikri.tar.gz -C /opt/krikri/bin && rm -f /tmp/kpg-krikri.tar.gz && " \
                              "chmod +x /opt/krikri/bin/krikri-playbook /opt/krikri/bin/plugins/*", 300.0)
      raise MicrovmProvisionError.new("krikri unpack on #{vm.ip} failed: #{result.stderr}") unless result.rc == 0
    end

    private def krikri_tar : String
      @krikri_tar ||= begin
        plugins_dir = File.join(File.dirname(@krikri_bin), "plugins")
        raise MicrovmProvisionError.new("krikri plugins dir #{plugins_dir.inspect} not found") unless File.exists?(plugins_dir)
        path = File.join(work_dir, "krikri.tar.gz")
        tar = Cmd.run("tar", ["-czf", path, "-C", File.dirname(@krikri_bin), File.basename(@krikri_bin), "plugins"], timeout: 300.0)
        raise MicrovmProvisionError.new("krikri tar failed: #{tar.stderr}") unless tar.rc == 0
        path
      end
    end

    private def assert_ansible_version(vm : Vm) : Nil
      result = run_script(vm, "ansible-playbook --version", 120.0)
      raise MicrovmProvisionError.new("ansible-playbook --version failed on #{vm.ip}: #{result.stderr}") unless result.rc == 0
      version = result.stdout.match(/core (\d+\.\d+\.\d+)/).try(&.[1])
      unless version == ANSIBLE_CORE_VERSION
        raise MicrovmProvisionError.new(
          "VM ansible-core is #{version.inspect}, expected #{ANSIBLE_CORE_VERSION} - " \
          "byte-parity comparisons against a different engine version are meaningless")
      end
    end

    private def exec_engine(vm : Vm, binary : String, basename : String) : Cmd::Result
      command = MicrovmBackend.engine_command(binary, basename, @engine_timeout, @check_mode)
      result = Cmd.run("timeout", [( @engine_timeout + 120).to_i.to_s, "ssh"] + ssh_args(vm) + ["root@#{vm.ip}", command],
        timeout: @engine_timeout + 150.0)
      if result.rc == 255
        raise MicrovmProvisionError.new("ssh session failed running #{binary}: #{result.stderr.lines.last(3).join(" | ")}")
      end
      result
    end

    private def run_script(vm : Vm, script : String, timeout : Float64) : Cmd::Result
      Cmd.run("ssh", ssh_args(vm) + ["root@#{vm.ip}", "bash -s"], input: script, timeout: timeout)
    end

    private def stopped_reason(vm : Vm) : String?
      pid = File.read(File.join(vm.dir, "qemu.pid")).strip.to_i?
      return unless pid
      return if Process.exists?(pid)
      tail = begin
        File.read(File.join(vm.dir, "console.log")).lines.map(&.strip).reject(&.empty?).last(3).join(" | ")
      rescue File::Error
        ""
      end
      "VM #{vm.name} is not running#{tail.empty? ? "" : ": #{tail}"}"
    rescue File::Error
      nil
    end

    private def stop_pair(pair : Pair) : Nil
      pair.vms.each { |host| stop_vm(host) }
    end

    private def stop_vm(vm : Vm) : Nil
      pid = File.read(File.join(vm.dir, "qemu.pid")).strip.to_i?
      if pid && Process.exists?(pid)
        # Ask the guest to power off first so the overlay is left with a
        # clean filesystem; a TERM to qemu is the fallback.
        Cmd.run("ssh", ssh_args(vm) + ["root@#{vm.ip}", "sync; poweroff -f >/dev/null 2>&1 || true"], timeout: 30.0)
        self.class.wait_gone(pid, 15)
        Process.signal(Signal::TERM, pid) if Process.exists?(pid)
        self.class.wait_gone(pid, 10)
        Process.signal(Signal::KILL, pid) if Process.exists?(pid)
      end
      FileUtils.rm_rf(vm.dir)
      File.delete?(run_record(vm.name))
    rescue File::Error | IO::Error
    end
  end
end
