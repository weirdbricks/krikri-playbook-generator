require "random/pcg32"

module KrikriPlaybookGenerator
  # One play-level keyword drawn for a playbook, either written as a play
  # key or exported through the environment variable ansible reads for it.
  # A `nil` setting means the axis is off for that playbook.
  record PlaySetting, keyword : String, value : String, env_key : String? = nil do
    def env? : Bool
      !env_key.nil?
    end

    def source : String
      env? ? "env" : "play"
    end

    # `strategy: free` / `ANSIBLE_STRATEGY=free`.
    def label : String
      env? ? "#{env_key}=#{value}" : "#{keyword}: #{value}"
    end

    # What a repro (or a backend) has to export for this row, empty when
    # the setting is a play key carried by the playbook file itself.
    def env : Hash(String, String)
      key = env_key
      key ? {key => value} : {} of String => String
    end
  end

  # The play-level keyword axis: strategy, serial, throttle,
  # any_errors_fatal, run_once, max_fail_percentage, gather_facts and
  # play-level connection, plus ANSIBLE_FORKS (which has no play-level
  # spelling at all).
  #
  # Exactly ONE keyword is set per playbook. Mixing them would be a
  # different experiment: ansible warns that the free strategy ignores
  # run_once/any_errors_fatal/max_fail_percentage, so a play with several
  # of them mainly tests the warning, not the keyword.
  #
  # The environment variants are separate playbooks, not an extra twist on
  # the same one: `ANSIBLE_STRATEGY=free` and `strategy: free` enter
  # through different code paths, and a fix verified on one can hide a
  # gap in the other (exactly the follow-up class the tracking issue
  # names).
  module PlayKeywords
    # The keyword names `--play-keywords` accepts.
    KINDS = %w[strategy serial throttle any_errors_fatal run_once
      max_fail_percentage gather_facts connection forks]

    # Values a happy path may draw: ansible accepts each one and the
    # playbook stays runnable, so it is still a valid baseline.
    VALUES = {
      "strategy"            => %w[linear free host_pinned debug],
      "serial"              => %w[1 2 50%],
      "throttle"            => %w[1 2],
      "any_errors_fatal"    => %w[true],
      "run_once"            => %w[true],
      "max_fail_percentage" => %w[0 50 100],
      "gather_facts"        => %w[true],
      "connection"          => %w[local],
      "forks"               => %w[1 3],
    }

    # Chaos draws a value ansible must reject (or a strategy/connection
    # name with no plugin behind it), so the delta under test is the
    # engine's validation of the play-level keyword.
    CHAOS_VALUES = {
      "strategy"            => %w[kpg-bogus-strategy],
      "serial"              => %w[kpg-many],
      "throttle"            => %w[kpg-many],
      "any_errors_fatal"    => %w[kpg-maybe],
      "run_once"            => %w[kpg-maybe],
      "max_fail_percentage" => %w[kpg-many],
      "gather_facts"        => %w[kpg-maybe],
      "connection"          => %w[kpg-bogus-connection],
      "forks"               => %w[kpg-many],
    }

    # Keywords whose value can arrive through the environment instead of a
    # play key.
    ENV_KEYS = {
      "strategy" => "ANSIBLE_STRATEGY",
      "forks"    => "ANSIBLE_FORKS",
    }

    ENV_ONLY = %w[forks]

    # `none` turns the axis off; nil for any unknown value so the caller
    # can name the flag.
    def self.parse_list(value : String) : Array(String)?
      values = value.split(',').map(&.strip)
      return [] of String if values == ["none"]
      return if values.empty? || !values.all? { |entry| KINDS.includes?(entry) }

      values.uniq
    end
  end

  # Deterministic per seed: the same seed regenerates the same keyword in
  # the same playbook. It keeps its own RNG so drawing a keyword never
  # shifts the task-argument draws (an argument change would otherwise
  # change which keyword a seed picks, and vice versa).
  class PlaySettingSampler
    # `strategy_values` is the strategy pool; `--strategy-plugins` appends
    # the seeded third-party plugin, whose altered behavior only ansible
    # runs (krikri substitutes linear), so it stays out of the default pool.
    def initialize(@seed : Int32, @kinds : Array(String) = PlayKeywords::KINDS,
                   @strategy_values : Array(String) = PlayKeywords::VALUES["strategy"])
      @rng = Random::PCG32.new(@seed.to_u64)
    end

    def empty? : Bool
      @kinds.empty?
    end

    # nil when the axis is off (`--play-keywords none`).
    def sample(chaos : Bool) : PlaySetting?
      return if @kinds.empty?

      kind = @kinds.sample(@rng)
      pool = chaos ? PlayKeywords::CHAOS_VALUES : PlayKeywords::VALUES
      value = (kind == "strategy" ? @strategy_values : pool[kind]).sample(@rng)
      env_key = PlayKeywords::ENV_KEYS[kind]?
      # An env-capable keyword arrives through the env var half the time;
      # `forks` can only arrive that way.
      if env_key && (PlayKeywords::ENV_ONLY.includes?(kind) || @rng.rand(2) == 0)
        PlaySetting.new(kind, value, env_key)
      else
        PlaySetting.new(kind, value)
      end
    end
  end
end
