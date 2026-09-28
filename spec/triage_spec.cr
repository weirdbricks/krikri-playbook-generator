require "./spec_helper"
require "../src/krikri_playbook_generator/triage"
require "file_utils"
require "json"

module KrikriPlaybookGenerator
  describe Triage do
    def write_fixture(dir : String, name : String, divergent : Bool, module_name : String,
                      mutations : Array({String, String}) = [] of {String, String}) : Nil
      playbook = File.join(dir, "#{name}.yml")
      File.write(playbook, "---\n")

      meta = {
        "module"     => module_name,
        "collection" => "ansible.builtin",
        "chaos"      => !mutations.empty?,
        "mutations"  => mutations.map { |(option, kind)| {"option" => option, "kind" => kind} },
      }
      File.write(File.join(dir, "#{name}.meta.json"), meta.to_json)

      result = {"playbook" => playbook, "divergent" => divergent}
      File.open(File.join(dir, "results.jsonl"), "a") { |file| file.puts(result.to_json) }
    end

    it "raises when results.jsonl doesn't exist" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      assert_raises(TriageError) { Triage.new(dir).report }
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "reports nothing when no playbook diverged" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_fixture(dir, "a", divergent: false, module_name: "apt")

      assert_empty(Triage.new(dir).report)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "groups a divergent happy-path playbook under the module with no chaos kind/option" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_fixture(dir, "a", divergent: true, module_name: "apt")

      findings = Triage.new(dir).report
      assert_equal(1, findings.size)
      assert_equal("apt", findings.first.module_name)
      assert_nil(findings.first.chaos_kind)
      assert_nil(findings.first.option)
      assert_equal(1, findings.first.count)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "splits a multi-mutation divergent playbook into one finding per mutation" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_fixture(dir, "a", divergent: true, module_name: "user",
        mutations: [{"shell", "Hallucinate"}, {"state", "BadChoice"}])

      findings = Triage.new(dir).report
      assert_equal(2, findings.size)
      keys = findings.map { |finding| {finding.chaos_kind, finding.option} }
      assert_includes(keys, {"Hallucinate", "shell"})
      assert_includes(keys, {"BadChoice", "state"})
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "dedupes multiple divergent playbooks hitting the same module/kind/option into one finding" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_fixture(dir, "a", divergent: true, module_name: "apt", mutations: [{"state", "BadChoice"}])
      write_fixture(dir, "b", divergent: true, module_name: "apt", mutations: [{"state", "BadChoice"}])
      write_fixture(dir, "c", divergent: false, module_name: "apt", mutations: [{"state", "BadChoice"}])

      findings = Triage.new(dir).report
      assert_equal(1, findings.size)
      assert_equal(2, findings.first.count)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "sorts findings by descending divergence count" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_fixture(dir, "a", divergent: true, module_name: "apt", mutations: [{"state", "BadChoice"}])
      write_fixture(dir, "b", divergent: true, module_name: "user", mutations: [{"shell", "Typo"}])
      write_fixture(dir, "c", divergent: true, module_name: "user", mutations: [{"shell", "Typo"}])

      findings = Triage.new(dir).report
      assert_equal("user", findings.first.module_name)
      assert_equal(2, findings.first.count)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "skips a divergent result whose meta.json sidecar is missing rather than raising" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      result = {"playbook" => File.join(dir, "ghost.yml"), "divergent" => true}
      File.open(File.join(dir, "results.jsonl"), "w") { |file| file.puts(result.to_json) }

      assert_empty(Triage.new(dir).report)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "skips a malformed results.jsonl line instead of crashing the whole report" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_fixture(dir, "a", divergent: true, module_name: "apt", mutations: [{"state", "BadChoice"}])
      write_fixture(dir, "b", divergent: true, module_name: "user", mutations: [{"shell", "Typo"}])

      File.open(File.join(dir, "results.jsonl"), "a") do |file|
        file.puts("{\"playbook\": \"/truncated\", \"divergent\": tru")
      end

      findings = Triage.new(dir).report
      assert_equal(2, findings.size)
      assert_equal(%w[apt user], findings.map(&.module_name).sort!)
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end
