require "./spec_helper"
require "../src/krikri_playbook_generator/overrides"

module KrikriPlaybookGenerator
  describe Overrides do
    it "resolves a module's own override before a names entry" do
      overrides = Overrides.load
      mode = overrides.for_option("file", "mode")
      refute_nil(mode)
      assert_equal("mode", mode.as(Overrides::OptionOverride).kind)
    end

    it "applies names entries to modules without their own override" do
      overrides = Overrides.load
      owner = overrides.for_option("some_unknown_module", "owner")
      refute_nil(owner)
      assert_equal("owner", owner.as(Overrides::OptionOverride).kind)
    end

    it "exposes the file.state choices whitelist" do
      overrides = Overrides.load
      state = overrides.for_option("file", "state")
      refute_nil(state)
      assert_equal(%w[touch directory absent], state.as(Overrides::OptionOverride).choices)
    end

    it "flags excluded options via module entries and names entries" do
      overrides = Overrides.load
      assert(overrides.excluded?("user", "uid"))
      assert(overrides.excluded?("user", "password_expire_min"))
      assert(overrides.excluded?("copy", "content"))
      assert(overrides.excluded?("some_unknown_module", "seuser"))
      refute(overrides.excluded?("copy", "src"))
    end

    it "exposes module-level require_one_of groups" do
      overrides = Overrides.load
      assert_equal([["src", "content"]], overrides.require_one_of("copy"))
      assert_equal([["line", "regexp"]], overrides.require_one_of("lineinfile"))
      assert_empty(overrides.require_one_of("debug"))
    end

    it "exposes the always-include list" do
      overrides = Overrides.load
      assert_equal(["state"], overrides.always("file"))
      assert_empty(overrides.always("copy"))
    end

    it "exposes a module-level free-form pool" do
      overrides = Overrides.load
      assert_includes(overrides.free_form("meta"), "noop")
      assert_empty(overrides.free_form("apt"))
    end

    it "still reads shell's free_form option as an excluded option, not a module key" do
      overrides = Overrides.load
      assert_empty(overrides.free_form("shell"))
      assert(overrides.excluded?("shell", "free_form"))
    end

    it "keeps module-level keys out of the per-option override map" do
      overrides = Overrides.load
      assert_nil(overrides.for_option("meta", "free_form"))
      assert_nil(overrides.for_option("fail", "expect_failure"))
      assert_nil(overrides.for_option("file", "always"))
      assert_nil(overrides.for_option("copy", "require_one_of"))
    end

    it "exposes expect_failure for modules whose purpose is to fail" do
      overrides = Overrides.load
      assert(overrides.expect_failure?("fail"))
      refute(overrides.expect_failure?("apt"))
    end

    it "parses free-form and expect_failure from a custom yaml" do
      overrides = Overrides.new(<<-YAML)
        modules:
          widget:
            free_form:
              pool: [go, stop]
          broken:
            expect_failure: true
            msg: {kind: literal_pool, pool: ["boom"]}
      YAML

      assert_equal(["go", "stop"], overrides.free_form("widget"))
      assert(overrides.expect_failure?("broken"))
      refute(overrides.excluded?("broken", "msg"))
    end

    it "names the fixture role for the role-loading actions and excludes the dict-typed apply" do
      overrides = Overrides.load
      %w[include_role import_role].each do |module_name|
        name = overrides.for_option(module_name, "name")
        refute_nil(name)
        assert_equal(["/opt/kpg-fixtures/roles/kpgrole"], name.as(Overrides::OptionOverride).pool)
      end
      assert(overrides.excluded?("include_role", "apply"))
      from = overrides.for_option("import_role", "tasks_from")
      refute_nil(from)
      assert_equal(["main"], from.as(Overrides::OptionOverride).pool)
    end
  end
end
