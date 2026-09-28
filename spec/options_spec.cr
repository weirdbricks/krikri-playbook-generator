require "./spec_helper"
require "../src/krikri_playbook_generator/options"

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
      assert_equal("pb/", opts.out_dir)
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

    it "raises on an empty argv" do
      err = assert_raises(InvalidOptionsError) { Options.parse([] of String) }
      assert((err.message || "").includes?("missing command"))
    end

    it "raises on an unknown command" do
      err = assert_raises(InvalidOptionsError) { Options.parse(["bogus"]) }
      assert((err.message || "").includes?("unknown command"))
    end
  end
end
