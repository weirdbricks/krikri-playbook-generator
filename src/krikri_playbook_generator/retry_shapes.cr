require "random/pcg32"

module KrikriPlaybookGenerator
  # `retries:`/`until:` change when a result becomes usable and how it is
  # reported (the RETRYING lines, the final attempts count, the recap).
  # Each shape is a deterministic task from the retry fixtures:
  #
  # - Retried: a command that succeeds on its third run, so the retry is
  #   really taken and the final result is a success.
  # - Exhausted: a command that never succeeds, so the play reports the
  #   failure shape and the attempts count.
  # - Delegated: the retried command delegated to the second alias, so the
  #   RETRYING lines name `host -> delegate`.
  # - DelegatedFact: a `set_fact` retried with `delegate_to` +
  #   `delegate_facts`, then a probe that reads the fact out of the
  #   delegate's hostvars, so fact placement under delegation is compared.
  enum RetryShape
    Off
    Retried
    Exhausted
    Delegated
    DelegatedFact

    def self.parse(value : String) : RetryShape?
      case value
      when "off"            then Off
      when "retried"        then Retried
      when "exhausted"      then Exhausted
      when "delegated"      then Delegated
      when "delegated-fact" then DelegatedFact
      end
    end

    def label : String
      to_s.downcase
    end
  end

  module RetryShapes
    KINDS = %w[retried exhausted delegated delegated-fact]

    def self.parse_list(value : String) : Array(String)?
      values = value.split(',').map(&.strip)
      return [] of String if values == ["none"]
      return if values.empty? || !values.all? { |entry| KINDS.includes?(entry) }

      values.uniq
    end
  end

  # Deterministic per seed, with its own RNG so drawing a retry shape never
  # shifts the other draws.
  class RetryShapeSampler
    def initialize(@seed : Int32, @kinds : Array(String) = RetryShapes::KINDS)
      @rng = Random::PCG32.new(@seed.to_u64 + 3)
    end

    def empty? : Bool
      @kinds.empty?
    end

    def sample : RetryShape
      return RetryShape::Off if @kinds.empty?

      RetryShape.parse(@kinds.sample(@rng)) || RetryShape::Off
    end
  end
end
