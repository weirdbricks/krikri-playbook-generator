require "random/pcg32"

module KrikriPlaybookGenerator
  # A block shape wraps the generated task in `block:`/`rescue:`/`always:`
  # so ansible's error-handling and cleanup paths are compared: whether a
  # rescue swallows the failure, whether always runs after it, what the
  # recap counts, and whether a skipped or undefined block-level condition
  # runs anything at all. The single generated module call stays the
  # baseline; the surrounding structure is what the shape adds.
  enum BlockShape
    None
    Rescue
    Always
    Skipped
    Undefined

    def self.parse(value : String) : BlockShape?
      case value
      when "none"      then None
      when "rescue"    then Rescue
      when "always"    then Always
      when "skipped"   then Skipped
      when "undefined" then Undefined
      end
    end

    def label : String
      to_s.downcase
    end
  end

  module BlockShapes
    # The shapes `--blocks` accepts (`none` turns the axis off).
    KINDS = %w[rescue always skipped undefined]

    def self.parse_list(value : String) : Array(String)?
      values = value.split(',').map(&.strip)
      return [] of String if values == ["none"]
      return if values.empty? || !values.all? { |entry| KINDS.includes?(entry) }

      values.uniq
    end
  end

  # Deterministic per seed, with its own RNG so drawing a block shape never
  # shifts the task-argument or play-keyword draws.
  class BlockShapeSampler
    def initialize(@seed : Int32, @kinds : Array(String) = BlockShapes::KINDS)
      @rng = Random::PCG32.new(@seed.to_u64 + 1)
    end

    def empty? : Bool
      @kinds.empty?
    end

    def sample : BlockShape
      return BlockShape::None if @kinds.empty?

      BlockShape.parse(@kinds.sample(@rng)) || BlockShape::None
    end
  end
end
