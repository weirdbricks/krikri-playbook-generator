require "./spec_helper"
require "../src/krikri_playbook_generator/podman_backend"
require "../src/krikri_playbook_generator/playbook_builder"
require "../src/krikri_playbook_generator/generator"
require "file_utils"

module KrikriPlaybookGenerator
  describe PodmanBackend do
    it "reports available? true when podman is on PATH" do
      assert_equal(!!Process.find_executable("podman"), PodmanBackend.available?)
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
