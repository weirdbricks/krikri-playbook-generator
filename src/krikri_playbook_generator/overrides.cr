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

    def initialize(yaml : String)
      parsed = YAML.parse(yaml)
      @modules = parse_module_section(parsed["modules"]?)
      @names = parse_name_section(parsed["names"]?)
      @require_one_of = parse_require_one_of(parsed["modules"]?)
      @always = parse_always(parsed["modules"]?)
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
            next if option_name.to_s == "exclude" || option_name.to_s == "require_one_of"

            option_map[option_name.to_s] = parse_override(spec)
          end
        end
        result[module_name.to_s] = option_map
      end
      result
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
