require "./spec_helper"
require "../src/krikri_playbook_generator/triage"
require "file_utils"
require "json"

module KrikriPlaybookGenerator
  describe Triage do
    def write_result(dir : String, name : String, module_name : String, divergent : Bool,
                     signature : String? = nil, chaos : Bool = false,
                     mutations : Array({String, String}) = [] of {String, String},
                     ansible_failed : Bool = false, ansible_error : String? = nil,
                     error : String? = nil) : String
      playbook = File.join(dir, "#{name}.yml")
      File.write(playbook, "---\n")

      result = {
        "playbook"       => playbook,
        "module"         => module_name,
        "chaos"          => chaos,
        "divergent"      => divergent,
        "signature"      => signature,
        "ansible_failed" => ansible_failed,
        "ansible_error"  => ansible_error,
        "mutations"      => mutations.map { |(option, kind)| {"option" => option, "kind" => kind} },
        "error"          => error,
      }
      File.open(File.join(dir, "results.jsonl"), "a") { |file| file.puts(result.to_json) }
      playbook
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
      write_result(dir, "a", "apt", divergent: false)

      assert_empty(Triage.new(dir).report)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "groups divergent playbooks by module + signature" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "copy", divergent: true, signature: "abc123def456")
      write_result(dir, "b", "copy", divergent: true, signature: "abc123def456")
      write_result(dir, "c", "copy", divergent: true, signature: "fff000111222")

      findings = Triage.new(dir).report
      assert_equal(2, findings.size)
      assert_equal("copy", findings.first.module_name)
      assert_equal(2, findings.first.count)
      assert_equal("abc123def456", findings.first.signature)
      assert(findings.first.playbooks.all? { |path| path.ends_with?(".yml") })
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "sorts findings by descending divergence count" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "apt", divergent: true, signature: "aaa")
      write_result(dir, "b", "user", divergent: true, signature: "bbb")
      write_result(dir, "c", "user", divergent: true, signature: "bbb")

      findings = Triage.new(dir).report
      assert_equal("user", findings.first.module_name)
      assert_equal(2, findings.first.count)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "exposes one example playbook and mutations per finding" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      playbook = write_result(dir, "a", "copy", divergent: true, signature: "abc",
        chaos: true, mutations: [{"mode", "WrongType"}])

      finding = Triage.new(dir).report.first
      assert_equal(playbook, finding.playbooks.first)
      assert_equal(1, finding.example_mutations.size)
      assert_equal("WrongType", finding.example_mutations.first.kind)
      assert_equal("mode", finding.example_mutations.first.option)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "formats a copy-paste repro command for an example playbook" do
      command = Triage.repro_command("/tmp/playbooks/000001-copy-happy.yml")
      assert(command.includes?("run /tmp/playbooks/000001-copy-happy.yml"))
      assert(command.includes?("--run-on-podman"))
    end

    it "reports per-module happy-path failures on real ansible with the first error line" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "copy", divergent: false, ansible_failed: true,
        ansible_error: "fatal: [target]: FAILED! => could not find src")
      write_result(dir, "b", "copy", divergent: false)
      write_result(dir, "c", "user", divergent: false, ansible_failed: true,
        ansible_error: "fatal: [target]: user foo does not exist")

      quality = Triage.new(dir).quality
      assert_equal(2, quality.size)
      copy = quality.find { |entry| entry.module_name == "copy" } || raise("missing copy")
      assert_equal(1, copy.failed)
      assert_equal(2, copy.total)
      assert(copy.example_error.includes?("could not find src"))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "excludes chaos playbooks and errored runs from the quality metric" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "copy", divergent: true, chaos: true,
        mutations: [{"mode", "WrongType"}], ansible_failed: true,
        ansible_error: "fatal: bad chaos value")
      write_result(dir, "b", "copy", divergent: false, error: "podman died")

      assert_empty(Triage.new(dir).quality)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "reports per-module byte-identical rates" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "copy", divergent: false)
      write_result(dir, "b", "copy", divergent: true, signature: "abc")
      write_result(dir, "c", "user", divergent: false)

      rates = Triage.new(dir).rates
      copy = rates.find { |rate| rate.module_name == "copy" } || raise("missing copy")
      user = rates.find { |rate| rate.module_name == "user" } || raise("missing user")
      assert_equal(1, copy.identical)
      assert_equal(2, copy.total)
      assert_equal(1, user.identical)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "skips a malformed results.jsonl line instead of crashing the whole report" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "apt", divergent: true, signature: "aaa")
      write_result(dir, "b", "user", divergent: true, signature: "bbb")

      File.open(File.join(dir, "results.jsonl"), "a") do |file|
        file.puts("{\"playbook\": \"/truncated\", \"divergent\": tru")
      end

      findings = Triage.new(dir).report
      assert_equal(2, findings.size)
      assert_equal(%w[apt user], findings.map(&.module_name).sort!)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "skips result lines missing the module field (legacy results.jsonl)" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      File.open(File.join(dir, "results.jsonl"), "w") do |file|
        file.puts({"playbook" => File.join(dir, "x.yml"), "divergent" => true}.to_json)
      end

      assert_empty(Triage.new(dir).report)
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end
