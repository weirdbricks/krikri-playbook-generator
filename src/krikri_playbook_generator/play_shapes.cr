require "random/pcg32"

module KrikriPlaybookGenerator
  # How a generated playbook's plays are laid out. Every other axis keeps
  # the scenario inside ONE play, so state that only exists at a play
  # boundary is invisible: handler flush timing, role defaults/vars
  # precedence through a play-level `roles:` entry, and a register
  # variable carried from one play into the next.
  #
  # - Split: the scenario's tasks are partitioned across two plays, the
  #   first ending with `meta: flush_handlers`, so a handler notified
  #   before the boundary runs at the flush and the host-scoped register
  #   chain crosses the boundary.
  # - Role: a play whose `roles:` entry names the seeded fixture role runs
  #   before the task play, exercising play-level role invocation,
  #   role-relative includes and role defaults/vars precedence.
  enum PlayShape
    Off
    Split
    Role

    def self.parse(value : String) : PlayShape?
      case value
      when "off", "none" then Off
      when "split"       then Split
      when "role"        then Role
      end
    end

    def label : String
      to_s.downcase
    end
  end

  module PlayShapes
    # The shapes `--play-shapes` accepts (`none` turns the axis off).
    KINDS = %w[split role]

    def self.parse_list(value : String) : Array(String)?
      values = value.split(',').map(&.strip)
      return [] of String if values == ["none"] || values == ["off"]
      return if values.empty? || !values.all? { |entry| KINDS.includes?(entry) }

      values.uniq
    end
  end

  # Deterministic per seed, with its own RNG so drawing a play shape never
  # shifts the task, keyword, block or handler draws.
  class PlayShapeSampler
    def initialize(@seed : Int32, @kinds : Array(String) = PlayShapes::KINDS)
      @rng = Random::PCG32.new(@seed.to_u64 + 8)
    end

    def empty? : Bool
      @kinds.empty?
    end

    def sample : PlayShape
      return PlayShape::Off if @kinds.empty?

      PlayShape.parse(@kinds.sample(@rng)) || PlayShape::Off
    end
  end
end
