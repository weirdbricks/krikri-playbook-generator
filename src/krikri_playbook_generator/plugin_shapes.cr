require "random/pcg32"

module KrikriPlaybookGenerator
  # How a row's plugin files reach the loader: next to the playbook (the
  # playbook-adjacent directory ansible and krikri both search first, which
  # every isolated backend copies along with the playbook), through the
  # ANSIBLE_<TYPE>_PLUGINS environment variable, or through an ansible.cfg
  # reached by ANSIBLE_CONFIG.
  enum PluginDiscovery
    Relative
    Env
    Config

    def label : String
      to_s.downcase
    end

    def self.parse(value : String) : PluginDiscovery?
      case value
      when "relative" then Relative
      when "env"      then Env
      when "config"   then Config
      end
    end
  end

  module PluginShapes
    KINDS = %w[relative env config]

    LOOKUP_KIND   = "lookup"
    FILTER_KIND   = "filter"
    STRATEGY_KIND = "strategy"

    # The fixture strategy plugin's name; a play setting drawn with this
    # value makes the row install and discover the plugin.
    CUSTOM_STRATEGY = "kpg_custom"

    # The loader directory name for each plugin kind.
    DIRS = {
      LOOKUP_KIND   => "lookup_plugins",
      FILTER_KIND   => "filter_plugins",
      STRATEGY_KIND => "strategy_plugins",
    }

    # The environment variable ansible (and krikri) read a plugin type's
    # search path from.
    ENV_KEYS = {
      LOOKUP_KIND   => "ANSIBLE_LOOKUP_PLUGINS",
      FILTER_KIND   => "ANSIBLE_FILTER_PLUGINS",
      STRATEGY_KIND => "ANSIBLE_STRATEGY_PLUGINS",
    }

    # nil for any unknown value so the caller can name the flag.
    def self.parse_list(value : String) : Array(String)?
      values = value.split(',').map(&.strip)
      return if values.empty? || !values.all? { |entry| KINDS.includes?(entry) }

      values.uniq
    end
  end

  # The lookup-plugin axis: the production class that started this work is
  # a custom lookup returning null (or the literal string "undefined")
  # without an error, so every shape drives one plugin through both
  # `debug: var:` and `debug: msg:` and records the result.
  enum LookupShape
    Off
    List
    Query
    None
    Undefined
    Raise
    Vars
    ModuleArg
    SideEffect
    Unknown

    def self.parse(value : String) : LookupShape?
      case value
      when "list"        then List
      when "query"       then Query
      when "none"        then None
      when "undefined"   then Undefined
      when "raise"       then Raise
      when "vars"        then Vars
      when "module-arg"  then ModuleArg
      when "side-effect" then SideEffect
      when "unknown"     then Unknown
      end
    end

    def label : String
      to_s.gsub(/([a-z])([A-Z])/, "\\1-\\2").downcase
    end

    # Shapes whose reference-side run fails by design (a lookup that
    # returns a non-list, raises, or does not exist). Their failure IS the
    # comparison under test, so they stay out of the happy-path quality
    # metric.
    def failing? : Bool
      none? || undefined? || raise? || unknown?
    end
  end

  module LookupShapes
    KINDS = %w[list query none undefined raise vars module-arg side-effect unknown]

    def self.parse_list(value : String) : Array(String)?
      values = value.split(',').map(&.strip)
      return [] of String if values == ["none"]
      return if values.empty? || !values.all? { |entry| KINDS.includes?(entry) }

      values.uniq
    end
  end

  # The filter/expression axis: the shared template engine exercised
  # through values ansible renders differently in `var:` and `msg:` (the
  # production reports: single-backreference `regex_search`, raw `{% %}`
  # blocks, empty renders).
  enum ExpressionShape
    Off
    RegexSearch
    RegexReplace
    Chain
    Positional
    Statement
    EmptyRender
    StarArgs

    def self.parse(value : String) : ExpressionShape?
      case value
      when "regex-search"  then RegexSearch
      when "regex-replace" then RegexReplace
      when "chain"         then Chain
      when "positional"    then Positional
      when "statement"     then Statement
      when "empty-render"  then EmptyRender
      when "star-args"     then StarArgs
      end
    end

    def label : String
      to_s.gsub(/([a-z])([A-Z])/, "\\1-\\2").downcase
    end

    # Shapes that call the seeded `filter_plugins/kpg_filters.py` filters;
    # the others use only builtin filters.
    def custom_filter? : Bool
      positional? || star_args?
    end
  end

  module ExpressionShapes
    KINDS = %w[regex-search regex-replace chain positional statement empty-render star-args]

    def self.parse_list(value : String) : Array(String)?
      values = value.split(',').map(&.strip)
      return [] of String if values == ["none"]
      return if values.empty? || !values.all? { |entry| KINDS.includes?(entry) }

      values.uniq
    end
  end

  # Deterministic per seed, each sampler with its own RNG so drawing one
  # axis never shifts another axis' draws.
  class PluginDiscoverySampler
    def initialize(@seed : Int32, @kinds : Array(String) = PluginShapes::KINDS)
      @rng = Random::PCG32.new(@seed.to_u64 + 5)
    end

    def empty? : Bool
      @kinds.empty?
    end

    def sample : PluginDiscovery?
      return if @kinds.empty?

      PluginDiscovery.parse(@kinds.sample(@rng))
    end
  end

  class LookupShapeSampler
    def initialize(@seed : Int32, @kinds : Array(String) = LookupShapes::KINDS)
      @rng = Random::PCG32.new(@seed.to_u64 + 6)
    end

    def empty? : Bool
      @kinds.empty?
    end

    def sample : LookupShape
      return LookupShape::Off if @kinds.empty?

      LookupShape.parse(@kinds.sample(@rng)) || LookupShape::Off
    end
  end

  class ExpressionShapeSampler
    def initialize(@seed : Int32, @kinds : Array(String) = ExpressionShapes::KINDS)
      @rng = Random::PCG32.new(@seed.to_u64 + 7)
    end

    def empty? : Bool
      @kinds.empty?
    end

    def sample : ExpressionShape
      return ExpressionShape::Off if @kinds.empty?

      ExpressionShape.parse(@kinds.sample(@rng)) || ExpressionShape::Off
    end
  end
end
