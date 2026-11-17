require "./spec_helper"
require "../src/krikri_playbook_generator/play_keywords"

module KrikriPlaybookGenerator
  describe PlayKeywords do
    it "parses a kind list and turns `none` into an empty axis" do
      assert_equal(%w[strategy serial], PlayKeywords.parse_list("strategy,serial"))
      assert_equal([] of String, PlayKeywords.parse_list("none"))
      assert_nil(PlayKeywords.parse_list("strategy,bogus"))
      assert_nil(PlayKeywords.parse_list(""))
    end

    it "lists exactly the keywords the issue names, forks included" do
      %w[strategy serial throttle any_errors_fatal run_once max_fail_percentage
        gather_facts connection forks].each do |kind|
        assert(PlayKeywords::KINDS.includes?(kind), "#{kind} missing from the axis")
        assert(PlayKeywords::VALUES.has_key?(kind))
        assert(PlayKeywords::CHAOS_VALUES.has_key?(kind))
      end
    end

    it "gives every keyword a value ansible accepts and a chaos value it does not" do
      PlayKeywords::KINDS.each do |kind|
        assert_equal(false, PlayKeywords::VALUES[kind].empty?)
        assert_equal(false, PlayKeywords::CHAOS_VALUES[kind].empty?)
      end
      assert_equal(["linear", "free", "host_pinned", "debug"], PlayKeywords::VALUES["strategy"])
      assert_equal(["local"], PlayKeywords::VALUES["connection"])
    end
  end

  describe PlaySetting do
    it "renders a play key and an env variant differently" do
      play = PlaySetting.new("strategy", "free")
      assert_equal("strategy: free", play.label)
      assert_equal("play", play.source)
      assert_equal({} of String => String, play.env)

      env = PlaySetting.new("strategy", "free", "ANSIBLE_STRATEGY")
      assert_equal("ANSIBLE_STRATEGY=free", env.label)
      assert_equal("env", env.source)
      assert_equal({"ANSIBLE_STRATEGY" => "free"}, env.env)
    end
  end

  describe PlaySettingSampler do
    it "is deterministic per seed and draws only valid values in a happy path" do
      first = Array.new(30) { PlaySettingSampler.new(7).sample(false) }
      second = Array.new(30) { PlaySettingSampler.new(7).sample(false) }
      assert_equal(first.map(&.to_s), second.map(&.to_s))

      settings = first.map { |setting| setting.as(PlaySetting) }
      settings.each do |setting|
        assert(PlayKeywords::VALUES[setting.keyword].includes?(setting.value))
      end
    end

    it "draws an invalid value only for a chaos playbook" do
      settings = Array.new(30) { PlaySettingSampler.new(11).sample(true) }
        .map { |setting| setting.as(PlaySetting) }
      settings.each do |setting|
        assert(PlayKeywords::CHAOS_VALUES[setting.keyword].includes?(setting.value))
      end
    end

    it "always delivers forks through the environment (it has no play key)" do
      sampler = PlaySettingSampler.new(5, ["forks"])
      Array.new(10) do
        setting = sampler.sample(false).as(PlaySetting)
        assert_equal("forks", setting.keyword)
        assert_equal("ANSIBLE_FORKS", setting.env_key)
        assert(setting.env?)
      end
    end

    it "exercises both doors for an env-capable keyword" do
      sampler = PlaySettingSampler.new(3, ["strategy"])
      settings = Array.new(40) { sampler.sample(false).as(PlaySetting) }
      assert(settings.any?(&.env?))
      assert(settings.any? { |setting| !setting.env? })
      settings.each do |setting|
        assert_equal("ANSIBLE_STRATEGY", setting.env_key) if setting.env?
      end
    end

    it "returns nil when the axis is off" do
      assert_nil(PlaySettingSampler.new(1, [] of String).sample(false))
      assert(PlaySettingSampler.new(1, [] of String).empty?)
    end

    it "draws the custom strategy only when its pool is passed in" do
      custom = PlaySettingSampler.new(3, ["strategy"], ["kpg_custom"])
      Array.new(5) do
        setting = custom.sample(false).as(PlaySetting)
        assert_equal("strategy", setting.keyword)
        assert_equal("kpg_custom", setting.value)
      end
      refute(PlayKeywords::VALUES["strategy"].includes?("kpg_custom"))
    end
  end
end
