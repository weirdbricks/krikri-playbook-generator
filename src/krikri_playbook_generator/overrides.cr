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
    @environment : Hash(String, Hash(String, String))
    @expect_failure : Hash(String, Bool)
    @not_applicable : Hash(String, Bool)
    @profiles : Hash(String, Array(String))
    @module_utils_skip : Hash(String, String)

    # Module-level keys are not option overrides; the per-option parser must
    # skip them even when their YAML shape (a map) looks identical. `free_form`
    # is deliberately absent: it is BOTH a module-level key (a pool of bare
    # task bodies) and a real option of shell/script (the raw command), so it
    # is disambiguated by its value - see `module_key?`.
    MODULE_KEYS = %w[always exclude expect_failure not_applicable require_one_of profiles environment]

    def initialize(yaml : String)
      parsed = YAML.parse(yaml)
      @modules = parse_module_section(parsed["modules"]?)
      @names = parse_name_section(parsed["names"]?)
      @require_one_of = parse_require_one_of(parsed["modules"]?)
      @always = parse_always(parsed["modules"]?)
      @free_form = parse_pool_by_module(parsed["modules"]?, "free_form")
      @environment = parse_environment(parsed["modules"]?)
      @expect_failure = parse_flag_by_module(parsed["modules"]?, "expect_failure")
      @not_applicable = parse_flag_by_module(parsed["modules"]?, "not_applicable")
      @profiles = parse_list_by_module(parsed["modules"]?, "profiles")
      @module_utils_skip = parse_module_utils_skip(parsed["module_utils_skip"]?)
    end

    # Module-level happy-path requirement groups from the data file: a
    # group the generator must satisfy even though the module's DOCUMENTATION
    # (and therefore the scanned schema) doesn't encode it - e.g. copy
    # needs src or content at runtime, but neither is `required:` in the
    # arg spec.
    def require_one_of(module_name : String) : Array(Array(String))
      @require_one_of[module_name]? || [] of Array(String)
    end

    # Module-level `environment:` map: variables every happy-path task of
    # this module exports (`get_url`/`uri` need a proxy-shaped environment
    # to exercise the module's use of it, for example). A task body key,
    # never an option override.
    def environment(module_name : String) : Hash(String, String)
      @environment[module_name]? || {} of String => String
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

    # Module-level `not_applicable: true`: the module cannot be exercised by
    # a single-task, local-connection playbook at all (reboot would reboot
    # the control node; apt_key's apt-key tooling no longer ships in the
    # reference image), so its happy-path failures are neither a generator
    # bug nor wasted coverage to chase. Triage keeps it out of both the
    # quality and happy-coverage metrics - visibly, never silently.
    def not_applicable?(module_name : String) : Bool
      @not_applicable[module_name]? || false
    end

    # Module-level `profiles: [debian, rocky]`: a module that is deliberately
    # exercised on more than one host image (its happy path runs on both).
    # Absent means the module's default profile only.
    def profiles(module_name : String) : Array(String)
      @profiles[module_name.split(".").last]? || [] of String
    end

    # Top-level `module_utils_skip:` entries: an `ansible.module_utils`
    # import path the module_utils probe axis must leave alone, with the
    # reason (usually an optional third-party library the reference image
    # does not install). nil when the path is not skipped.
    def module_utils_skip_reason(name : String) : String?
      @module_utils_skip[name]?
    end

    private def parse_module_utils_skip(section : YAML::Any?) : Hash(String, String)
      result = {} of String => String
      section.try(&.as_h?).try do |entries|
        entries.each do |name, reason|
          text = reason.as_s?
          result[name.to_s] = text if text
        end
      end
      result
    end

    # A module-level bare list (`profiles: [debian, rocky]`), unlike the
    # option overrides' `{pool: [...]}` shape.
    private def parse_environment(section : YAML::Any?) : Hash(String, Hash(String, String))
      result = {} of String => Hash(String, String)
      section.try(&.as_h?).try do |section_hash|
        section_hash.each do |module_name, options|
          env = options.as_h?.try(&.["environment"]?).try(&.as_h?).try do |entries|
            entries.each_with_object({} of String => String) do |(name, value), hash|
              text = value.as_s?
              hash[name.to_s] = text if text
            end
          end
          result[module_name.to_s] = env if env && !env.empty?
        end
      end
      result
    end

    private def parse_list_by_module(section : YAML::Any?, key : String) : Hash(String, Array(String))
      result = {} of String => Array(String)
      section.try(&.as_h?).try do |section_hash|
        section_hash.each do |module_name, options|
          list = options.as_h?.try(&.[key]?).try(&.as_a?).try(&.compact_map(&.as_s?))
          next if module_name.to_s == key
          result[module_name.to_s] = list if list && !list.empty?
        end
      end
      result
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

    private def parse_flag_by_module(section : YAML::Any?, key : String) : Hash(String, Bool)
      result = {} of String => Bool
      section.try(&.as_h?).try do |section_hash|
        section_hash.each do |module_name, options|
          flag = options.as_h?.try(&.[key]?).try(&.as_bool?)
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
