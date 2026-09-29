require "./spec_helper"
require "../src/krikri_playbook_generator/runner"
require "../src/krikri_playbook_generator/playbook_builder"
require "../src/krikri_playbook_generator/generator"
require "file_utils"
require "json"

module KrikriPlaybookGenerator
  describe Runner::Recap do
    it "parses a real PLAY RECAP counter line" do
      text = <<-TEXT
        PLAY RECAP *******************************************************************
        localhost : ok=1 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=1
        TEXT
      recap = Runner::Recap.parse(text)
      refute_nil(recap)
      assert_equal(1, recap.as(Runner::Recap).ok)
      assert_equal(0, recap.as(Runner::Recap).changed)
      assert_equal(1, recap.as(Runner::Recap).ignored)
    end

    it "returns nil for text with no recap counters" do
      assert_nil(Runner::Recap.parse("some unrelated output"))
    end

    it "ignores ok=N-shaped text appearing before the real PLAY RECAP line" do
      text = <<-TEXT
        TASK [debug] ***
        task output: ok=2 changed=9 unreachable=9 failed=9 skipped=9 ignored=9
        PLAY RECAP *******************************************************************
        localhost : ok=3 changed=1 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0
        TEXT

      recap = Runner::Recap.parse(text)
      refute_nil(recap)
      recap = recap.as(Runner::Recap)
      assert_equal(3, recap.ok)
      assert_equal(1, recap.changed)
      assert_equal(0, recap.ignored)
    end

    it "returns nil when there is a PLAY RECAP header but no counter line" do
      assert_nil(Runner::Recap.parse("PLAY RECAP *****\n(no usable counters here)"))
    end
  end

  describe Runner::PlaybookResult do
    def engine_run(recap : Runner::Recap?, rc : Int32 = 0, stdout : String = "", stderr : String = "") : Runner::EngineRun
      Runner::EngineRun.new("x", rc, recap, stdout, stderr)
    end

    it "is not divergent when both engines report the same recap and byte-identical output" do
      recap = Runner::Recap.new(1, 0, 0, 0, 0, 0)
      result = Runner::PlaybookResult.new("p.yml", engine_run(recap, stdout: "same"), engine_run(recap, stdout: "same"), nil)
      refute(result.divergent?)
      assert(result.masked_identical?)
      assert(result.raw_identical?)
      refute(result.recap_divergent?)
      assert_nil(result.signature)
    end

    it "is divergent when the masked stdout differs even with matching recaps" do
      recap = Runner::Recap.new(1, 0, 0, 0, 0, 0)
      result = Runner::PlaybookResult.new("p.yml",
        engine_run(recap, stdout: "ok: [target]\n"), engine_run(recap, stdout: "ok differently\n"), nil)
      assert(result.divergent?)
      refute_nil(result.signature)
    end

    it "is divergent when the rcs differ even with byte-identical output" do
      recap = Runner::Recap.new(1, 0, 0, 0, 0, 0)
      result = Runner::PlaybookResult.new("p.yml",
        engine_run(recap, rc: 0, stdout: "same"), engine_run(recap, rc: 2, stdout: "same"), nil)
      assert(result.divergent?)
    end

    it "is divergent when exactly one engine timed out" do
      recap = Runner::Recap.new(1, 0, 0, 0, 0, 0)
      a = Runner::EngineRun.new("ansible", 0, recap, "same", "")
      b = Runner::EngineRun.new("krikri", 124, recap, "same", "", true)
      result = Runner::PlaybookResult.new("p.yml", a, b, nil)
      assert(result.divergent?)
    end

    it "ignores the real ansible WARNING lines and temp paths via the mask list" do
      warning = "[WARNING]: Host 'target' is using the discovered Python interpreter at /usr/bin/python3.12\n"
      tmp_a = "created via ansible-tmp-1727612345.12-1234567\n"
      tmp_b = "created via ansible-tmp-1727699999.99-7654321\n"
      result = Runner::PlaybookResult.new("p.yml",
        engine_run(nil, stdout: warning + tmp_a), engine_run(nil, stdout: warning + tmp_b), nil)
      refute(result.divergent?)
      assert(result.raw_identical? == false)
    end

    it "keeps the recap comparison as an independent extra field" do
      a = Runner::Recap.new(1, 0, 0, 0, 0, 0)
      b = Runner::Recap.new(1, 1, 0, 0, 0, 0)
      result = Runner::PlaybookResult.new("p.yml", engine_run(a), engine_run(b), nil)
      assert(result.recap_divergent?)
    end

    it "flags real-ansible failures via rc, ignored counter or a fatal line" do
      ok_recap = Runner::Recap.new(1, 0, 0, 0, 0, 0)
      ignored_recap = Runner::Recap.new(1, 0, 0, 0, 0, 1)

      clean = Runner::PlaybookResult.new("p.yml", engine_run(ok_recap), engine_run(ok_recap), nil)
      refute(clean.ansible_failed?)
      assert_nil(clean.ansible_error_line)

      by_rc = Runner::PlaybookResult.new("p.yml", engine_run(ok_recap, rc: 2), engine_run(ok_recap), nil)
      assert(by_rc.ansible_failed?)

      by_ignored = Runner::PlaybookResult.new("p.yml", engine_run(ignored_recap), engine_run(ok_recap), nil)
      assert(by_ignored.ansible_failed?)

      by_fatal = Runner::PlaybookResult.new("p.yml",
        engine_run(ok_recap, stdout: "fatal: [target]: FAILED! => boom"), engine_run(ok_recap), nil)
      assert(by_fatal.ansible_failed?)
      error_line = by_fatal.ansible_error_line
      refute_nil(error_line)
      assert(error_line.as(String).includes?("fatal:"))
    end

    it "is never divergent when the run itself errored" do
      result = Runner::PlaybookResult.errored("p.yml", nil, "podman died")
      refute(result.divergent?)
      refute(result.raw_identical?)
      assert_equal("podman died", result.error)
    end
  end

  describe Runner do
    it "runs a real generated playbook against real ansible-playbook and krikri-playbook, writing results.jsonl" do
      playbook_dir = File.tempname("kpg-spec-playbooks")
      results_dir = File.tempname("kpg-spec-results")

      task = GeneratedTask.new("debug", "ansible.builtin", {"msg" => YAML::Any.new("krikri-playbook-generator runner spec")})
      playbook_path = PlaybookBuilder.new(playbook_dir).build([task]).first

      krikri_bin = Process.find_executable("krikri-playbook") || "/home/labros/git_work/krikri/bin/krikri-playbook"
      # run_on_podman defaults to false: local is what this spec wants (fast,
      # no container, checks this exact machine's installed engines).
      # PodmanBackend gets its own opt-in integration spec below.
      results = Runner.new([playbook_path], results_dir, krikri_bin: krikri_bin).run

      assert_equal(1, results.size)
      result = results.first
      assert_equal(playbook_path, result.playbook)
      assert_equal(0, result.ansible.rc)
      assert_equal(0, result.krikri.rc)
      meta = result.meta
      refute_nil(meta)
      assert_equal("debug", meta.as(Runner::MetaInfo).module_name)
      lines = File.read_lines(File.join(results_dir, "results.jsonl"))
      assert_equal(1, lines.size)
      parsed = JSON.parse(lines.first)
      assert_equal(playbook_path, parsed["playbook"].as_s)
      assert(parsed["ansible"]["recap"].as_h.has_key?("ok"))
      assert(parsed["ansible"].as_h.has_key?("timed_out"))
      assert(parsed.as_h.has_key?("masked_identical"))
      assert(parsed.as_h.has_key?("signature"))
      assert(parsed.as_h.has_key?("ansible_failed"))
      assert(parsed["diff"].as_h.has_key?("masked"))
      assert(parsed["diff"].as_h.has_key?("raw"))
    ensure
      FileUtils.rm_rf(playbook_dir) if playbook_dir
      FileUtils.rm_rf(results_dir) if results_dir
    end
  end
end
