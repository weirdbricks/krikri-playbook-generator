require "./spec_helper"
require "../src/krikri_playbook_generator/block_shapes"

module KrikriPlaybookGenerator
  describe BlockShapes do
    it "parses the shape list and turns `none` into an empty axis" do
      assert_equal(%w[rescue always], BlockShapes.parse_list("rescue,always"))
      assert_equal([] of String, BlockShapes.parse_list("none"))
      assert_nil(BlockShapes.parse_list("rescue,bogus"))
      assert_nil(BlockShapes.parse_list(""))
    end

    it "names every shape the issue asks for" do
      %w[rescue always skipped undefined].each do |kind|
        assert(BlockShapes::KINDS.includes?(kind), "#{kind} missing")
        refute_nil(BlockShape.parse(kind))
      end
      assert_nil(BlockShape.parse("bogus"))
    end
  end

  describe BlockShapeSampler do
    it "is deterministic per seed" do
      first = BlockShapeSampler.new(9)
      second = BlockShapeSampler.new(9)
      assert_equal(Array.new(20) { first.sample }, Array.new(20) { second.sample })
    end

    it "draws only the requested shapes" do
      sampler = BlockShapeSampler.new(4, %w[rescue])
      Array.new(10) { assert_equal(BlockShape::Rescue, sampler.sample) }
    end

    it "returns None when the axis is off" do
      assert_equal(BlockShape::None, BlockShapeSampler.new(1, [] of String).sample)
      assert(BlockShapeSampler.new(1, [] of String).empty?)
    end
  end
end
