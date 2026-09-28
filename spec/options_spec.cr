require "./spec_helper"
require "../src/krikri_playbook_generator/options"
require "../src/krikri_playbook_generator/generator"

module KrikriPlaybookGenerator
  describe Options do
    it "parses the generate command with defaults" do
      opts = Options.parse(["generate"])
      assert_equal(Command::Generate, opts.command)
      assert_equal(42, opts.seed)
      assert_equal(0.0, opts.chaos_percentage)
      assert_nil(opts.modules)
    end

    it "parses generate flags" do
      opts = Options.parse(["generate", "--modules", "apt,copy,user", "--seed", "7",
                            "--count", "500", "--chaos-percentage", "3", "--out", "pb/"])
      assert_equal(%w[apt copy user], opts.modules)
      assert_equal(7, opts.seed)
      assert_equal(500, opts.count)
      assert_equal(3.0, opts.chaos_percentage)
      assert_equal(File.expand_path("pb/"), opts.out_dir)
    end

    it "parses the run command" do
      opts = Options.parse(["run", "--atlantic-hosts", "10", "--results-dir", "/tmp/results"])
      assert_equal(Command::Run, opts.command)
      assert_equal(10, opts.atlantic_hosts)
      assert_equal("/tmp/results", opts.results_dir)
    end

    it "parses the report command" do
      opts = Options.parse(["report", "--results-dir", "/tmp/results"])
      assert_equal(Command::Report, opts.command)
      assert_equal("/tmp/results", opts.results_dir)
    end

    it "defaults run_on_podman? to false" do
      opts = Options.parse(["generate"])
      refute(opts.run_on_podman?)
    end

    it "parses --run-on-podman on generate" do
      opts = Options.parse(["generate", "--run-on-podman"])
      assert(opts.run_on_podman?)
    end

    it "parses --run-on-podman on run" do
      opts = Options.parse(["run", "--run-on-podman"])
      assert(opts.run_on_podman?)
    end

    it "expands a tilde --out to an absolute path under the real HOME" do
      opts = Options.parse(["generate", "--out", "~/foo/kpg"])
      home = ENV["HOME"]
      refute_nil(home)
      assert(opts.out_dir.starts_with?(home.as(String)))
      refute(opts.out_dir.starts_with?("~/"))
    end

    it "expands the tilde default results_dir rather than using it literally" do
      opts = Options.parse(["generate"])
      refute(opts.results_dir.starts_with?("~/"))
      assert(Path[opts.results_dir].absolute?)
    end

    it "expands a tilde --krikri-bin without breaking bare PATH lookups" do
      opts = Options.parse(["run", "--krikri-bin", "~/bin/krikri-playbook"])
      home = ENV["HOME"]
      refute_nil(home)
      assert(opts.krikri_bin.starts_with?(home.as(String)))

      opts = Options.parse(["run"])
      assert_equal("ansible-playbook", opts.ansible_playbook_bin)
    end

    it "raises on an empty argv" do
      err = assert_raises(InvalidOptionsError) { Options.parse([] of String) }
      assert((err.message || "").includes?("missing command"))
    end

    it "raises on an unknown command" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["bogus"]) }
      assert((err.message || "").includes?("unknown command"))
    end

    it "raises on an unknown --chaos-kinds value, naming it" do
      err = assert_raises(InvalidOptionsError) do
        Options.parse(["generate", "--chaos-kinds", "typo,bogus-kind"])
      end
      assert((err.message || "").includes?("bogus-kind"))
    end

    it "maps kebab-case --chaos-kinds values to ChaosKind members" do
      kinds = Options.parse_chaos_kinds(%w[typo hallucinate wrong-type bad-choice violate-constraint])
      assert_equal([ChaosKind::Typo, ChaosKind::Hallucinate, ChaosKind::WrongType,
                    ChaosKind::BadChoice, ChaosKind::ViolateConstraint], kinds)
    end

    it "raises on a non-numeric --seed, naming the flag" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["generate", "--seed", "abc"]) }
      assert((err.message || "").includes?("--seed"))
      assert((err.message || "").includes?("abc"))
    end

    it "raises on a negative --seed" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["generate", "--seed", "-1"]) }
      assert((err.message || "").includes?("--seed"))
    end

    it "raises on a negative --count" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["generate", "--count", "-3"]) }
      assert((err.message || "").includes?("--count"))
    end

    it "raises on a non-numeric --count, naming the flag" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["generate", "--count", "many"]) }
      assert((err.message || "").includes?("--count"))
    end

    it "raises on an out-of-range --chaos-percentage" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["generate", "--chaos-percentage", "150"]) }
      assert((err.message || "").includes?("--chaos-percentage"))
    end

    it "raises on a non-numeric --chaos-percentage, naming the flag" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["generate", "--chaos-percentage", "lots"]) }
      assert((err.message || "").includes?("--chaos-percentage"))
    end

    it "raises on a non-numeric --atlantic-hosts, naming the flag" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["run", "--atlantic-hosts", "fleet"]) }
      assert((err.message || "").includes?("--atlantic-hosts"))
    end
  end
end
