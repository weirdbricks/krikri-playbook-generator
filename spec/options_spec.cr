require "./spec_helper"

module KrikriPlaybookGenerator
  describe Options do
    it "parses the generate command with defaults" do
      opts = Options.parse(["generate"])
      opts.command.should eq(Command::Generate)
      opts.seed.should eq(42)
      opts.chaos_percentage.should eq(0.0)
      opts.modules.should be_nil
    end

    it "parses generate flags" do
      opts = Options.parse(["generate", "--modules", "apt,copy,user", "--seed", "7",
                             "--count", "500", "--chaos-percentage", "3", "--out", "pb/"])
      opts.modules.should eq(%w[apt copy user])
      opts.seed.should eq(7)
      opts.count.should eq(500)
      opts.chaos_percentage.should eq(3.0)
      opts.out_dir.should eq("pb/")
    end

    it "parses the run command" do
      opts = Options.parse(["run", "--atlantic-hosts", "10", "--results-dir", "/tmp/results"])
      opts.command.should eq(Command::Run)
      opts.atlantic_hosts.should eq(10)
      opts.results_dir.should eq("/tmp/results")
    end

    it "parses the report command" do
      opts = Options.parse(["report", "--results-dir", "/tmp/results"])
      opts.command.should eq(Command::Report)
      opts.results_dir.should eq("/tmp/results")
    end

    it "raises on an empty argv" do
      expect_raises(InvalidOptionsError, /missing command/) { Options.parse([] of String) }
    end

    it "raises on an unknown command" do
      expect_raises(InvalidOptionsError, /unknown command/) { Options.parse(["bogus"]) }
    end
  end
end
