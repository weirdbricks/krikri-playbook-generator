require "./spec_helper"
require "../src/krikri_playbook_generator/generator"
require "../src/krikri_playbook_generator/fixtures"

module KrikriPlaybookGenerator
  describe Generator do
    def apt_schema : ModuleSchema
      schema = ModuleSchema.new("apt", "ansible.builtin")
      schema.options["name"] = OptionSchema.new("name", "list", elements: "str")
      schema.options["state"] = OptionSchema.new("state", "str", choices: %w[absent present latest])
      schema.options["update_cache"] = OptionSchema.new("update_cache", "bool")
      schema.options["force"] = OptionSchema.new("force", "bool", required: true)
      schema.options["x"] = OptionSchema.new("x", "str")
      schema.options["y"] = OptionSchema.new("y", "str")
      schema.mutually_exclusive = [%w[deb name upgrade]]
      schema.required_together = [%w[a b]]
      schema.required_one_of = [%w[x y]]
      schema
    end

    def copy_schema : ModuleSchema
      schema = ModuleSchema.new("copy", "ansible.builtin")
      schema.options["src"] = OptionSchema.new("src", "path")
      schema.options["dest"] = OptionSchema.new("dest", "path")
      schema.options["mode"] = OptionSchema.new("mode", "raw")
      schema.options["owner"] = OptionSchema.new("owner", "str")
      schema.options["validate"] = OptionSchema.new("validate", "str")
      schema.options["content"] = OptionSchema.new("content", "str")
      schema
    end

    def debug_schema : ModuleSchema
      schema = ModuleSchema.new("debug", "ansible.builtin")
      schema.options["msg"] = OptionSchema.new("msg", "str")
      schema
    end

    it "generates the requested count of tasks" do
      tasks = Generator.new(1).generate(apt_schema, 5)
      assert_equal(5, tasks.size)
    end

    it "always includes required options at 0% chaos" do
      Generator.new(1, 0.0).generate(apt_schema, 20).each do |task|
        assert(task.args.has_key?("force"))
        refute(task.chaos?)
      end
    end

    it "is deterministic for a given seed" do
      a = Generator.new(42, 5.0).generate(apt_schema, 10).map(&.args.to_s)
      b = Generator.new(42, 5.0).generate(apt_schema, 10).map(&.args.to_s)
      assert_equal(a, b)
    end

    it "generates multi-task scenarios of distinct modules" do
      scenarios = Generator.new(9, 0.0).generate_scenarios([apt_schema, copy_schema, debug_schema], 3, 5)

      assert_equal(5, scenarios.size)
      scenarios.each do |tasks|
        assert_equal(3, tasks.size)
        assert_equal(3, tasks.map(&.module_name).uniq!.size)
      end
    end

    it "chains each task's when condition onto the previous task's register" do
      Generator.new(2, 0.0).generate_scenarios([apt_schema, copy_schema, debug_schema], 3, 10).each do |tasks|
        refute(tasks.first.when_condition)
        tasks[1..].each_with_index do |task, offset|
          condition = task.when_condition
          refute_nil(condition)
          expected_register = "kpg_task_#{offset}"
          assert(condition.to_s.starts_with?("#{expected_register} is "))
        end
      end
    end

    it "wires a fixture-source-path argument into a loop over the fixture sources" do
      scenarios = Generator.new(4, 0.0).generate_scenarios([copy_schema, debug_schema], 2, 30)
      looped = scenarios.flatten.select(&.loop_option)

      refute(looped.empty?, "expected at least one loop-wired copy task across the batch")
      looped.each do |task|
        assert_equal("src", task.loop_option)
        assert_equal("{{ item }}", task.args["src"].as_s)
        assert_equal(Fixtures::SOURCE_FILES, task.loop_items)
      end
    end

    it "raises for multi-task scenarios without two distinct modules" do
      err = assert_raises(ArgumentError) { Generator.new(1).generate_scenarios([apt_schema], 2, 1) }
      assert((err.message || "").includes?("at least 2"))

      err = assert_raises(ArgumentError) { Generator.new(1).generate_scenarios([apt_schema, copy_schema], 1, 1) }
      assert((err.message || "").includes?("per_playbook"))
    end

    it "is deterministic for a given seed across scenarios too" do
      schemas = [apt_schema, copy_schema, debug_schema]
      shape = ->(seed : Int32) do
        Generator.new(seed, 5.0).generate_scenarios(schemas, 3, 6).map do |tasks|
          tasks.map { |task| "#{task.module_name}:#{task.when_condition}:#{task.loop_option}:#{task.notify}:#{task.args}" }.join("|")
        end
      end
      assert_equal(shape.call(11), shape.call(11))
    end

    it "produces a choice value from the schema at 0% chaos" do
      task = Generator.new(1, 0.0).generate(apt_schema, 1).first
      state = task.args["state"]?
      assert_includes(%w[absent present latest], state.as_s) if state
    end

    it "points path-typed options at pre-seeded fixture or work paths only" do
      Generator.new(3, 0.0).generate(copy_schema, 30).each do |task|
        {"src" => Fixtures::SOURCE_FILES, "dest" => Fixtures::DEST_PATHS}.each do |name, allowed|
          value = task.args[name]?
          next unless value

          assert(allowed.includes?(value.as_s),
            "#{name}=#{value.as_s.inspect} is outside the fixture/work roots")
        end
      end
    end

    it "generates a valid octal mode string and existing owner/group via the override table" do
      Generator.new(5, 0.0).generate(copy_schema, 30).each do |task|
        mode = task.args["mode"]?
        assert_includes(["0644", "0755", "0600", "0750"], mode.as_s) if mode

        owner = task.args["owner"]?
        assert_equal("root", owner.as_s) if owner
      end
    end

    it "gives validate a value containing the required %s placeholder" do
      Generator.new(5, 0.0).generate(copy_schema, 30).each do |task|
        validate = task.args["validate"]?
        assert(validate.as_s.includes?("%s")) if validate
      end
    end

    it "never includes a happy-path-excluded option (copy.content)" do
      Generator.new(5, 0.0).generate(copy_schema, 30).each do |task|
        refute(task.args.has_key?("content"), "copy.content must stay out of happy-path tasks")
      end
    end

    it "satisfies mutually_exclusive groups in the happy path" do
      Generator.new(9, 0.0).generate(apt_schema, 50).each do |task|
        present = %w[deb name upgrade].count { |name| task.args.has_key?(name) }
        assert(present <= 1, "mutually_exclusive group fully included: #{task.args}")
      end
    end

    it "satisfies required_one_of groups in the happy path" do
      Generator.new(9, 0.0).generate(apt_schema, 50).each do |task|
        present = %w[x y].count { |name| task.args.has_key?(name) }
        assert(present >= 1, "required_one_of group left empty: #{task.args}")
      end
    end

    it "satisfies required_if in the happy path" do
      schema = ModuleSchema.new("thing", "ansible.builtin")
      schema.options["state"] = OptionSchema.new("state", "str", choices: %w[present absent])
      schema.options["path"] = OptionSchema.new("path", "path")
      schema.options["extra"] = OptionSchema.new("extra", "str")
      schema.required_if = [JSON.parse(%q(["state", "present", ["path"], false]))]

      Generator.new(11, 0.0).generate(schema, 50).each do |task|
        state = task.args["state"]?
        if state && state.as_s == "present"
          assert(task.args.has_key?("path"), "required_if demanded path for state=present: #{task.args}")
        end
      end
    end

    it "tags every mutation with a real ChaosKind at 100% chaos" do
      tasks = Generator.new(1, 100.0).generate(apt_schema, 5)
      tasks.each do |task|
        assert(task.chaos?)
        task.mutations.each do |(_, kind)|
          assert_instance_of(ChaosKind, kind)
        end
      end
    end

    it "keeps a required member when a mutually_exclusive group has to be cut" do
      schema = ModuleSchema.new("req_exclusive", "ansible.builtin")
      schema.options["content"] = OptionSchema.new("content", "str")
      schema.options["path"] = OptionSchema.new("path", "path", required: true)
      schema.mutually_exclusive = [%w[content path]]

      overrides = Overrides.new(<<-YAML)
          modules:
            req_exclusive:
              always: [content, path]
        YAML

      Generator.new(19, 0.0, ChaosKind.values, overrides).generate(schema, 10).each do |task|
        assert(task.args.has_key?("path"), "the required member was cut: #{task.args}")
        refute(task.args.has_key?("content"))
      end
    end

    it "keeps a fill from introducing a mutually_exclusive sibling" do
      schema = ModuleSchema.new("exclusive", "ansible.builtin")
      schema.options["path"] = OptionSchema.new("path", "path")
      schema.options["content"] = OptionSchema.new("content", "str")
      schema.required_together = [%w[path content]]
      schema.mutually_exclusive = [%w[path content]]

      overrides = Overrides.new(<<-YAML)
          modules:
            exclusive:
              always: [path]
        YAML

      Generator.new(13, 0.0, ChaosKind.values, overrides).generate(schema, 20).each do |task|
        present = %w[path content].count { |name| task.args.has_key?(name) }
        assert(present <= 1, "mutually_exclusive siblings both present: #{task.args}")
      end
    end

    it "keeps a required_if fill from introducing a mutually_exclusive sibling" do
      schema = ModuleSchema.new("exclusive_if", "ansible.builtin")
      schema.options["state"] = OptionSchema.new("state", "str", choices: %w[present])
      schema.options["path"] = OptionSchema.new("path", "path")
      schema.options["content"] = OptionSchema.new("content", "str")
      schema.mutually_exclusive = [%w[path content]]
      schema.required_if = [JSON.parse(%q(["state", "present", ["content"], false]))]

      overrides = Overrides.new(<<-YAML)
          modules:
            exclusive_if:
              always: [path, state]
        YAML

      Generator.new(17, 0.0, ChaosKind.values, overrides).generate(schema, 20).each do |task|
        present = %w[path content].count { |name| task.args.has_key?(name) }
        assert(present <= 1, "mutually_exclusive siblings both present: #{task.args}")
      end
    end

    it "renders an empty_dict override as a real empty dict" do
      schema = ModuleSchema.new("typed", "ansible.builtin")
      schema.options["spec"] = OptionSchema.new("spec", "str", required: true)
      overrides = Overrides.new(<<-YAML)
          modules:
            typed:
              spec: {kind: empty_dict}
        YAML

      Generator.new(2, 0.0, ChaosKind.values, overrides).generate(schema, 5).each do |task|
        assert(task.args["spec"].raw.is_a?(Hash), "expected an empty dict, got #{task.args["spec"].raw.class}")
      end
    end

    it "jinja-wraps an option value into an equivalent template expression" do
      baseline = Generator.new(23, 0.0, [ChaosKind::Jinja]).generate(apt_schema, 1).first
      mutated = Generator.new(23, 100.0, [ChaosKind::Jinja]).generate(apt_schema, 1).first

      force = baseline.args["force"]
      assert_equal("{{ #{force.as_bool ? "true" : "false"} }}", mutated.args["force"].as_s)
      assert_equal([{"force", ChaosKind::Jinja}],
        mutated.mutations.select { |(name, _)| name == "force" })
    end

    it "jinja-wraps string values while keeping the value as a quoted literal" do
      baseline = Generator.new(29, 0.0, [ChaosKind::Jinja]).generate(copy_schema, 1).first
      mutated = Generator.new(29, 100.0, [ChaosKind::Jinja]).generate(copy_schema, 1).first

      src = baseline.args["src"].as_s
      assert_equal("{{ '#{src}' }}", mutated.args["src"].as_s)
    end

    it "records a Jinja mutation for every wrapped slot and never for a free-form body" do
      tasks = Generator.new(31, 100.0, [ChaosKind::Jinja]).generate(copy_schema, 10)
      tasks.each do |task|
        task.mutations.each do |(name, kind)|
          assert_equal(ChaosKind::Jinja, kind)
          assert(task.args[name].as_s.starts_with?("{{ "), "#{name} was not templated: #{task.args[name]}")
          assert(task.args[name].as_s.ends_with?(" }}"))
        end
      end

      free_form = Generator.new(31, 100.0, ChaosKind.values, free_form_overrides)
        .generate(ModuleSchema.new("meta", "ansible.builtin"), 5)
      free_form.each do |task|
        assert_equal([{"free_form", ChaosKind::BadChoice}], task.mutations)
      end
    end

    it "mutates a valid baseline instead of inventing fresh chaos values" do
      tasks = Generator.new(3, 100.0, [ChaosKind::WrongType]).generate(copy_schema, 20)
      tasks.each do |task|
        task.mutations.each do |(name, kind)|
          assert_equal(ChaosKind::WrongType, kind)
          # the wrong-type mutation must REPLACE a slot the valid baseline
          # had, never appear on an option the baseline didn't include
          assert(copy_schema.options.has_key?(name))
        end
      end
    end

    it "only applies BadChoice mutations to options that actually have choices" do
      tasks = Generator.new(3, 100.0, [ChaosKind::BadChoice]).generate(apt_schema, 10)
      tasks.each do |task|
        task.mutations.each do |(name, kind)|
          assert_equal(ChaosKind::BadChoice, kind)
          assert_equal("state", name)
        end
      end
    end

    it "violates a mutually_exclusive group by including all its members together" do
      tasks = Generator.new(7, 100.0, [ChaosKind::ViolateConstraint]).generate(apt_schema, 20)
      violated = tasks.any? do |task|
        task.mutations.any? { |(name, kind)| kind.violate_constraint? && name == "deb,name,upgrade" }
      end
      assert(violated)
    end

    it "violates required_if by forcing the condition and dropping demanded keys" do
      schema = required_if_schema("all")
      tasks = Generator.new(3, 100.0, [ChaosKind::ViolateConstraint], always_overrides)
        .generate(schema, 20)

      violated = tasks.select do |task|
        task.mutations.any? { |(name, kind)| kind.violate_constraint? && name == "required_if:state" }
      end
      assert(violated.present?, "no task violated required_if: #{tasks.map(&.mutations)}")
      violated.each do |task|
        assert_equal("present", task.args["state"].as_s)
        refute(task.args.has_key?("path"), "demanded key survived violation: #{task.args}")
      end
    end

    it "violates required_if in any-mode by dropping every demanded key" do
      schema = required_if_schema("any")
      schema.options["extra"] = OptionSchema.new("extra", "str")
      schema.required_if = [JSON.parse(%q(["state", "present", ["path", "extra"], true]))]

      tasks = Generator.new(3, 100.0, [ChaosKind::ViolateConstraint], always_overrides)
        .generate(schema, 20)

      violated = tasks.select do |task|
        task.mutations.any? { |(name, _)| name == "required_if:state" }
      end
      assert(violated.present?)
      violated.each do |task|
        refute(task.args.has_key?("path"))
        refute(task.args.has_key?("extra"))
      end
    end

    it "violates required_if with a bool condition value" do
      schema = ModuleSchema.new("if_bool", "ansible.builtin")
      schema.options["enabled"] = OptionSchema.new("enabled", "bool")
      schema.options["path"] = OptionSchema.new("path", "path")
      schema.required_if = [JSON.parse(%q(["enabled", true, ["path"], false]))]

      overrides = Overrides.new("modules:\n  if_bool:\n    always: [enabled, path]\n")
      tasks = Generator.new(3, 100.0, [ChaosKind::ViolateConstraint], overrides).generate(schema, 20)

      violated = tasks.select { |task| task.mutations.any? { |(name, _)| name == "required_if:enabled" } }
      assert(violated.present?)
      violated.each do |task|
        assert_equal(true, task.args["enabled"].as_bool)
        refute(task.args.has_key?("path"))
      end
    end

    it "violates required_if with an int condition value" do
      schema = ModuleSchema.new("if_int", "ansible.builtin")
      schema.options["retries"] = OptionSchema.new("retries", "int")
      schema.options["path"] = OptionSchema.new("path", "path")
      schema.required_if = [JSON.parse(%q(["retries", 99, ["path"], false]))]

      overrides = Overrides.new("modules:\n  if_int:\n    always: [retries, path]\n")
      tasks = Generator.new(3, 100.0, [ChaosKind::ViolateConstraint], overrides).generate(schema, 20)

      violated = tasks.select { |task| task.mutations.any? { |(name, _)| name == "required_if:retries" } }
      assert(violated.present?)
      violated.each do |task|
        assert_equal(99, task.args["retries"].as_i64)
        refute(task.args.has_key?("path"))
      end
    end

    it "skips required_if violation when a demanded key is a required option" do
      schema = required_if_schema("all")
      schema.options["path"] = OptionSchema.new("path", "path", required: true)

      tasks = Generator.new(3, 100.0, [ChaosKind::ViolateConstraint], always_overrides)
        .generate(schema, 20)
      tasks.each do |task|
        refute(task.mutations.any? { |(name, _)| name == "required_if:state" },
          "violation must skip when it would also trip missing-required: #{task.args}")
        assert(task.args.has_key?("path"), "required demanded key was deleted: #{task.args}")
      end
    end

    it "records no required_if mutation at 0% chaos" do
      tasks = Generator.new(3, 0.0, [ChaosKind::ViolateConstraint], always_overrides)
        .generate(required_if_schema("all"), 20)
      tasks.each do |task|
        refute(task.mutations.any? { |(name, kind)| kind.violate_constraint? && name.starts_with?("required_if:") })
      end
    end

    def required_if_schema(mode : String) : ModuleSchema
      schema = ModuleSchema.new("if_thing", "ansible.builtin")
      schema.options["state"] = OptionSchema.new("state", "str", choices: %w[present absent])
      schema.options["path"] = OptionSchema.new("path", "path")
      schema.options["extra"] = OptionSchema.new("extra", "str")
      any = mode == "any"
      schema.required_if = [JSON.parse(%Q(["state", "present", ["path"], #{any}]))]
      schema
    end

    def always_overrides : Overrides
      Overrides.new("modules:\n  if_thing:\n    always: [state, path]\n")
    end

    it "never typos an option name into another real option's name" do
      schema = ModuleSchema.new("collision", "ansible.builtin")
      schema.options["ab"] = OptionSchema.new("ab", "str")
      schema.options["ba"] = OptionSchema.new("ba", "str")

      tasks = Generator.new(5, 100.0, [ChaosKind::Typo]).generate(schema, 50)
      real_names = %w[ab ba]
      assert(tasks.any?(&.chaos?))

      tasks.each do |task|
        extra_keys = task.args.keys - real_names
        assert_equal(task.mutations.size, extra_keys.size)
        extra_keys.each do |key|
          refute(real_names.includes?(key), "typo'd key #{key.inspect} collides with a real option name")
        end
      end
    end

    it "still produces a plain typo when no collision is possible" do
      schema = ModuleSchema.new("solo", "ansible.builtin")
      schema.options["abc"] = OptionSchema.new("abc", "str")

      tasks = Generator.new(5, 100.0, [ChaosKind::Typo]).generate(schema, 20)
      typo_keys = tasks.flat_map(&.args.keys).reject { |key| key == "abc" }
      assert(typo_keys.all? { |key| key == "acb" || key == "bac" })
      refute_empty(typo_keys)
    end

    it "generates a free-form module's whole task body from its pool, with no args" do
      generator = Generator.new(1, 0.0, ChaosKind.values, free_form_overrides)
      tasks = generator.generate(ModuleSchema.new("meta", "ansible.builtin"), 10)

      pool = %w[noop flush_handlers clear_facts refresh_inventory]
      tasks.each do |task|
        value = task.free_form
        refute_nil(value)
        assert_includes(pool, value || "missing free-form value")
        assert_empty(task.args)
        refute(task.chaos?)
      end
    end

    it "mutates a free-form task body into an invalid action in chaos mode" do
      generator = Generator.new(1, 100.0, ChaosKind.values, free_form_overrides)
      tasks = generator.generate(ModuleSchema.new("meta", "ansible.builtin"), 5)

      tasks.each do |task|
        assert(task.chaos?)
        assert((task.free_form || "missing").ends_with?("_bogus"))
        assert_equal([{"free_form", ChaosKind::BadChoice}], task.mutations)
      end
    end

    it "points the role-loading actions at the seeded fixture role and never at a dict-typed apply" do
      tasks = Generator.new(5, 0.0).generate(include_role_schema, 20)
      tasks.each do |task|
        assert_equal(Fixtures::ROLE_PATH, task.args["name"].as_s)
        refute(task.args.has_key?("apply"))
        %w[tasks_from defaults_from vars_from handlers_from].each do |name|
          value = task.args[name]?
          assert_equal("main", value.as_s) if value
        end
      end
    end

    def include_role_schema : ModuleSchema
      schema = ModuleSchema.new("include_role", "ansible.builtin")
      schema.options["name"] = OptionSchema.new("name", "str", required: true)
      schema.options["apply"] = OptionSchema.new("apply", "dict")
      schema.options["tasks_from"] = OptionSchema.new("tasks_from", "str")
      schema.options["defaults_from"] = OptionSchema.new("defaults_from", "str")
      schema.options["vars_from"] = OptionSchema.new("vars_from", "str")
      schema.options["handlers_from"] = OptionSchema.new("handlers_from", "str")
      schema.options["public"] = OptionSchema.new("public", "bool")
      schema
    end

    def free_form_overrides : Overrides
      Overrides.new(<<-YAML)
          modules:
            meta:
              free_form:
                pool: [noop, flush_handlers, clear_facts, refresh_inventory]
        YAML
    end
  end
end
