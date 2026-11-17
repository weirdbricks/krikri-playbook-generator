require "./spec_helper"
require "../src/krikri_playbook_generator/include_shapes"

module KrikriPlaybookGenerator
  describe IncludeShapes do
    it "parses the shape list and turns `none` into an empty axis" do
      assert_equal(%w[relative import-playbook], IncludeShapes.parse_list("relative,import-playbook"))
      assert_equal([] of String, IncludeShapes.parse_list("none"))
      assert_nil(IncludeShapes.parse_list("relative,bogus"))
    end

    it "names every form the issue asks for" do
      %w[relative role-vars role-inner loop-tasks loop-role import-playbook
        import-role].each do |kind|
        assert(IncludeShapes::KINDS.includes?(kind), "#{kind} missing")
        refute_nil(IncludeShape.parse(kind))
      end
      assert_nil(IncludeShape.parse("bogus"))
    end
  end

  describe IncludeShapeSampler do
    it "is deterministic per seed and draws only the requested shapes" do
      first = IncludeShapeSampler.new(15)
      second = IncludeShapeSampler.new(15)
      assert_equal(Array.new(20) { first.sample }, Array.new(20) { second.sample })

      only = IncludeShapeSampler.new(3, %w[loop-tasks])
      Array.new(5) { assert_equal(IncludeShape::LoopTasks, only.sample) }
    end

    it "returns Off when the axis is off" do
      assert_equal(IncludeShape::Off, IncludeShapeSampler.new(1, [] of String).sample)
      assert(IncludeShapeSampler.new(1, [] of String).empty?)
    end
  end
end
