require "./spec_helper"
require "../src/krikri_playbook_generator/runner"
require "../src/krikri_playbook_generator/playbook_builder"
require "../src/krikri_playbook_generator/generator"
require "file_utils"
require "json"

module KrikriPlaybookGenerator
  describe Runner::Recap do
    it "parses a real PLAY RECAP counter line" do
      recap = Runner::Recap.parse("localhost : ok=1 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=1")
      refute_nil(recap)
      assert_equal(1, recap.as(Runner::Recap).ok)
      assert_equal(0, recap.as(Runner::Recap).changed)
    end

    it "returns nil for text with no recap counters" do
      assert_nil(Runner::Recap.parse("some unrelated output"))
    end
  end

  describe Runner::PlaybookResult do
    def engine_run(recap : Runner::Recap?, rc : Int32 = 0) : Runner::EngineRun
      Runner::EngineRun.new("x", rc, recap, "", "")
    end

    it "is not divergent when both engines report the same recap and rc" do
      recap = Runner::Recap.new(1, 0, 0, 0, 0)
      result = Runner::PlaybookResult.new("p.yml", engine_run(recap), engine_run(recap))
      refute(result.divergent?)
    end

    it "is divergent when recaps differ" do
      a = Runner::Recap.new(1, 0, 0, 0, 0)
      b = Runner::Recap.new(1, 1, 0, 0, 0)
      result = Runner::PlaybookResult.new("p.yml", engine_run(a), engine_run(b))
      assert(result.divergent?)
    end

    it "is divergent when one engine fails and the other doesn't" do
      recap = Runner::Recap.new(1, 0, 0, 0, 0)
      result = Runner::PlaybookResult.new("p.yml", engine_run(recap, rc: 0), engine_run(recap, rc: 2))
      assert(result.divergent?)
    end
  end

  describe Runner do
    it "runs a real generated playbook against real ansible-playbook and krikri-playbook, writing results.jsonl" do
      playbook_dir = File.tempname("kpg-spec-playbooks")
      results_dir = File.tempname("kpg-spec-results")

      task = GeneratedTask.new("debug", "ansible.builtin", {"msg" => YAML::Any.new("krikri-playbook-generator runner spec")})
      playbook_path = PlaybookBuilder.new(playbook_dir).build([task]).first

      krikri_bin = Process.find_executable("krikri-playbook") || "/home/labros/git_work/krikri/bin/krikri-playbook"
      results = Runner.new([playbook_path], results_dir, krikri_bin: krikri_bin).run

      assert_equal(1, results.size)
      result = results.first
      assert_equal(playbook_path, result.playbook)
      assert_equal(0, result.ansible.rc)
      assert_equal(0, result.krikri.rc)

      lines = File.read_lines(File.join(results_dir, "results.jsonl"))
      assert_equal(1, lines.size)
      parsed = JSON.parse(lines.first)
      assert_equal(playbook_path, parsed["playbook"].as_s)
      assert(parsed["ansible"]["recap"].as_h.has_key?("ok"))
    ensure
      FileUtils.rm_rf(playbook_dir) if playbook_dir
      FileUtils.rm_rf(results_dir) if results_dir
    end
  end
end
