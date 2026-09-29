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

    def initialize(yaml : String)
      parsed = YAML.parse(yaml)
      @modules = parse_module_section(parsed["modules"]?)
      @names = parse_name_section(parsed["names"]?)
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
            next if option_name == "exclude"

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
