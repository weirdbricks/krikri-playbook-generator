require "yaml"
require "./schema"
require "random/pcg32"

module KrikriPlaybookGenerator
  enum ChaosKind
    Typo
    Hallucinate
    WrongType
    BadChoice
    ViolateConstraint
  end

  # One generated task's arguments plus, for chaos-mode tasks, which
  # slots were mutated and how — carried through to triage so a
  # divergence can always be traced back to a specific mutation kind.
  class GeneratedTask
    property module_name : String
    property collection : String
    property args : Hash(String, YAML::Any)
    property mutations : Array({String, ChaosKind})

    def initialize(@module_name, @collection = "ansible.builtin", @args = {} of String => YAML::Any,
                   @mutations = [] of {String, ChaosKind})
    end

    def fqcn : String
      "#{collection}.#{module_name}"
    end

    def chaos? : Bool
      !mutations.empty?
    end
  end

  # Given a module's schema, an RNG seed, and a chaos-percentage, builds
  # random-but-schema-aware argument sets: mostly valid ("happy path"),
  # with each option-slot independently eligible for a chaos mutation at
  # probability `chaos_percentage` (a percent, e.g. 3.0 == 3%).
  #
  # `mutually_exclusive`/`required_together`/`required_one_of` violations
  # (ViolateConstraint) act on a whole constraint group rather than a
  # single option, so they're rolled once per group per task instead of
  # once per option. `required_if` constraints aren't violated yet — their
  # heterogeneous [key, value, [required_keys], bool?] shape doesn't reduce
  # to a plain name group the same way; left as a known gap, not guessed at.
  class Generator
    ALPHABET = ("a".."z").to_a

    def initialize(@seed : Int32, @chaos_percentage : Float64 = 0.0,
                   @chaos_kinds : Array(ChaosKind) = ChaosKind.values)
      @rng = Random::PCG32.new(@seed.to_u64)
    end

    def generate(schema : ModuleSchema, count : Int32) : Array(GeneratedTask)
      Array(GeneratedTask).new(count) { build_task(schema) }
    end

    private def build_task(schema : ModuleSchema) : GeneratedTask
      args = {} of String => YAML::Any
      mutations = [] of {String, ChaosKind}
      per_option_kinds = @chaos_kinds - [ChaosKind::ViolateConstraint]

      schema.options.each_value do |option|
        next unless include_option?(option)

        if !per_option_kinds.empty? && chaos_triggered?
          apply_chaos!(args, mutations, option, per_option_kinds.sample(@rng))
        else
          args[option.name] = happy_value(option)
        end
      end

      apply_constraint_violations!(schema, args, mutations)

      GeneratedTask.new(schema.module_name, schema.collection, args, mutations)
    end

    private def include_option?(option : OptionSchema) : Bool
      option.required? || @rng.rand < 0.5
    end

    private def chaos_triggered? : Bool
      @chaos_percentage > 0 && @rng.rand(100.0) < @chaos_percentage
    end

    private def apply_chaos!(args : Hash(String, YAML::Any), mutations : Array({String, ChaosKind}),
                             option : OptionSchema, kind : ChaosKind) : Nil
      case kind
      when .typo?
        args[typo_name(option.name)] = happy_value(option)
        mutations << {option.name, kind}
      when .hallucinate?
        args["#{option.name}_bogus"] = happy_value(option)
        mutations << {option.name, kind}
      when .wrong_type?
        args[option.name] = wrong_type_value(option)
        mutations << {option.name, kind}
      when .bad_choice?
        if option.choices.empty?
          args[option.name] = happy_value(option)
        else
          args[option.name] = YAML::Any.new(bad_choice_value(option))
          mutations << {option.name, kind}
        end
      else
        args[option.name] = happy_value(option)
      end
    end

    # Rolls ViolateConstraint independently per constraint group (its own
    # "slot"), same probability as a single option-slot's chaos check.
    private def apply_constraint_violations!(schema : ModuleSchema, args : Hash(String, YAML::Any),
                                             mutations : Array({String, ChaosKind})) : Nil
      return unless @chaos_kinds.includes?(ChaosKind::ViolateConstraint)
      return unless @chaos_percentage > 0

      schema.mutually_exclusive.each do |group|
        next unless chaos_triggered?
        group.each do |name|
          option = schema.options[name]?
          args[name] = happy_value(option) if option
        end
        mutations << {group.join(","), ChaosKind::ViolateConstraint}
      end

      schema.required_together.each do |group|
        next unless group.size >= 2 && chaos_triggered?
        first = group.first
        option = schema.options[first]?
        args[first] = happy_value(option) if option
        group[1..].each { |name| args.delete(name) }
        mutations << {group.join(","), ChaosKind::ViolateConstraint}
      end

      schema.required_one_of.each do |group|
        next unless chaos_triggered?
        group.each { |name| args.delete(name) }
        mutations << {group.join(","), ChaosKind::ViolateConstraint}
      end
    end

    private def happy_value(option : OptionSchema?) : YAML::Any
      return YAML::Any.new(nil) unless option
      return YAML::Any.new(option.choices.sample(@rng)) unless option.choices.empty?

      happy_scalar(option.type, option.elements)
    end

    private def happy_scalar(type : String, elements : String? = nil) : YAML::Any
      case type
      when "bool"
        YAML::Any.new(@rng.rand < 0.5)
      when "int"
        YAML::Any.new(@rng.rand(1..1000).to_i64)
      when "float"
        YAML::Any.new(@rng.rand(1.0..1000.0))
      when "list"
        element_type = elements || "str"
        size = @rng.rand(1..3)
        YAML::Any.new(Array.new(size) { happy_scalar(element_type) })
      when "dict"
        YAML::Any.new({} of YAML::Any => YAML::Any)
      when "path"
        YAML::Any.new("/tmp/kpg-#{random_word}")
      else
        YAML::Any.new(random_word)
      end
    end

    private def wrong_type_value(option : OptionSchema) : YAML::Any
      case option.type
      when "list", "dict"
        YAML::Any.new(random_word)
      when "bool", "int", "float"
        YAML::Any.new(random_word)
      else
        YAML::Any.new(@rng.rand(1..1000).to_i64)
      end
    end

    private def bad_choice_value(option : OptionSchema) : String
      candidate = "#{option.choices.sample(@rng)}_x"
      while option.choices.includes?(candidate)
        candidate = "#{candidate}_x"
      end
      candidate
    end

    private def typo_name(name : String) : String
      return "#{name}x" if name.size < 2

      idx = @rng.rand(name.size - 1)
      chars = name.chars
      chars[idx], chars[idx + 1] = chars[idx + 1], chars[idx]
      chars.join
    end

    private def random_word(length : Int32 = 6) : String
      String.build { |str| length.times { str << ALPHABET.sample(@rng) } }
    end
  end
end
