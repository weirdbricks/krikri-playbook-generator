require "random/pcg32"

module KrikriPlaybookGenerator
  # How a generated playbook's handler section behaves. Handlers have their
  # own semantics - ignored-failure reporting, delegation target,
  # notification order - so each shape answers a different question:
  #
  # - Failing: the handler's command exits non-zero, so the play fails at
  #   handler time and the recap's failed count is compared.
  # - Ignoring: the same failure with `ignore_errors: true`, so the
  #   `...ignoring` line and the ignored count are compared.
  # - Delegated: a debug handler delegated to the second alias, so the
  #   `host -> delegate` label and the delegate's context are compared.
  # - Chained: the first handler notifies a second one, so notification
  #   ordering between handlers is compared.
  #
  # A deterministic "Kpg notifier" task (`command: /bin/true` with
  # `changed_when: true`) always notifies the shaped handler, so the
  # handler really runs whatever module the playbook exercises.
  enum HandlerShape
    Off
    Failing
    Ignoring
    Delegated
    Chained

    def self.parse(value : String) : HandlerShape?
      case value
      when "off"       then Off
      when "failing"   then Failing
      when "ignoring"  then Ignoring
      when "delegated" then Delegated
      when "chained"   then Chained
      end
    end

    def label : String
      to_s.downcase
    end
  end

  module HandlerShapes
    # The shapes `--handlers` accepts (`none` turns the axis off).
    KINDS = %w[failing ignoring delegated chained]

    def self.parse_list(value : String) : Array(String)?
      values = value.split(',').map(&.strip)
      return [] of String if values == ["none"]
      return if values.empty? || !values.all? { |entry| KINDS.includes?(entry) }

      values.uniq
    end
  end

  # Deterministic per seed, with its own RNG so drawing a handler shape
  # never shifts the task, keyword or block draws.
  class HandlerShapeSampler
    def initialize(@seed : Int32, @kinds : Array(String) = HandlerShapes::KINDS)
      @rng = Random::PCG32.new(@seed.to_u64 + 2)
    end

    def empty? : Bool
      @kinds.empty?
    end

    def sample : HandlerShape
      return HandlerShape::Off if @kinds.empty?

      HandlerShape.parse(@kinds.sample(@rng)) || HandlerShape::Off
    end
  end
end
