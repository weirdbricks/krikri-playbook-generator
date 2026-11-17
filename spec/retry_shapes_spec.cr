require "./spec_helper"
require "../src/krikri_playbook_generator/retry_shapes"

module KrikriPlaybookGenerator
  describe RetryShapes do
    it "parses the shape list and turns `none` into an empty axis" do
      assert_equal(%w[retried delegated-fact], RetryShapes.parse_list("retried,delegated-fact"))
      assert_equal([] of String, RetryShapes.parse_list("none"))
      assert_nil(RetryShapes.parse_list("retried,bogus"))
    end

    it "names every shape the issue asks for" do
      %w[retried exhausted delegated delegated-fact].each do |kind|
        assert(RetryShapes::KINDS.includes?(kind), "#{kind} missing")
        refute_nil(RetryShape.parse(kind))
      end
      assert_nil(RetryShape.parse("bogus"))
    end
  end

  describe RetryShapeSampler do
    it "is deterministic per seed and draws only the requested shapes" do
      first = RetryShapeSampler.new(14)
      second = RetryShapeSampler.new(14)
      assert_equal(Array.new(20) { first.sample }, Array.new(20) { second.sample })

      only = RetryShapeSampler.new(3, %w[exhausted])
      Array.new(5) { assert_equal(RetryShape::Exhausted, only.sample) }
    end

    it "returns Off when the axis is off" do
      assert_equal(RetryShape::Off, RetryShapeSampler.new(1, [] of String).sample)
      assert(RetryShapeSampler.new(1, [] of String).empty?)
    end
  end
end
