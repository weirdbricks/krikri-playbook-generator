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
  end
end
