require "./spec_helper"
require "../src/krikri_playbook_generator/play_shapes"

module KrikriPlaybookGenerator
  describe PlayShape do
    it "parses and labels the shapes" do
      assert_equal(PlayShape::Off, PlayShape.parse("none"))
      assert_equal(PlayShape::Off, PlayShape.parse("off"))
      assert_equal(PlayShape::Split, PlayShape.parse("split"))
      assert_equal(PlayShape::Role, PlayShape.parse("role"))
      assert_nil(PlayShape.parse("bogus"))
      assert_equal("split", PlayShape::Split.label)
    end
  end

  describe PlayShapes do
    it "parses a comma-separated list and `none`" do
      assert_equal(%w[split role], PlayShapes.parse_list("split,role"))
      assert_equal([] of String, PlayShapes.parse_list("none"))
      assert_nil(PlayShapes.parse_list("split,bogus"))
    end
  end

  describe PlayShapeSampler do
    it "is deterministic per seed and only samples enabled shapes" do
      sampler = PlayShapeSampler.new(42, ["split"])
      5.times { assert_equal(PlayShape::Split, sampler.sample) }
      assert_equal(PlayShape::Off, PlayShapeSampler.new(42, [] of String).sample)
      assert_equal(PlayShapeSampler.new(42, ["role"]).sample,
        PlayShapeSampler.new(42, ["role"]).sample)
    end
  end
end
