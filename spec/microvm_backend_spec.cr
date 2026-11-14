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
      command = MicrovmBackend.overlay_command("/base/gold.qcow2", "/work/disk.qcow2")
      assert_equal("qemu-img create -f qcow2 -F qcow2 -b /base/gold.qcow2 /work/disk.qcow2", command)
      refute_includes(command, " 4G ")
    end

    it "boots with slirp hostfwd on the kpg address space and a separate port from the role tester" do
      command = MicrovmBackend.boot_command("qemu-system-x86_64", "kpg-real-1", "/w/disk.qcow2",
        "/w/seed.iso", "127.90.3.1", MicrovmBackend::SSH_PORT, "/w/console.log", "/w/qemu.pid")
      assert_includes(command, "hostfwd=tcp:127.90.3.1:#{MicrovmBackend::SSH_PORT}-:22")
      assert_includes(command, "-enable-kvm")
      assert_includes(command, "-M q35")
      assert_includes(command, "-drive file=/w/disk.qcow2,if=virtio,format=qcow2")
      assert_includes(command, "-drive file=/w/seed.iso,if=virtio,format=raw,readonly=on")
      refute_equal(2322, MicrovmBackend::SSH_PORT)
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
      assert_includes(command, "timeout 120 ansible-playbook -i inventory.ini /work/000001-copy-happy.yml </dev/null")
      refute_includes(command, "--check")

      check = MicrovmBackend.engine_command("/opt/krikri/bin/krikri-playbook", "x.yml", 60, true)
      assert_includes(check, "--check --diff")
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
  end
end
