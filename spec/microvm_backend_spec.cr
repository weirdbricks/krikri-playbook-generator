require "./spec_helper"
require "../src/krikri_playbook_generator/microvm_backend"

module KrikriPlaybookGenerator
  describe MicrovmBackend do
    it "routes rpm, SELinux and firewalld modules to the Rocky golden and everything else to Ubuntu" do
      assert_equal("rocky", MicrovmBackend.profile_for(["yum_repository"]))
      assert_equal("rocky", MicrovmBackend.profile_for(["ansible.posix.selinux"]))
      assert_equal("rocky", MicrovmBackend.profile_for(["community.general.seport"]))
      assert_equal("rocky", MicrovmBackend.profile_for(["ansible.posix.firewalld_info"]))
      assert_equal("rocky", MicrovmBackend.profile_for(["file", "dnf5"]))
      assert_equal("ubuntu", MicrovmBackend.profile_for(["community.postgresql.postgresql_db"]))
      assert_equal("ubuntu", MicrovmBackend.profile_for(["copy"]))
      assert_equal("ubuntu", MicrovmBackend.profile_for([] of String))
    end

    it "marks only modules that need a service or kernel as microvm-only" do
      %w[mysql_db docker_container podman_image zfs snap rabbitmq_user nsupdate
        virt_net firewalld selinux current_container_facts].each do |name|
        assert(MicrovmBackend.microvm_only?([name]), "#{name} should be routed to microvm")
      end
      %w[dnf yum_repository copy file apt systemd_service postgresql_info].each do |name|
        refute(MicrovmBackend.microvm_only?([name]), "#{name} should stay on podman")
      end
    end

    it "creates overlays that inherit the base image's size" do
      args = MicrovmBackend.overlay_args("/base/gold.qcow2", "/work/disk.qcow2")
      assert_equal(%w[create -f qcow2 -F qcow2 -b /base/gold.qcow2 /work/disk.qcow2], args)
      refute_includes(args.join(" "), " 4G ")
    end

    it "grows a golden past the base image's root, which ubuntu's minimal image cannot hold" do
      assert_equal(["resize", "/work/gold.qcow2", "+#{MicrovmBackend::GOLDEN_EXTRA_GB}G"],
        MicrovmBackend.resize_args("/work/gold.qcow2", "ubuntu"))
      assert(MicrovmBackend::GOLDEN_EXTRA_GB > 0)
      assert_equal(0, MicrovmBackend.golden_extra_gb("rocky"))
      assert_equal(MicrovmBackend::GOLDEN_EXTRA_GB, MicrovmBackend.golden_extra_gb("ubuntu"))
    end

    it "puts the pinned core over Ubuntu's distro ansible without tripping PEP 668" do
      ubuntu = MicrovmBackend.ansible_install_command("ubuntu")
      assert_includes(ubuntu, "--break-system-packages")
      assert_includes(ubuntu, "--ignore-installed")
      assert_includes(ubuntu, "ansible-core==#{MicrovmBackend::ANSIBLE_CORE_VERSION}")
      assert_equal("pip3 install ansible-core==#{MicrovmBackend::ANSIBLE_CORE_VERSION}",
        MicrovmBackend.ansible_install_command("rocky"))
    end

    it "boots with slirp hostfwd on the kpg address space and a separate port from the role tester" do
      args = MicrovmBackend.boot_args("kpg-real-1", "/w/disk.qcow2",
        "/w/seed.iso", "127.90.3.1", MicrovmBackend::SSH_PORT, "/w/console.log", "/w/qemu.pid")
      assert_includes(args, "-enable-kvm")
      assert_equal("q35", args[args.index!("-M") + 1])
      assert_includes(args, "user,model=virtio-net-pci,hostfwd=tcp:127.90.3.1:#{MicrovmBackend::SSH_PORT}-:22")
      assert_includes(args, "file=/w/disk.qcow2,if=virtio,format=qcow2")
      assert_includes(args, "file=/w/seed.iso,if=virtio,format=raw,readonly=on")
      refute_equal(2322, MicrovmBackend::SSH_PORT)
    end

    # Two kpg processes (a fix-issues verification and the loop's own batch)
    # used to boot their first pair on the same 127.90.1.x hostfwd port, and
    # the second qemu died before running anything.
    it "leases each VM pair a slot no other process can take" do
      dir = File.join(Dir.tempdir, "kpg-slot-spec-#{Process.pid}-#{Random.rand(1_000_000)}")
      begin
        first = MicrovmBackend.new("/bin/true", dir: dir)
        second = MicrovmBackend.new("/bin/true", dir: dir)
        assert_equal(File.join(dir, "slots", "3.lock"), MicrovmBackend.slot_lock_path(dir, 3))

        a = first.acquire_slot
        b = second.acquire_slot
        assert_equal(0, a.slot)
        assert_equal(1, b.slot)

        held = Cmd.run("flock", ["-n", MicrovmBackend.slot_lock_path(dir, 0), "true"], timeout: 30.0)
        refute_equal(0, held.rc, "a second process must not be able to take the leased slot")

        a.release
        free = Cmd.run("flock", ["-n", MicrovmBackend.slot_lock_path(dir, 0), "true"], timeout: 30.0)
        assert_equal(0, free.rc, "a released slot must be available to the next process")
        assert_equal(0, second.acquire_slot.slot)

        b.release

        assert_equal(File.join(dir, "slots", "bake.lock"), MicrovmBackend.bake_lock_path(dir))
        bake = first.acquire_bake_lock
        busy = Cmd.run("flock", ["-n", MicrovmBackend.bake_lock_path(dir), "true"], timeout: 30.0)
        refute_equal(0, busy.rc, "the bake and its verify boot share one fixed address, so one bake at a time")
        bake.release
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "connects on the published ssh port, not the guest's 22" do
      options = MicrovmBackend.ssh_options("/k/bench_key")
      assert_equal(MicrovmBackend::SSH_PORT.to_s, options[options.index!("-p") + 1])
      assert_includes(options, "/k/bench_key")
    end

    it "authorizes the bench key for root and disables root login only through the key" do
      user_data = MicrovmBackend.seed_user_data("ssh-ed25519 AAAA test")
      assert_includes(user_data, "#cloud-config")
      assert_includes(user_data, "disable_root: false")
      assert_includes(user_data, "ssh_authorized_keys:")
      assert_includes(user_data, "ssh-ed25519 AAAA test")
      assert_includes(user_data, "ssh_pwauth: false")
      assert_equal("instance-id: abc\n", MicrovmBackend.seed_meta_data("abc"))
    end

    it "fingerprints the golden by os, package list and prep" do
      first = MicrovmBackend.fingerprint("ubuntu", %w[python3 mariadb-server], %w[community.mysql], "prep")
      assert_equal(first, MicrovmBackend.fingerprint("ubuntu", %w[python3 mariadb-server], %w[community.mysql], "prep"))
      refute_equal(first, MicrovmBackend.fingerprint("ubuntu", %w[python3], %w[community.mysql], "prep"))
      refute_equal(first, MicrovmBackend.fingerprint("ubuntu", %w[python3 mariadb-server], %w[community.mysql], "other prep"))
      refute_equal(first, MicrovmBackend.fingerprint("ubuntu", %w[python3 mariadb-server], %w[community.postgresql], "prep"))
      refute_equal(first, MicrovmBackend.fingerprint("rocky", %w[python3 mariadb-server], %w[community.mysql], "prep"))
    end

    it "names goldens by os and fingerprint" do
      assert_equal("/m/gold-ubuntu-abc.qcow2", MicrovmBackend.gold_path("/m", "ubuntu", "abc"))
      assert_equal("/m/gold-ubuntu-abc.qcow2.ok", MicrovmBackend.baked_marker("/m/gold-ubuntu-abc.qcow2"))
    end

    it "builds the same engine invocation for both engines, with the other backends' env strip" do
      command = MicrovmBackend.engine_command("ansible-playbook", "000001-copy-happy.yml", 120, false)
      assert_includes(command, "cd /work")
      assert_includes(command, "ANSIBLE_NOCOLOR=1")
      refute_includes(command, "ANSIBLE_GATHERING=")
      assert_includes(command, "timeout 120 ansible-playbook --diff -i inventory.ini /work/000001-copy-happy.yml </dev/null")
      refute_includes(command, "--check")

      check = MicrovmBackend.engine_command("/opt/krikri/bin/krikri-playbook", "x.yml", 60, true)
      assert_includes(check, "--check --diff")

      no_diff = MicrovmBackend.engine_command("ansible-playbook", "x.yml", 60, false, false)
      refute_includes(no_diff, "--diff")
    end

    it "installs the pinned ansible-core and the profile's own service packages in the golden" do
      deps = Dependencies.new(<<-YAML)
        deb_modules:
          both: [ansible, python3]
        rpm_modules:
          both: [python3]
        community.docker.docker_container:
          real:
            debian_packages: [python3-docker]
        community.postgresql.postgresql_db:
          real:
            debian_packages: [python3-psycopg2]
            collections: [community.postgresql]
        YAML
      packages = MicrovmBackend.packages_for("ubuntu", deps)
      assert_includes(packages, "mariadb-server")
      assert_includes(packages, "docker.io")
      assert_includes(packages, "python3-psycopg2")
      refute_includes(packages, "dnf")

      rocky = MicrovmBackend.packages_for("rocky", deps)
      assert_includes(rocky, "python3-dnf-plugin-versionlock")
      assert_includes(rocky, "policycoreutils")
      refute_includes(rocky, "mariadb-server")

      assert_includes(MicrovmBackend.collections_for("ubuntu", deps), "community.postgresql")
    end

    it "keeps the two golden profiles within one prep script each" do
      assert_includes(MicrovmBackend.prep_for("ubuntu"), "postgresql")
      assert_includes(MicrovmBackend.prep_for("ubuntu"), "zpool")
      assert_includes(MicrovmBackend.prep_for("rocky"), "firewalld")
    end

    it "keeps the zfs pool's backing file out of /tmp, which empties on boot" do
      prep = MicrovmBackend.prep_for("ubuntu")
      refute_includes(prep, "/tmp/kpg-zfs")
      assert_includes(prep, "/var/lib/kpg-zfs/pool.img")
    end
  end
end
