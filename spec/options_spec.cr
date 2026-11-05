require "./spec_helper"
require "../src/krikri_playbook_generator/options"
require "../src/krikri_playbook_generator/generator"

module KrikriPlaybookGenerator
  describe Options do
    it "parses the generate command with defaults" do
      opts = Options.parse(["generate"])
      assert_equal(Command::Generate, opts.command)
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

    it "defaults keep_going to false and engine_timeout to 120" do
      opts = Options.parse(["run"])
      refute(opts.keep_going?)
      assert_equal(120, opts.engine_timeout)
    end

    it "parses --keep-going and --engine-timeout" do
      opts = Options.parse(["run", "--keep-going", "--engine-timeout", "30"])
      assert(opts.keep_going?)
      assert_equal(30, opts.engine_timeout)
    end

    it "raises on a non-positive --engine-timeout" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["run", "--engine-timeout", "0"]) }
      assert((err.message || "").includes?("--engine-timeout"))
    end

    it "parses --control with --run-on-podman" do
      assert(Options.parse(["run", "--run-on-podman", "--control"]).control?)
    end

    it "refuses --control without --run-on-podman" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["run", "--control"]) }
      assert((err.message || "").includes?("--control"))
    end

    it "parses --refresh-podman-templates with --run-on-podman and refuses it without" do
      assert(Options.parse(["run", "--run-on-podman", "--refresh-podman-templates"]).refresh_podman_templates?)
      err = assert_raises(InvalidOptionsError) { Options.parse(["run", "--refresh-podman-templates"]) }
      assert((err.message || "").includes?("--refresh-podman-templates"))
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

    it "defaults supported_community? to false" do
      refute(Options.parse(["generate"]).supported_community?)
    end

    it "short-circuits --version in main() before Options.parse" do
      # main() intercepts --version/-v/version and prints VERSION without
      # ever reaching Options.parse, which has no version flag by design.
      refute(Options.parse(["generate"]).supported_community?)
    end

    it "parses --supported-community on generate" do
      opts = Options.parse(["generate", "--supported-community"])
      assert(opts.supported_community?)
    end

    it "refuses --supported-community with --modules, --all-modules, or outside generate" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["generate", "--supported-community", "--modules", "apt"]) }
      assert((err.message || "").includes?("--supported-community"))

      err = assert_raises(InvalidOptionsError) { Options.parse(["generate", "--supported-community", "--all-modules"]) }
      assert((err.message || "").includes?("--supported-community"))

      err = assert_raises(InvalidOptionsError) { Options.parse(["run", "--supported-community"]) }
      assert((err.message || "").includes?("--supported-community"))
    end

    it "parses --json with the report command" do
      opts = Options.parse(["report", "--results-dir", "/tmp/r", "--json"])
      assert(opts.json?)
    end

    it "defaults json? to false" do
      refute(Options.parse(["report"]).json?)
    end

    it "refuses --json outside the report command" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["run", "--json"]) }
      assert((err.message || "").includes?("--json"))

      err = assert_raises(InvalidOptionsError) { Options.parse(["generate", "--json"]) }
      assert((err.message || "").includes?("--json"))
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
      kinds = Options.parse_chaos_kinds(%w[typo hallucinate wrong-type bad-choice violate-constraint jinja])
      assert_equal([ChaosKind::Typo, ChaosKind::Hallucinate, ChaosKind::WrongType,
                    ChaosKind::BadChoice, ChaosKind::ViolateConstraint, ChaosKind::Jinja], kinds)
    end

    it "includes jinja in the default chaos kinds" do
      assert_includes(Options.parse(["generate"]).chaos_kinds, "jinja")
    end

    it "parses --min-happy-success on report" do
      opts = Options.parse(["report", "--min-happy-success", "90"])
      assert_equal(90.0, opts.min_happy_success || 0.0)
    end

    it "parses --min-happy-success on a generate that runs a backend" do
      opts = Options.parse(["generate", "--run-on-podman", "--min-happy-success", "75.5"])
      assert_equal(75.5, opts.min_happy_success || 0.0)
    end

    it "defaults min_happy_success to nil" do
      assert_nil(Options.parse(["report"]).min_happy_success)
    end

    it "refuses --min-happy-success on a plain run or a generate without a backend" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["run", "--min-happy-success", "90"]) }
      assert((err.message || "").includes?("--min-happy-success"))

      err = assert_raises(InvalidOptionsError) { Options.parse(["generate", "--min-happy-success", "90"]) }
      assert((err.message || "").includes?("--min-happy-success"))
    end

    it "defaults tasks_per_playbook to 1 (the v1 single-task shape)" do
      assert_equal(1, Options.parse(["generate"]).tasks_per_playbook)
    end

    it "parses --tasks-per-playbook" do
      opts = Options.parse(["generate", "--tasks-per-playbook", "3"])
      assert_equal(3, opts.tasks_per_playbook)
    end

    it "raises on --tasks-per-playbook below 1" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["generate", "--tasks-per-playbook", "0"]) }
      assert((err.message || "").includes?("--tasks-per-playbook"))
    end

    it "defaults to a fresh random seed when --seed is not passed" do
      seeds = [Options.parse(["generate"]).seed, Options.parse(["generate"]).seed]
      refute_equal(seeds[0], seeds[1])
      refute_equal(42, seeds[0])
    end

    it "keeps an explicit --seed" do
      assert_equal(7, Options.parse(["generate", "--seed", "7"]).seed)
      assert(Options.parse(["generate", "--seed", "7"]).seed_given?)
    end

    it "raises on an out-of-range --min-happy-success" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["report", "--min-happy-success", "101"]) }
      assert((err.message || "").includes?("--min-happy-success"))
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

    it "parses --all-modules" do
      opts = Options.parse(["generate", "--all-modules"])
      assert(opts.all_modules?)
    end

    it "raises when --all-modules is combined with --modules" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["generate", "--all-modules", "--modules", "copy"]) }
      assert((err.message || "").includes?("--all-modules"))
      assert((err.message || "").includes?("--modules"))
    end
  end
end
