require "./spec_helper"
require "../src/krikri_playbook_generator/handler_shapes"

module KrikriPlaybookGenerator
  describe HandlerShapes do
    it "parses the shape list and turns `none` into an empty axis" do
      assert_equal(%w[failing delegated], HandlerShapes.parse_list("failing,delegated"))
      assert_equal([] of String, HandlerShapes.parse_list("none"))
      assert_nil(HandlerShapes.parse_list("failing,bogus"))
    end

    it "names every shape the issue asks for" do
      %w[failing ignoring delegated chained].each do |kind|
        assert(HandlerShapes::KINDS.includes?(kind), "#{kind} missing")
        refute_nil(HandlerShape.parse(kind))
      end
      assert_nil(HandlerShape.parse("bogus"))
    end
  end

  describe HandlerShapeSampler do
    it "is deterministic per seed and draws only the requested shapes" do
      first = HandlerShapeSampler.new(12)
      second = HandlerShapeSampler.new(12)
      assert_equal(Array.new(20) { first.sample }, Array.new(20) { second.sample })

      only = HandlerShapeSampler.new(3, %w[chained])
      Array.new(5) { assert_equal(HandlerShape::Chained, only.sample) }
    end

    it "returns Off when the axis is off" do
      assert_equal(HandlerShape::Off, HandlerShapeSampler.new(1, [] of String).sample)
      assert(HandlerShapeSampler.new(1, [] of String).empty?)
    end
  end
end
