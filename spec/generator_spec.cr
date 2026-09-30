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
