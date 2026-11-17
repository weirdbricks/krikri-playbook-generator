require "./spec_helper"
require "../src/krikri_playbook_generator/triage"
require "../src/krikri_playbook_generator/masks"
require "file_utils"
require "json"

module KrikriPlaybookGenerator
  describe Triage do
    def write_result(dir : String, name : String, module_name : String, divergent : Bool,
                     signature : String? = nil, chaos : Bool = false,
                     mode : String = "real", run : Int32 = 1,
                     user : String = "root", umask : String = "022", hosts : Int32 = 1,
                     limit : String = "off", profile : String = "debian",
                     mutations : Array({String, String}) = [] of {String, String},
                     ansible_failed : Bool = false, ansible_error : String? = nil,
                     error : String? = nil, masked_diff : String = "",
                     masked_identical : Bool? = nil, state_divergent : Bool = false,
                     state_diff : String = "", check_mode_mutated : Bool = false,
                     check_mode_diff : String = "", leftover_temps : String = "",
                     library_target : String? = nil, core_version : String = "2.21.6") : String
      playbook = File.join(dir, "#{name}.yml")
      File.write(playbook, "---\n")

      result = {
        "playbook"           => playbook,
        "module"             => module_name,
        "mode"               => mode,
        "run"                => run,
        "user"               => user,
        "umask"              => umask,
        "hosts"              => hosts,
        "limit"              => limit,
        "profile"            => profile,
        "core_version"       => core_version,
        "chaos"              => chaos,
        "divergent"          => divergent,
        "masked_identical"   => masked_identical.nil? ? !divergent : masked_identical,
        "state_divergent"    => state_divergent,
        "state_diff"         => state_diff.empty? ? nil : state_diff,
        "check_mode_mutated" => check_mode_mutated,
        "check_mode_diff"    => check_mode_diff.empty? ? nil : check_mode_diff,
        "leftover_temps"     => leftover_temps.empty? ? nil : leftover_temps,
        "signature"          => signature,
        "ansible_failed"     => ansible_failed,
        "ansible_error"      => ansible_error,
        "mutations"          => mutations.map { |(option, kind)| {"option" => option, "kind" => kind} },
        "error"              => error,
        "diff"               => {"masked" => masked_diff, "raw" => ""},
        "library"            => library_target ? {"target" => library_target, "shape" => "probe"} : nil,
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
      assert(findings.first.playbooks.all?(&.ends_with?(".yml")))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "merges a finding across reference core versions and pins the version in a repro" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "copy", divergent: true, signature: "same", core_version: "2.20.1")
      write_result(dir, "b", "copy", divergent: true, signature: "same", core_version: "2.21.6")

      findings = Triage.new(dir).report
      assert_equal(1, findings.size)
      assert_equal(%w[2.20.1 2.21.6], findings.first.core_versions)

      command = Triage.repro_command(findings.first.playbooks.first, ["copy"], core_version: "2.20.1")
      assert(command.includes?("--reference-core-version 2.20.1"))
      # The default version is the backend default and stays unpinned.
      refute(Triage.repro_command("x.yml", ["copy"], core_version: "2.21.6").includes?("--reference-core-version"))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "groups the same signature separately per identity and umask" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      diff = "stdout:\n--- a\n+++ b\n"
      write_result(dir, "root-a", "file", divergent: true, masked_identical: false,
        signature: "same", masked_diff: diff)
      write_result(dir, "root-b", "file", divergent: true, masked_identical: false,
        signature: "same", masked_diff: diff)
      write_result(dir, "nr", "file", divergent: true, masked_identical: false,
        signature: "same", masked_diff: diff, user: "nonroot")
      write_result(dir, "u77", "file", divergent: true, masked_identical: false,
        signature: "same", masked_diff: diff, umask: "077")

      findings = Triage.new(dir).report
      assert_equal(3, findings.size)
      assert_equal([1, 1, 2], findings.map(&.count).sort!)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "groups the same signature separately per host count and pins it in the repro" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      diff = "stdout:\n--- a\n+++ b\n"
      write_result(dir, "one-host", "file", divergent: true, masked_identical: false,
        signature: "same", masked_diff: diff)
      write_result(dir, "two-hosts", "file", divergent: true, masked_identical: false,
        signature: "same", masked_diff: diff, hosts: 2)

      findings = Triage.new(dir).report
      assert_equal(2, findings.size)
      assert_equal([1, 1], findings.map(&.count))

      command = Triage.repro_command("/tmp/p.yml", ["copy"], "real", 2, true, "root", "022", 2)
      assert(command.includes?("--hosts 2"))
      refute(Triage.repro_command("/tmp/p.yml", ["copy"], "real", 2, true, "root", "022", 1)
        .includes?("--hosts"))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "exports a row's env-var play keyword in its repro command" do
      command = Triage.repro_command("/tmp/p.yml", ["copy"], "real", 1, true, "root", "022", 1,
        {"ANSIBLE_STRATEGY" => "free"})
      assert(command.starts_with?("ANSIBLE_STRATEGY=free krikri-playbook-generator run"))
      refute(Triage.repro_command("/tmp/p.yml", ["copy"]).starts_with?("ANSIBLE_"))
    end

    it "groups the same signature separately per limit and pins it in the repro" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      diff = "stdout:\n--- a\n+++ b\n"
      write_result(dir, "plain", "file", divergent: true, masked_identical: false,
        signature: "same", masked_diff: diff)
      write_result(dir, "limited", "file", divergent: true, masked_identical: false,
        signature: "same", masked_diff: diff, limit: "one")

      assert_equal(2, Triage.new(dir).report.size)

      command = Triage.repro_command("/tmp/p.yml", ["copy"], "real", 1, true, "root", "022", 1,
        {} of String => String, "one")
      assert(command.includes?("--limit one"))
      refute(Triage.repro_command("/tmp/p.yml", ["copy"]).includes?("--limit"))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "groups and rates per host image, and pins neither in the repro" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      diff = "stdout:\n--- a\n+++ b\n"
      write_result(dir, "deb", "package", divergent: true, masked_identical: false,
        signature: "same", masked_diff: diff)
      write_result(dir, "rpm", "package", divergent: true, masked_identical: false,
        signature: "same", masked_diff: diff, profile: "rocky")

      assert_equal(2, Triage.new(dir).report.size)
      rates = Triage.new(dir).rates
      assert_equal(%w[debian rocky], rates.map(&.profile))
      assert_equal(["package [debian]", "package [rocky]"], rates.map(&.label))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "pins the identity and umask in a nonroot finding's repro" do
      command = Triage.repro_command("/tmp/p.yml", ["copy"], "real", 2, true, "nonroot", "077")
      assert(command.includes?("--user-profile nonroot"))
      assert(command.includes?("--umask 077"))

      root = Triage.repro_command("/tmp/p.yml", ["copy"], "real", 2, true, "root", "022")
      refute(root.includes?("--user-profile"))
      assert(root.includes?("--umask 022"))
    end

    it "groups the same playbook separately per mode and run" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "copy", divergent: true, signature: "abc", mode: "check", run: 1)
      write_result(dir, "b", "copy", divergent: true, signature: "abc", mode: "real", run: 1)
      write_result(dir, "c", "copy", divergent: true, signature: "abc", mode: "real", run: 2)

      findings = Triage.new(dir).report
      assert_equal(3, findings.size)
      assert_equal(%w[check real real], findings.map { |finding| finding.example.mode }.sort!)
      assert_equal([1, 1, 2], findings.map { |finding| finding.example.run }.sort!)
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
      command = Triage.repro_command("/tmp/playbooks/000001-copy-happy.yml", ["copy"])
      assert(command.includes?("run /tmp/playbooks/000001-copy-happy.yml"))
      assert(command.includes?("--run-on-podman"))
      assert(command.includes?("--no-second-run"))
    end

    it "pins the repro to the finding's mode and keeps both runs for a run-2 finding" do
      check = Triage.repro_command("/tmp/p.yml", ["copy"], "check", 1)
      assert(check.includes?("--modes check"))
      assert(check.includes?("--no-second-run"))

      second = Triage.repro_command("/tmp/p.yml", ["copy"], "real", 2)
      assert(second.includes?("--modes real"))
      refute(second.includes?("--no-second-run"))
    end

    it "skips diff in a repro when the batch never compared diff output" do
      refute(Triage.repro_command("/tmp/p.yml", ["copy"]).includes?("--no-diff"))
      assert(Triage.repro_command("/tmp/p.yml", ["copy"], nil, 1, false).includes?("--no-diff"))
    end

    it "points a service module's repro at the backend that can host it" do
      command = Triage.repro_command("/tmp/playbooks/000001-postgresql_db-happy.yml",
        ["community.postgresql.postgresql_db"])
      assert(command.includes?("--run-on-mixed"))
      refute(command.includes?("--run-on-podman"))
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

    it "keeps second-run rows out of the quality and happy-coverage metrics" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "copy", divergent: false, run: 1)
      write_result(dir, "b", "copy", divergent: false, run: 2,
        ansible_failed: true, ansible_error: "fatal: second run")

      triage = Triage.new(dir)
      assert_empty(triage.quality)
      assert_equal(1, triage.happy_coverage.attempted)
      assert_equal(0, triage.happy_coverage.failed)
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

    it "excludes modules marked expect_failure from the wasted-coverage metric" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "fail", divergent: false, ansible_failed: true,
        ansible_error: "fatal: [target]: FAILED! => [kpg expected failure]")
      write_result(dir, "b", "copy", divergent: false, ansible_failed: true,
        ansible_error: "fatal: [target]: FAILED! => could not find src")

      triage = Triage.new(dir)
      quality = triage.quality
      assert_equal(1, quality.size)
      assert_equal("copy", quality.first.module_name)
      assert_equal(["fail"], triage.expected_failures)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "excludes modules marked not_applicable from the coverage metrics" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "reboot", divergent: true, ansible_failed: true,
        ansible_error: "fatal: running reboot with local connection would reboot the control node")
      write_result(dir, "b", "copy", divergent: false)

      triage = Triage.new(dir)
      assert_empty(triage.quality)
      assert_equal(["reboot"], triage.not_applicable_modules)
      assert_equal(1, triage.happy_coverage.attempted)
      assert_equal(0, triage.happy_coverage.failed)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "keeps a library probe out of the quality and happy-coverage metrics but still reports it" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "probe", "kpg_mu_facts", divergent: true, signature: "libsig",
        ansible_failed: true, ansible_error: "No module named 'ansible.module_utils.facts'",
        library_target: "ansible.module_utils.facts")
      write_result(dir, "copy", "copy", divergent: false)

      triage = Triage.new(dir)
      assert_empty(triage.quality)
      assert_equal(1, triage.happy_coverage.attempted)
      assert_equal(0, triage.happy_coverage.failed)
      # the probe's own divergence is still a finding, grouped by its module
      findings = triage.report
      assert_equal(1, findings.size)
      assert_equal("kpg_mu_facts", findings.first.module_name)
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

    it "computes the batch happy-path success rate, excluding chaos, errored and expect_failure runs" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "copy", divergent: false)
      write_result(dir, "b", "copy", divergent: false, ansible_failed: true,
        ansible_error: "fatal: could not find src")
      write_result(dir, "c", "copy", divergent: true, chaos: true, ansible_failed: true,
        mutations: [{"mode", "WrongType"}])
      write_result(dir, "d", "copy", divergent: false, error: "podman died")
      write_result(dir, "e", "fail", divergent: false, ansible_failed: true,
        ansible_error: "fatal: expected failure")

      coverage = Triage.new(dir).happy_coverage
      assert_equal(2, coverage.attempted)
      assert_equal(1, coverage.failed)
      assert_equal(1, coverage.succeeded)
      assert_equal(50.0, coverage.success_rate)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "reports a 100% happy-path success rate when there are no happy-path playbooks" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "copy", divergent: true, chaos: true,
        mutations: [{"mode", "WrongType"}])

      coverage = Triage.new(dir).happy_coverage
      assert_equal(0, coverage.attempted)
      assert_equal(100.0, coverage.success_rate)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "renders the full JSON report shape from results.jsonl" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      playbook_a = write_result(dir, "a", "copy", divergent: true, signature: "abc",
        chaos: true, mutations: [{"mode", "WrongType"}],
        masked_diff: "stdout:\n--- a\n+++ b\n", ansible_error: "fatal: boom")
      write_result(dir, "b", "copy", divergent: true, signature: "abc",
        masked_diff: "stdout:\n--- a\n+++ b\n")
      write_result(dir, "c", "apt", divergent: false)
      write_result(dir, "d", "user", divergent: false, error: "podman died")

      report = JSON.parse(Triage.new(dir).report_json)

      assert_equal(File.expand_path(dir), report["results_dir"].as_s)
      assert_equal(4, report["total"].as_i)
      assert_equal(1, report["errored"].as_i)
      assert_equal(2, report["divergent"].as_i)

      findings = report["findings"].as_a
      assert_equal(1, findings.size)
      copy = findings.first
      assert_equal("copy", copy["module"].as_s)
      expected_signature = ByteDiff.signature("stdout:\n--- a\n+++ b\n") || raise("no signature")
      assert_equal(expected_signature, copy["signature"].as_s)
      assert_equal(2, copy["count"].as_i)
      assert_equal([playbook_a, File.join(dir, "b.yml")], copy["playbooks"].as_a.map(&.as_s))

      example = copy["example"]
      assert_equal(playbook_a, example["playbook"].as_s)
      assert_equal("real", example["mode"].as_s)
      assert_equal(1, example["run"].as_i)
      assert_equal(true, example["chaos"].as_bool)
      assert_equal([{"option" => "mode", "kind" => "WrongType"}],
        example["mutations"].as_a.map { |entry| {"option" => entry["option"].as_s, "kind" => entry["kind"].as_s} })
      assert(example["masked_diff"].as_s.includes?("+++ b"))
      assert_equal("fatal: boom", example["ansible_error"].as_s)

      errors = report["errors"].as_a
      assert_equal(1, errors.size)
      assert_equal(File.join(dir, "d.yml"), errors.first["playbook"].as_s)
      assert_equal("user", errors.first["module"].as_s)
      assert_equal("podman died", errors.first["error"].as_s)
      assert_equal([] of String, report["not_applicable"].as_a.map(&.as_s))

      rates = report["rates"].as_a
      apt = rates.find { |rate| rate["module"].as_s == "apt" } || raise("missing apt")
      assert_equal(1, apt["identical"].as_i)
      assert_equal(1, apt["total"].as_i)

      coverage = report["happy_coverage"]
      assert_equal(2, coverage["attempted"].as_i)
      assert_equal(0, coverage["failed"].as_i)
      assert_equal(2, coverage["succeeded"].as_i)
      assert_equal(100.0, coverage["success_percent"].as_f)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "recomputes the signature from the masked diff instead of the stored one" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "copy", divergent: true, signature: "stale0000000",
        masked_diff: "stdout:\n--- a\n+++ b\n")

      finding = Triage.new(dir).report.first
      assert_equal(ByteDiff.signature("stdout:\n--- a\n+++ b\n"), finding.signature)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "renders nulls for a missing signature and ansible_error in the JSON report" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "apt", divergent: true)

      report = JSON.parse(Triage.new(dir).report_json)
      finding = report["findings"].as_a.first

      assert(finding["signature"].raw.nil?)
      assert(finding["example"]["ansible_error"].raw.nil?)
      assert_equal("", finding["example"]["masked_diff"].as_s)
      assert_equal(0, report["errors"].as_a.size)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "reports a state-only divergence separately and keeps it out of the byte-identical rate" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      state_diff = "-file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover\n"
      write_result(dir, "a", "copy", divergent: true, masked_identical: true,
        state_divergent: true, state_diff: state_diff)

      triage = Triage.new(dir)
      assert_empty(triage.report)
      state = triage.state_report
      assert_equal(1, state.size)
      assert_equal("copy", state.first.module_name)
      signature = state.first.signature
      refute_nil(signature)
      assert(signature.as(String).starts_with?("state:"))
      assert_equal(state_diff, state.first.example.state_diff)

      rate = triage.rates.first
      assert_equal(1, rate.identical)
      assert_equal(1, rate.total)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "counts a playbook that diverges on both output and state once (as an output finding)" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "copy", divergent: true, masked_identical: false,
        signature: "abc123", state_divergent: true,
        state_diff: "-file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover\n",
        masked_diff: "stdout:\n--- a\n+++ b\n")

      triage = Triage.new(dir)
      assert_equal(1, triage.report.size)
      assert_empty(triage.state_report)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "groups state-only divergences by their state signature" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      first = "-file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover\n"
      second = "-file\tadded\tf\t0\t0\t644\t9\t/tmp/kpg-work/other\n"
      write_result(dir, "a", "copy", divergent: true, masked_identical: true,
        state_divergent: true, state_diff: first)
      write_result(dir, "b", "copy", divergent: true, masked_identical: true,
        state_divergent: true, state_diff: second)

      state = Triage.new(dir).state_report
      assert_equal(1, state.size)
      assert_equal(2, state.first.count)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "renders state findings and the state divergence count in the JSON report" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      state_diff = "-file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover\n"
      leftover = "krikri:\n+ f\t/tmp/kpg-work/.krikri-playbook-copy-abc.tmp (task: Copy)\n"
      write_result(dir, "a", "copy", divergent: true, masked_identical: true,
        state_divergent: true, state_diff: state_diff, leftover_temps: leftover)

      report = JSON.parse(Triage.new(dir).report_json)
      assert_equal(1, report["state_divergent"].as_i)
      assert_equal(0, report["findings"].as_a.size)
      findings = report["state_findings"].as_a
      assert_equal(1, findings.size)
      assert_equal("state", findings.first["kind"].as_s)
      assert_equal(state_diff, findings.first["example"]["state_diff"].as_s)
      assert_equal(leftover, findings.first["example"]["leftover_temps"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "keeps a state finding whose only detail is the leftover staging file" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      leftover = "krikri:\n+ f\t/tmp/kpg-work/.krikri-playbook-copy-abc.tmp\n"
      write_result(dir, "a", "copy", divergent: true, masked_identical: true,
        state_divergent: true, leftover_temps: leftover)

      triage = Triage.new(dir)
      findings = triage.state_report
      assert_equal(1, findings.size)
      assert_equal(leftover, findings.first.example.leftover_temps)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "reports a check-mode mutation separately from output and state findings" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      diff = "ansible:\n+ file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover\n" \
             "krikri:\n+ file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover\n"
      write_result(dir, "a", "copy", divergent: true, masked_identical: true,
        mode: "check", check_mode_mutated: true, check_mode_diff: diff)

      triage = Triage.new(dir)
      assert_empty(triage.report)
      assert_empty(triage.state_report)
      findings = triage.check_mode_report
      assert_equal(1, findings.size)
      signature = findings.first.signature
      refute_nil(signature)
      assert(signature.as(String).starts_with?("check-mode:"))
      assert_equal(diff, findings.first.example.check_mode_diff)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "counts a check-mode mutation once when the output diverges too" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "copy", divergent: true, masked_identical: false,
        mode: "check", signature: "abc123", check_mode_mutated: true,
        check_mode_diff: "krikri:\n+ file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover\n",
        masked_diff: "stdout:\n--- a\n+++ b\n")

      triage = Triage.new(dir)
      assert_equal(1, triage.report.size)
      assert_empty(triage.check_mode_report)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "prefers a check-mode finding over a state-only one for the same mutation" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "copy", divergent: true, masked_identical: true,
        mode: "check", state_divergent: true,
        state_diff: "-file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover\n",
        check_mode_mutated: true,
        check_mode_diff: "krikri:\n+ file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover\n")

      triage = Triage.new(dir)
      assert_empty(triage.state_report)
      assert_equal(1, triage.check_mode_report.size)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "groups check-mode mutations by signature and renders them in the JSON report" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      first = "ansible:\n+ file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover\n"
      second = "ansible:\n+ file\tadded\tf\t0\t0\t644\t9\t/tmp/kpg-work/other\n"
      write_result(dir, "a", "copy", divergent: true, masked_identical: true,
        mode: "check", check_mode_mutated: true, check_mode_diff: first)
      write_result(dir, "b", "copy", divergent: true, masked_identical: true,
        mode: "check", check_mode_mutated: true, check_mode_diff: second)

      triage = Triage.new(dir)
      findings = triage.check_mode_report
      assert_equal(1, findings.size)
      assert_equal(2, findings.first.count)

      report = JSON.parse(triage.report_json)
      assert_equal(2, report["check_mode_divergent"].as_i)
      assert_equal(0, report["state_findings"].as_a.size)
      rendered = report["check_mode_findings"].as_a
      assert_equal(1, rendered.size)
      assert_equal("check-mode", rendered.first["kind"].as_s)
      assert_equal(first, rendered.first["example"]["check_mode_diff"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "reads the batch modes, duration and idempotency flag from versions.txt" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      write_result(dir, "a", "apt", divergent: false)
      File.write(File.join(dir, "versions.txt"), <<-TEXT)
        tool: krikri-playbook-generator 0.0.8
        modes: check,real
        idempotency: true
        diff: true
        reference cores: 2.21.6,2.20.1
        batch duration: 41.2s
        TEXT

      info = Triage.new(dir).batch_info
      assert_equal(%w[check real], info[:modes])
      assert_equal(true, info[:second_run])
      assert_equal(true, info[:diff])
      assert_equal("41.2s", info[:duration])
      assert_equal(%w[2.21.6 2.20.1], info[:cores])
      report = JSON.parse(Triage.new(dir).report_json)
      assert_equal(%w[check real], report["batch"]["modes"].as_a.map(&.as_s))
      assert_equal(true, report["batch"]["second_run"].as_bool)
      assert_equal(true, report["batch"]["diff"].as_bool)
      assert_equal(%w[2.21.6 2.20.1], report["batch"]["reference_cores"].as_a.map(&.as_s))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "treats a legacy divergent line without masked_identical as an output finding" do
      dir = File.tempname("kpg-spec-triage")
      Dir.mkdir_p(dir)
      File.open(File.join(dir, "results.jsonl"), "a") do |file|
        file.puts({
          "playbook"  => File.join(dir, "a.yml"),
          "module"    => "copy",
          "divergent" => true,
          "signature" => "abc",
          "diff"      => {"masked" => "stdout:\n--- a\n+++ b\n", "raw" => ""},
        }.to_json)
      end

      assert_equal(1, Triage.new(dir).report.size)
      assert_empty(Triage.new(dir).state_report)
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end
