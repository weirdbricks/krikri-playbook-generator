require "./spec_helper"
require "../src/krikri_playbook_generator/plugin_shapes"

module KrikriPlaybookGenerator
  describe LookupShapes do
    def lookup(kind : String) : LookupShape
      LookupShape.parse(kind) || LookupShape::Off
    end

    it "parses every shape the axis documents and turns `none` off" do
      assert_equal(%w[list none], LookupShapes.parse_list("list,none"))
      assert_equal([] of String, LookupShapes.parse_list("none"))
      assert_nil(LookupShapes.parse_list("list,bogus"))

      LookupShapes::KINDS.each do |kind|
        refute_nil(LookupShape.parse(kind), "#{kind} missing")
        assert_equal(kind, lookup(kind).label)
      end
      assert_nil(LookupShape.parse("bogus"))
    end

    it "marks the shapes whose reference-side run fails by design" do
      %w[none undefined raise unknown].each do |kind|
        assert(lookup(kind).failing?, "#{kind} should be a structural failure")
      end
      %w[list query vars module-arg side-effect].each do |kind|
        refute(lookup(kind).failing?, "#{kind} should stay runnable")
      end
    end
  end

  describe ExpressionShapes do
    def expression(kind : String) : ExpressionShape
      ExpressionShape.parse(kind) || ExpressionShape::Off
    end

    it "parses every shape the axis documents and turns `none` off" do
      assert_equal(%w[regex-search], ExpressionShapes.parse_list("regex-search"))
      assert_equal([] of String, ExpressionShapes.parse_list("none"))
      assert_nil(ExpressionShapes.parse_list("regex-search,bogus"))

      ExpressionShapes::KINDS.each do |kind|
        refute_nil(ExpressionShape.parse(kind), "#{kind} missing")
        assert_equal(kind, expression(kind).label)
      end
      assert_nil(ExpressionShape.parse("bogus"))
    end

    it "knows which shapes need the seeded filter plugin" do
      assert(expression("positional").custom_filter?)
      assert(expression("star-args").custom_filter?)
      %w[regex-search regex-replace chain statement empty-render].each do |kind|
        refute(expression(kind).custom_filter?, "#{kind} uses builtin filters")
      end
    end
  end

  describe PluginShapes do
    it "parses the discovery list and refuses unknown paths" do
      assert_equal(%w[relative env], PluginShapes.parse_list("relative,env"))
      assert_equal(%w[config], PluginShapes.parse_list("config"))
      assert_nil(PluginShapes.parse_list("relative,telepathy"))

      assert_equal(PluginDiscovery::Env, PluginDiscovery.parse("env"))
      assert_nil(PluginDiscovery.parse("telepathy"))
      assert_equal("relative", PluginDiscovery::Relative.label)
    end
  end

  describe LookupShapeSampler do
    it "is deterministic per seed and draws only the requested shapes" do
      first = LookupShapeSampler.new(21)
      second = LookupShapeSampler.new(21)
      assert_equal(Array.new(20) { first.sample }, Array.new(20) { second.sample })

      only = LookupShapeSampler.new(3, %w[module-arg])
      Array.new(5) { assert_equal(LookupShape::ModuleArg, only.sample) }
    end

    it "returns Off when the axis is off" do
      sampler = LookupShapeSampler.new(1, [] of String)
      assert(sampler.empty?)
      assert_equal(LookupShape::Off, sampler.sample)
    end
  end

  describe ExpressionShapeSampler do
    it "is deterministic per seed and draws only the requested shapes" do
      first = ExpressionShapeSampler.new(21)
      second = ExpressionShapeSampler.new(21)
      assert_equal(Array.new(20) { first.sample }, Array.new(20) { second.sample })

      only = ExpressionShapeSampler.new(3, %w[statement])
      Array.new(5) { assert_equal(ExpressionShape::Statement, only.sample) }
    end

    it "returns Off when the axis is off" do
      sampler = ExpressionShapeSampler.new(1, [] of String)
      assert(sampler.empty?)
      assert_equal(ExpressionShape::Off, sampler.sample)
    end
  end

  describe PluginDiscoverySampler do
    it "is deterministic per seed and draws only the requested paths" do
      first = PluginDiscoverySampler.new(21)
      second = PluginDiscoverySampler.new(21)
      assert_equal(Array.new(20) { first.sample }, Array.new(20) { second.sample })

      only = PluginDiscoverySampler.new(3, %w[config])
      Array.new(5) { assert_equal(PluginDiscovery::Config, only.sample) }
    end

    it "returns nil when no path was requested" do
      sampler = PluginDiscoverySampler.new(1, [] of String)
      assert(sampler.empty?)
      assert_nil(sampler.sample)
    end
  end
end
