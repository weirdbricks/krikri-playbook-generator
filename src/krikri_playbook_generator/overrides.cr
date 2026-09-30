require "yaml"

module KrikriPlaybookGenerator
  # Loader for data/module_overrides.yml (embedded at compile time). See
  # the data file's own comment for the value kinds and why each exists.
  #
  # Lookup order: a module's own entry for the option wins; otherwise a
  # `names:` entry applies by option name; otherwise nil (the generator
  # falls back to type/name heuristics).
  class Overrides
    record OptionOverride, kind : String?, choices : Array(String)?, pool : Array(String)?, exclude : Bool

    OVERRIDES_YAML = {{ read_file("#{__DIR__}/data/module_overrides.yml") }}

    def self.load : Overrides
      Overrides.new(OVERRIDES_YAML)
    end

    @modules : Hash(String, Hash(String, OptionOverride))
    @names : Hash(String, OptionOverride)
    @require_one_of : Hash(String, Array(Array(String)))
    @always : Hash(String, Array(String))
    @free_form : Hash(String, Array(String))
    @expect_failure : Hash(String, Bool)

    # Module-level keys are not option overrides; the per-option parser must
    # skip them even when their YAML shape (a map) looks identical. `free_form`
    # is deliberately absent: it is BOTH a module-level key (a pool of bare
    # task bodies) and a real option of shell/script (the raw command), so it
    # is disambiguated by its value - see `module_key?`.
    MODULE_KEYS = %w[always exclude expect_failure require_one_of]

    def initialize(yaml : String)
      parsed = YAML.parse(yaml)
      @modules = parse_module_section(parsed["modules"]?)
      @names = parse_name_section(parsed["names"]?)
      @require_one_of = parse_require_one_of(parsed["modules"]?)
      @always = parse_always(parsed["modules"]?)
      @free_form = parse_pool_by_module(parsed["modules"]?, "free_form")
      @expect_failure = parse_expect_failure(parsed["modules"]?)
    end

    # Module-level happy-path requirement groups from the data file: a
    # group the generator must satisfy even though the module's DOCUMENTATION
    # (and therefore the scanned schema) doesn't encode it - e.g. copy
    # needs src or content at runtime, but neither is `required:` in the
    # arg spec.
    def require_one_of(module_name : String) : Array(Array(String))
      @require_one_of[module_name]? || [] of Array(String)
    end

    def for_option(module_name : String, option_name : String) : OptionOverride?
      @modules[module_name]?.try(&.[option_name]?) || @names[option_name]?
    end

    def excluded?(module_name : String, option_name : String) : Bool
      override = for_option(module_name, option_name)
      override ? override.exclude : false
    end

    private def parse_module_section(section : YAML::Any?) : Hash(String, Hash(String, OptionOverride))
      result = {} of String => Hash(String, OptionOverride)
      section_hash = section.try(&.as_h?)
      return result unless section_hash

      section_hash.each do |module_name, options|
        option_map = {} of String => OptionOverride
        options.as_h?.try do |entries|
          excludes = entries["exclude"]?.try(&.as_a?)
          excludes.try(&.each { |name| option_map[name.as_s] = OptionOverride.new(nil, nil, nil, true) })
          entries.each do |option_name, spec|
            next if module_key?(option_name.to_s, spec)

            option_map[option_name.to_s] = parse_override(spec)
          end
        end
        result[module_name.to_s] = option_map
      end
      result
    end

    private def module_key?(name : String, spec : YAML::Any) : Bool
      return MODULE_KEYS.includes?(name) unless name == "free_form"

      spec.as_h?.try(&.has_key?("pool")) == true
    end

    private def parse_name_section(section : YAML::Any?) : Hash(String, OptionOverride)
      result = {} of String => OptionOverride
      section_hash = section.try(&.as_h?)
      return result unless section_hash

      section_hash.each do |option_name, spec|
        result[option_name.to_s] = parse_override(spec)
      end
      result
    end

    private def parse_require_one_of(section : YAML::Any?) : Hash(String, Array(Array(String)))
      result = {} of String => Array(Array(String))
      section_hash = section.try(&.as_h?)
      return result unless section_hash

      section_hash.each do |module_name, options|
        groups = options.as_h?.try(&.["require_one_of"]?).try(&.as_a?).try do |groups_yaml|
          groups_yaml.compact_map do |group|
            group.as_a?.try(&.map(&.as_s))
          end
        end
        result[module_name.to_s] = groups if groups && !groups.empty?
      end
      result
    end

    # Module-level `always` list: options included in every happy-path
    # task even when not required, because omitting them fails in
    # practice (e.g. `file` without `state` cannot touch an absent path).
    def always(module_name : String) : Array(String)
      @always[module_name]? || [] of String
    end

    private def parse_always(section : YAML::Any?) : Hash(String, Array(String))
      result = {} of String => Array(String)
      section_hash = section.try(&.as_h?)
      return result unless section_hash

      section_hash.each do |module_name, options|
        list = options.as_h?.try(&.["always"]?).try(&.as_a?).try(&.compact_map(&.as_s?))
        result[module_name.to_s] = list if list && !list.empty?
      end
      result
    end

    # Module-level `free_form` pool: the module's action takes a bare string
    # instead of an argument map (e.g. `meta:` needs `noop`, not
    # `free_form: noop`), so the whole task is one of these values. Empty for
    # every module that takes real options.
    def free_form(module_name : String) : Array(String)
      @free_form[module_name]? || [] of String
    end

    # Module-level `expect_failure: true`: the module's whole purpose is to
    # fail (ansible.builtin.fail), so a happy-path failure on real ansible is
    # the expected outcome, not wasted coverage - Triage keeps it out of the
    # quality metric.
    def expect_failure?(module_name : String) : Bool
      @expect_failure[module_name]? || false
    end

    private def parse_pool_by_module(section : YAML::Any?, key : String) : Hash(String, Array(String))
      result = {} of String => Array(String)
      section.try(&.as_h?).try do |section_hash|
        section_hash.each do |module_name, options|
          pool = options.as_h?.try(&.[key]?).try(&.as_h?).try(&.["pool"]?).try(&.as_a?).try(&.compact_map(&.as_s?))
          result[module_name.to_s] = pool if pool && !pool.empty?
        end
      end
      result
    end

    private def parse_expect_failure(section : YAML::Any?) : Hash(String, Bool)
      result = {} of String => Bool
      section.try(&.as_h?).try do |section_hash|
        section_hash.each do |module_name, options|
          flag = options.as_h?.try(&.["expect_failure"]?).try(&.as_bool?)
          result[module_name.to_s] = true if flag
        end
      end
      result
    end

    private def parse_override(spec : YAML::Any) : OptionOverride
      hash = spec.as_h?
      return OptionOverride.new(nil, nil, nil, false) unless hash

      kind = hash["kind"]?.try(&.as_s?)
      choices = hash["choices"]?.try(&.as_a?.try(&.map(&.as_s)))
      pool = hash["pool"]?.try(&.as_a?.try(&.map(&.as_s)))
      exclude = hash["exclude"]?.try(&.as_bool?) || false
      OptionOverride.new(kind, choices, pool, exclude)
    end
  end
end
