require "./spec_helper"
require "../src/krikri_playbook_generator/podman_backend"
require "../src/krikri_playbook_generator/playbook_builder"
require "../src/krikri_playbook_generator/generator"
require "file_utils"

module KrikriPlaybookGenerator
  describe PodmanBackend do
    it "includes the union dependency packages in the template installs" do
      deps = Dependencies.new(<<-YAML)
        supported: [community.general.sudoers]

        deb_modules:
          both: [ansible, python3]
          real: [python3-pexpect]
          krikri: [libxml2]

        rpm_modules:
          both: [python3]
          real: [python3-dnf]
          krikri: []

        community.general.sudoers:
          real:
            debian_packages: [sudo]
        YAML
      backend = PodmanBackend.new("/tmp/krikri-playbook", module_fqcns: [] of String, dependencies: deps)
      sets = backend.package_sets_for_test
      assert_includes(sets.real_debian, "sudo")
      assert_includes(sets.real_debian, "ansible")
      assert_includes(sets.krikri_debian, "libxml2")
      assert_includes(sets.krikri_debian, "ansible")
    end

    it "labels every container it starts with the owner pid and boots the fixture http server" do
      args = PodmanBackend.run_args(PodmanBackend::IMAGE, "kpg-real-1")

      assert_equal(
        ["run", "-d", "--privileged", "--label", "#{PodmanBackend::OWNER_LABEL}=#{Process.pid}", "--name", "kpg-real-1",
         PodmanBackend::IMAGE, "sh", "-c",
         "python3 -m http.server #{Fixtures::HTTP_PORT} --bind 127.0.0.1 --directory #{Fixtures::FIXTURE_ROOT} >/dev/null 2>&1 & exec sleep infinity"],
        args)
    end

    it "reports available? true when podman is on PATH" do
      assert_equal(!!Process.find_executable("podman"), PodmanBackend.available?)
    end

    it "runs each playbook on its own profile's template image, even after another profile was provisioned" do
      skip("podman not available on this machine") unless PodmanBackend.available?

      krikri_bin = Process.find_executable("krikri-playbook") || "/home/labros/git_work/krikri/bin/krikri-playbook"
      skip("no krikri-playbook binary to stage into the container") unless File.exists?(krikri_bin)

      dir = File.tempname("kpg-spec-podman")
      Dir.mkdir_p(dir)
      # /usr/bin/apt-get exists on the Debian pair and nowhere on the Rocky
      # one, so a Debian playbook that runs after the rpm template was
      # provisioned only succeeds if image selection really is per profile.
      task = GeneratedTask.new("command", "ansible.builtin", {} of String => YAML::Any,
        free_form: "/usr/bin/apt-get --version")
      playbook_path = PlaybookBuilder.new(dir).build([task]).first

      backend = PodmanBackend.new(krikri_bin)
      backend.provision(PodmanBackend::Profile::Debian)
      backend.provision(PodmanBackend::Profile::Rpm)
      begin
        outcome = backend.run_playbook(playbook_path, PodmanBackend::Profile::Debian)
        assert_equal(0, outcome[:ansible].rc)
        assert(outcome[:ansible].stdout.includes?("ignored=0"),
          "the Debian playbook was not run on the Debian image:\n#{outcome[:ansible].stdout}")
      ensure
        backend.teardown
      end
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "provisions two throwaway containers, runs a real playbook in each, and tears down cleanly" do
      skip("podman not available on this machine") unless PodmanBackend.available?

      krikri_bin = Process.find_executable("krikri-playbook") || "/home/labros/git_work/krikri/bin/krikri-playbook"
      skip("no krikri-playbook binary to stage into the container") unless File.exists?(krikri_bin)

      dir = File.tempname("kpg-spec-podman")
      Dir.mkdir_p(dir)
      task = GeneratedTask.new("debug", "ansible.builtin", {"msg" => YAML::Any.new("podman backend spec")})
      playbook_path = PlaybookBuilder.new(dir).build([task]).first

      backend = PodmanBackend.new(krikri_bin)
      backend.provision
      begin
        outcome = backend.run_playbook(playbook_path)
        assert_equal(0, outcome[:ansible].rc)
        assert_equal(0, outcome[:krikri].rc)
        assert(outcome[:ansible].stdout.includes?("PLAY RECAP"))
        assert(outcome[:krikri].stdout.includes?("PLAY RECAP"))
      ensure
        backend.teardown
      end
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end
