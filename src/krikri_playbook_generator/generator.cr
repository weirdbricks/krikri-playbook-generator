require "yaml"
require "./schema"
require "./fixtures"
require "./overrides"
require "random/pcg32"

module KrikriPlaybookGenerator
  # The handler a scenario task may notify. Every name a generated playbook
  # carries (play, task, handler) starts with an uppercase letter because
  # ansible-lint's name[casing] rule requires it, and the playbooks are meant
  # to be lint-clean so a lint run only ever reports krikri's own behaviour.
  HANDLER_NAME = "Kpg handler"

  enum ChaosKind
    Typo
    Hallucinate
    WrongType
    BadChoice
    ViolateConstraint
    Jinja
  end

  # One generated task's arguments plus, for chaos-mode tasks, which
  # slots were mutated and how — carried through to triage so a
  # divergence can always be traced back to a specific mutation kind.
  class GeneratedTask
    property module_name : String
    property collection : String
    property args : Hash(String, YAML::Any)
    property mutations : Array({String, ChaosKind})
    # Set for the handful of actions whose task body is a bare string rather
    # than an argument map (`meta: noop`), in which case `args` is empty.
    property free_form : String?
    # v2 multi-task wiring (nil for the single-task playbook shape):
    # a `when:` condition referencing the previous task's register, a
    # `loop:` (with `loop_option` naming the argument replaced by
    # `{{ item }}`), and a `notify:` target in the play's handlers.
    property when_condition : String?
    property loop_option : String?
    property loop_items : Array(String)?
    property notify : String?

    def initialize(@module_name, @collection = "ansible.builtin", @args = {} of String => YAML::Any,
                   @mutations = [] of {String, ChaosKind}, @free_form = nil,
                   @when_condition = nil, @loop_option = nil, @loop_items = nil, @notify = nil)
    end

    def fqcn : String
      "#{collection}.#{module_name}"
    end

    def chaos? : Bool
      !mutations.empty?
    end
  end

  # Given a module's schema, an RNG seed, and a chaos-percentage, builds
  # argument sets that are runnable first and mutated second:
  #
  # - happy path: a VALID baseline - schema-valid *and* runnable inside
  #   the podman containers. Path-typed options point at pre-seeded
  #   fixture files (Fixtures), mode/owner/group/validate come from the
  #   per-module override table (data/module_overrides.yml), choices are
  #   respected, ints stay in sane ranges, and the baseline satisfies
  #   mutually_exclusive/required_together/required_one_of/required_if
  #   rather than violating them.
  # - chaos: an INDEPENDENT mutation of that valid baseline per
  #   option-slot at probability `chaos_percentage` (a percent, e.g. 3.0
  #   == 3%) - never a fresh random value, so a divergence can always be
  #   attributed to the delta from a task that was runnable as-is.
  #
  # `ViolateConstraint` acts on a whole constraint group rather than a
  # single option (it inherently spans several), rolled once per group
  # per task. A `required_if` entry is violated by forcing its condition
  # to the demanded value and dropping every key it demands (for the
  # `any`-mode fourth element, every demanded key except at most one,
  # which keeps the task valid unless all are dropped), so the task
  # reaches argument validation with exactly the missing-key shape the
  # constraint exists to reject.
  #
  # `Jinja` is the one "chaos" kind whose value is still semantically
  # valid: it rewrites an option's value as a Jinja expression that
  # evaluates to that same value (`0644` -> `{{ '0644' }}`), so the delta
  # under test is the ENGINE's templating (where krikri historically
  # diverges), not the module's argument validation. It is recorded in
  # `GeneratedTask#mutations` like every other kind, which is why it is a
  # chaos kind rather than a silent happy-path variation.
  #
  # Deterministic per seed (`Random::PCG32`); every mutation is recorded
  # in `GeneratedTask#mutations`, never applied silently.
  class Generator
    ALPHABET = ("a".."z").to_a
    MODES    = ["0644", "0755", "0600", "0750"]

    def initialize(@seed : Int32, @chaos_percentage : Float64 = 0.0,
                   @chaos_kinds : Array(ChaosKind) = ChaosKind.values,
                   @overrides : Overrides = Overrides.load)
      @rng = Random::PCG32.new(@seed.to_u64)
    end

    def generate(schema : ModuleSchema, count : Int32) : Array(GeneratedTask)
      Array(GeneratedTask).new(count) { build_task(schema) }
    end

    # v2 multi-task scenarios: `count` playbooks of `per_playbook` tasks
    # each, every task from a DIFFERENT module (sampled without
    # replacement from the scanned pool), then wired into an interaction
    # chain - every task registers `kpg_task_<i>`, tasks after the first
    # run under a `when:` on the previous task's register, one task whose
    # args carry a fixture source path iterates that path over the
    # fixture source list with `loop:`, and tasks may `notify:` a
    # play-level handler. Wiring is structural (recorded in the sidecar
    # as wiring, never as a chaos mutation); chaos is still applied per
    # task exactly as in the single-task shape.
    def generate_scenarios(schemas : Array(ModuleSchema), per_playbook : Int32,
                           count : Int32) : Array(Array(GeneratedTask))
      raise ArgumentError.new("multi-task scenarios need per_playbook >= 2, got #{per_playbook}") if per_playbook < 2
      raise ArgumentError.new("multi-task scenarios need at least 2 scanned modules, got #{schemas.size}") if schemas.size < 2

      per = Math.min(per_playbook, schemas.size)
      Array(Array(GeneratedTask)).new(count) do
        tasks = schemas.sample(per, @rng).map { |schema| build_task(schema) }
        wire_scenario!(tasks)
        tasks
      end
    end

    private def wire_scenario!(tasks : Array(GeneratedTask)) : Nil
      tasks.each_with_index do |task, index|
        if index > 0
          previous = "kpg_task_#{index - 1}"
          task.when_condition = ["#{previous} is succeeded", "#{previous} is not skipped"].sample(@rng)
        end
        apply_loop_wiring!(task)
        task.notify = HANDLER_NAME if @rng.rand < 0.4
      end
    end

    # A task whose baseline args point at one of the read-only fixture
    # source files gets that argument templated as `{{ item }}` and a
    # `loop:` over the whole fixture source list - the loop interaction
    # (per-item templating of one slot) without inventing new values.
    private def apply_loop_wiring!(task : GeneratedTask) : Nil
      return if task.free_form

      hit = task.args.find do |_, value|
        raw = value.raw
        raw.is_a?(String) && Fixtures::SOURCE_FILES.includes?(raw)
      end
      return unless hit

      name, _ = hit
      task.args[name] = YAML::Any.new("{{ item }}")
      task.loop_option = name
      task.loop_items = Fixtures::SOURCE_FILES.dup
    end

    private def build_task(schema : ModuleSchema) : GeneratedTask
      return free_form_task(schema) unless @overrides.free_form(schema.module_name).empty?

      args = happy_baseline(schema)
      mutations = [] of {String, ChaosKind}
      apply_chaos!(schema, args, mutations)
      GeneratedTask.new(schema.module_name, schema.collection, args, mutations)
    end

    # Actions like `meta` take a bare string, not an argument map, so the
    # whole task is generated at once from the module's free-form pool -
    # valid action first, then (in chaos mode) an invalid one, which is the
    # only meaningful mutation a free-form body has.
    private def free_form_task(schema : ModuleSchema) : GeneratedTask
      value = @overrides.free_form(schema.module_name).sample(@rng)
      mutations = [] of {String, ChaosKind}
      if chaos_triggered?
        value = "#{value}_bogus"
        mutations << {"free_form", ChaosKind::BadChoice}
      end

      GeneratedTask.new(schema.module_name, schema.collection, {} of String => YAML::Any, mutations, value)
    end

    # The valid baseline: included options get runnable happy-path values,
    # then cross-option constraints are satisfied so the task passes
    # ansible's argument validation and reaches the module logic.
    private def happy_baseline(schema : ModuleSchema) : Hash(String, YAML::Any)
      args = {} of String => YAML::Any

      schema.options.each_value do |option|
        next if @overrides.excluded?(schema.module_name, option.name)
        next unless option.required? || @overrides.always(schema.module_name).includes?(option.name) ||
                    @rng.rand < 0.5

        args[option.name] = happy_value(schema, option)
      end

      satisfy_constraints!(schema, args)
      args
    end

    private def chaos_triggered? : Bool
      @chaos_percentage > 0 && @rng.rand(100.0) < @chaos_percentage
    end

    private def apply_chaos!(schema : ModuleSchema, args : Hash(String, YAML::Any),
                             mutations : Array({String, ChaosKind})) : Nil
      per_option_kinds = @chaos_kinds - [ChaosKind::ViolateConstraint]
      if per_option_kinds.empty? == false && @chaos_percentage > 0
        schema.options.each_value do |option|
          next unless args.has_key?(option.name)
          next unless chaos_triggered?

          mutate_option!(schema, args, mutations, option, per_option_kinds.sample(@rng))
        end
      end

      apply_constraint_violations!(schema, args, mutations)
    end

    # Every mutation is a delta on top of the valid baseline value that's
    # already in `args` - a wrong-type value replaces a runnable one, a
    # bad choice replaces an in-schema one, etc.
    private def mutate_option!(schema : ModuleSchema, args : Hash(String, YAML::Any),
                               mutations : Array({String, ChaosKind}),
                               option : OptionSchema, kind : ChaosKind) : Nil
      case kind
      when .typo?
        renamed = typo_name(option.name, schema.options.keys)
        args[renamed] = args[option.name]
        args.delete(option.name)
        mutations << {option.name, kind}
      when .hallucinate?
        args["#{option.name}_bogus"] = args[option.name]
        mutations << {option.name, kind}
      when .wrong_type?
        args[option.name] = wrong_type_value(option)
        mutations << {option.name, kind}
      when .bad_choice?
        if option.choices.empty?
          args[option.name] = happy_value(schema, option)
        else
          args[option.name] = YAML::Any.new(bad_choice_value(option))
          mutations << {option.name, kind}
        end
      when .jinja?
        if wrapped = jinja_wrap(args[option.name])
          args[option.name] = wrapped
          mutations << {option.name, kind}
        end
      else
        args[option.name] = happy_value(schema, option)
      end
    end

    # Rewrites a valid value as a Jinja expression that evaluates back to
    # it: `0644` -> `{{ '0644' }}`, `true` -> `{{ true }}`, `[a, b]` ->
    # `{{ ['a', 'b'] }}`. Only the representation changes, so a divergence
    # here is engine templating, not module validation. A value that
    # cannot be expressed (nil, an empty dict) returns nil and is left
    # unchanged, so the mutation is never recorded for a no-op.
    private def jinja_wrap(value : YAML::Any) : YAML::Any?
      literal = jinja_literal(value)
      literal ? YAML::Any.new("{{ #{literal} }}") : nil
    end

    private def jinja_literal(value : YAML::Any) : String?
      case raw = value.raw
      when String
        "'#{raw.gsub('\\', "\\\\").gsub('\'', "\\'")}'"
      when Bool
        raw ? "true" : "false"
      when Int, Float
        raw.to_s
      when Array
        elements = [] of String
        raw.each do |element|
          element_literal = jinja_literal(element)
          return unless element_literal

          elements << element_literal
        end
        "[#{elements.join(", ")}]"
      when Hash
        return if raw.empty?

        pairs = [] of String
        raw.each do |key, element|
          key_literal = jinja_literal(key)
          value_literal = jinja_literal(element)
          return unless key_literal && value_literal

          pairs << "#{key_literal}: #{value_literal}"
        end
        "{#{pairs.join(", ")}}"
      else
        # a value kind with no template-literal form (nil, time, ...)
      end
    end

    # Rolls ViolateConstraint independently per constraint group (its own
    # "slot"), same probability as a single option-slot's chaos check.
    private def apply_constraint_violations!(schema : ModuleSchema, args : Hash(String, YAML::Any),
                                             mutations : Array({String, ChaosKind})) : Nil
      return unless @chaos_kinds.includes?(ChaosKind::ViolateConstraint)

      schema.mutually_exclusive.each do |group|
        next unless chaos_triggered?
        next unless group.any? { |name| args.has_key?(name) || schema.options[name]? }

        group.each do |name|
          option = schema.options[name]?
          args[name] = happy_value(schema, option) if option
        end
        mutations << {group.join(","), ChaosKind::ViolateConstraint}
      end
      violate_required_groups!(schema, args, mutations)
    end

    private def violate_required_groups!(schema : ModuleSchema, args : Hash(String, YAML::Any),
                                         mutations : Array({String, ChaosKind})) : Nil
      schema.required_together.each do |group|
        next unless group.size >= 2 && chaos_triggered?
        next unless group.any? { |name| args.has_key?(name) }

        first = group.first
        option = schema.options[first]?
        args[first] = happy_value(schema, option) if option
        group[1..].each { |name| args.delete(name) }
        mutations << {group.join(","), ChaosKind::ViolateConstraint}
      end

      schema.required_one_of.each do |group|
        next unless chaos_triggered?
        next unless group.any? { |name| args.has_key?(name) }

        group.each { |name| args.delete(name) }
        mutations << {group.join(","), ChaosKind::ViolateConstraint}
      end

      schema.required_if.each do |entry|
        next unless chaos_triggered?

        violate_required_if!(schema, args, entry) do |label|
          mutations << {label, ChaosKind::ViolateConstraint}
        end
      end
    end

    # Forces a `required_if` entry's condition to its demanded value
    # and drops the keys it demands, leaving the task invalid in exactly
    # the way the constraint exists to catch. In `any` mode (fourth
    # element `true`) keeping one demanded key would keep the task
    # valid, so all of them are dropped. Skips the entry unless the
    # condition can be set without tripping an unrelated validation:
    # its value must exist in the schema (or as a choice of the
    # condition option, so a bad choice isn't also introduced) and
    # every demanded key must be deletable (not a required option or
    # already excluded). Yields the mutation label only on success.
    private def violate_required_if!(schema : ModuleSchema, args : Hash(String, YAML::Any),
                                     entry : JSON::Any, &) : Nil
      entry_list = entry.as_a?
      return unless entry_list && entry_list.size >= 3

      condition = entry_list[0].as_s?
      return unless condition
      return unless schema.options[condition]?

      required_keys = entry_list[2].as_a?.try(&.compact_map(&.as_s?)) || [] of String
      return if required_keys.empty?
      return unless required_keys.all? { |name| schema.options[name]? && args.has_key?(name) }
      return if required_keys.any? do |name|
                  option = schema.options[name]?
                  (option && option.required?) || @overrides.excluded?(schema.module_name, name)
                end

      demanded = entry_list[1]
      args[condition] = required_if_value(schema, condition, demanded)
      required_keys.each { |name| args.delete(name) }
      yield "required_if:#{condition}"
    end

    # The exact demanded value (bool/string/int/float), or - when the
    # entry's value is a type argument validation can't match by
    # equality (a list, a dict) - the condition option's first choice,
    # which is the only kind of value an entry realistically demands.
    # Never a random value: the delta must be the dropped keys, not a
    # changed condition.
    private def required_if_value(schema : ModuleSchema, condition : String,
                                  demanded : JSON::Any) : YAML::Any
      case raw = demanded.raw
      when String then YAML::Any.new(raw)
      when Bool   then YAML::Any.new(raw)
      when Int    then YAML::Any.new(raw.to_i64)
      when Float  then YAML::Any.new(raw)
      when Nil    then YAML::Any.new(nil)
      else
        option = schema.options[condition]?
        if option && !option.choices.empty?
          YAML::Any.new(option.choices.first)
        else
          json_to_yaml(demanded)
        end
      end
    end

    private def json_to_yaml(value : JSON::Any) : YAML::Any
      case raw = value.raw
      when Array
        YAML::Any.new(raw.map { |element| json_to_yaml(element) })
      when Hash
        hash = {} of YAML::Any => YAML::Any
        raw.each { |key, element| hash[YAML::Any.new(key)] = json_to_yaml(element) }
        YAML::Any.new(hash)
      when String then YAML::Any.new(raw)
      when Bool   then YAML::Any.new(raw)
      when Int    then YAML::Any.new(raw.to_i64)
      when Float  then YAML::Any.new(raw)
      else
        YAML::Any.new(nil)
      end
    end

    # Satisfies the cross-option constraints on the baseline: keeps only
    # one member of each mutually_exclusive group, fills in the rest of
    # any touched required_together group, populates a required_one_of
    # group if none of its members made it in, and adds keys required_if
    # demands for the condition values that are actually present.
    #
    # Ansible validates mutually_exclusive LAST (after the required_*
    # checks), so a fill must never introduce a second member of an
    # exclusive group - `addable?` plus the final pass enforce that.
    private def satisfy_constraints!(schema : ModuleSchema, args : Hash(String, YAML::Any)) : Nil
      keep_first_of_mutually_exclusive(schema, args)
      fill_required_together(schema, args)
      fill_required_one_of(schema, args)
      fill_required_if(schema, args)
      keep_first_of_mutually_exclusive(schema, args)
    end

    private def keep_first_of_mutually_exclusive(schema : ModuleSchema, args : Hash(String, YAML::Any)) : Nil
      schema.mutually_exclusive.each do |group|
        present = group.select { |name| args.has_key?(name) }
        next unless present.size > 1

        # A required member must survive the cut, or the task fails
        # argument validation for a different reason than the one under test.
        keeper = present.find do |name|
          option = schema.options[name]?
          option && option.required?
        end || present.first
        present.each { |name| args.delete(name) unless name == keeper }
      end
    end

    private def fill_required_together(schema : ModuleSchema, args : Hash(String, YAML::Any)) : Nil
      schema.required_together.each do |group|
        next unless group.any? { |name| args.has_key?(name) }

        add_all(schema, args, group)
      end
    end

    private def fill_required_one_of(schema : ModuleSchema, args : Hash(String, YAML::Any)) : Nil
      groups = schema.required_one_of + @overrides.require_one_of(schema.module_name)
      groups.each do |group|
        next if group.any? { |name| args.has_key?(name) }

        name = group.find { |candidate| addable?(schema, args, candidate) }
        next unless name

        args[name] = happy_value(schema, schema.options[name])
      end
    end

    private def fill_required_if(schema : ModuleSchema, args : Hash(String, YAML::Any)) : Nil
      schema.required_if.each do |entry|
        entry_list = entry.as_a?
        next unless entry_list && entry_list.size >= 3

        condition = entry_list[0].as_s?
        next unless condition
        next unless args.has_key?(condition) && value_matches?(args[condition], entry_list[1])

        required_keys = entry_list[2].as_a?.try(&.compact_map(&.as_s?)) || [] of String
        require_any = entry_list[3]?.try(&.as_bool?) || false
        required_keys.each do |name|
          next if args.has_key?(name) || !addable?(schema, args, name)

          args[name] = happy_value(schema, schema.options[name])
          break if require_any
        end
      end
    end

    private def add_all(schema : ModuleSchema, args : Hash(String, YAML::Any), names : Array(String)) : Nil
      names.each do |name|
        option = schema.options[name]?
        next if !option || args.has_key?(name) || !addable?(schema, args, name)

        args[name] = happy_value(schema, option)
      end
    end

    private def addable?(schema : ModuleSchema, args : Hash(String, YAML::Any), name : String) : Bool
      return false unless schema.options[name]?
      return false if @overrides.excluded?(schema.module_name, name)

      !exclusive_conflict?(schema, args, name)
    end

    # True when adding `name` would put a second member of the same
    # mutually_exclusive group into `args`.
    private def exclusive_conflict?(schema : ModuleSchema, args : Hash(String, YAML::Any), name : String) : Bool
      schema.mutually_exclusive.any? do |group|
        group.includes?(name) && group.any? { |member| member != name && args.has_key?(member) }
      end
    end

    private def value_matches?(yaml_value : YAML::Any, json_value : JSON::Any) : Bool
      if json_value.as_s?
        return yaml_value.raw.is_a?(String) && yaml_value.as_s == json_value.as_s
      end
      if bool_value = json_value.as_bool?
        return yaml_value.raw.is_a?(Bool) && yaml_value.as_bool == bool_value
      end
      false
    end

    private def happy_value(schema : ModuleSchema, option : OptionSchema?) : YAML::Any
      return YAML::Any.new(nil) unless option

      if override = @overrides.for_option(schema.module_name, option.name)
        value = override_value(override)
        return value if value
        if (choices = override.choices) && !choices.empty?
          return YAML::Any.new(choices.sample(@rng))
        end
      end

      return YAML::Any.new(option.choices.sample(@rng)) unless option.choices.empty?

      happy_scalar(schema.module_name, option)
    end

    private def override_value(override : Overrides::OptionOverride) : YAML::Any?
      case override.kind
      when "mode", "owner", "group", "validate"
        simple_override_value(override)
      when "source_path", "work_path", "work_dir", "username", "literal_pool"
        pool_override_value(override)
      when "empty_dict"
        # For options the DOCUMENTATION leaves untyped but the module
        # validates as a dict (validate_argument_spec's argument_spec):
        # a random word there is a type error, an empty dict is valid.
        YAML::Any.new({} of YAML::Any => YAML::Any)
      end
    end

    private def simple_override_value(override : Overrides::OptionOverride) : YAML::Any?
      case override.kind
      when "mode"
        YAML::Any.new((override.pool || MODES).sample(@rng))
      when "owner", "group"
        YAML::Any.new("root")
      when "validate"
        YAML::Any.new("/bin/true %s")
      end
    end

    private def pool_override_value(override : Overrides::OptionOverride) : YAML::Any?
      value : String? = case override.kind
      when "source_path"
        (override.pool || Fixtures::SOURCE_FILES).sample(@rng)
      when "work_path"
        Fixtures::DEST_PATHS.sample(@rng)
      when "work_dir"
        [Fixtures::WORK_ROOT, "#{Fixtures::FIXTURE_ROOT}/dir"].sample(@rng)
      when "username"
        "kpg#{random_word(4)}#{@rng.rand(10..99)}"
      when "literal_pool"
        (override.pool || [""]).sample(@rng)
      end
      value.nil? ? nil : YAML::Any.new(value)
    end

    private def happy_scalar(module_name : String, option : OptionSchema) : YAML::Any
      case option.type
      when "bool"
        YAML::Any.new(@rng.rand < 0.5)
      when "int"
        YAML::Any.new(@rng.rand(0..100).to_i64)
      when "float"
        YAML::Any.new(@rng.rand(1.0..100.0))
      when "list"
        element_type = option.elements || "str"
        size = @rng.rand(1..3)
        YAML::Any.new(Array.new(size) { happy_scalar(module_name, option.name, element_type) })
      when "dict"
        YAML::Any.new({} of YAML::Any => YAML::Any)
      when "path"
        path_value(option.name)
      else
        YAML::Any.new(random_word)
      end
    end

    # List elements have no OptionSchema of their own; they share the
    # parent option's name for path heuristics and default to plain words
    # otherwise.
    private def happy_scalar(module_name : String, option_name : String, type : String) : YAML::Any
      case type
      when "bool"
        YAML::Any.new(@rng.rand < 0.5)
      when "int"
        YAML::Any.new(@rng.rand(0..100).to_i64)
      when "path"
        path_value(option_name)
      else
        YAML::Any.new(random_word)
      end
    end

    # Path options without an override fall back to a name heuristic:
    # src-shaped names point at existing read-only fixture files, anything
    # else at a writable path under the work root. Nothing the generator
    # emits ever references a path outside those two roots.
    private def path_value(option_name : String) : YAML::Any
      if option_name == "src" || option_name.ends_with?("src")
        YAML::Any.new(Fixtures::SOURCE_FILES.sample(@rng))
      else
        YAML::Any.new(Fixtures::DEST_PATHS.sample(@rng))
      end
    end

    private def wrong_type_value(option : OptionSchema) : YAML::Any
      case option.type
      when "list", "dict", "bool", "int", "float"
        YAML::Any.new(random_word)
      else
        YAML::Any.new(@rng.rand(0..100).to_i64)
      end
    end

    private def bad_choice_value(option : OptionSchema) : String
      candidate = "#{option.choices.sample(@rng)}_x"
      while option.choices.includes?(candidate)
        candidate = "#{candidate}_x"
      end
      candidate
    end

    # A typo'd name must never collide with another real option name:
    # that would silently clobber an unrelated argument while the recorded
    # mutation still names the original option. Try each adjacent-swap
    # position; if every swap collides (or changes nothing), fall back to
    # appending a character until the result is collision-free.
    private def typo_name(name : String, real_names : Array(String)) : String
      if name.size < 2
        candidate = "#{name}x"
        while real_names.includes?(candidate)
          candidate = "#{candidate}x"
        end
        return candidate
      end

      start = @rng.rand(name.size - 1)
      (name.size - 1).times do |offset|
        idx = (start + offset) % (name.size - 1)
        chars = name.chars
        chars[idx], chars[idx + 1] = chars[idx + 1], chars[idx]
        candidate = chars.join
        return candidate unless real_names.includes?(candidate) || candidate == name
      end

      candidate = "#{name}x"
      while real_names.includes?(candidate)
        candidate = "#{candidate}x"
      end
      candidate
    end

    private def random_word(length : Int32 = 6) : String
      String.build { |str| length.times { str << ALPHABET.sample(@rng) } }
    end
  end
end
