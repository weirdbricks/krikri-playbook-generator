require "./spec_helper"
require "../src/krikri_playbook_generator/generator"

module KrikriPlaybookGenerator
  describe Generator do
    def apt_schema : ModuleSchema
      schema = ModuleSchema.new("apt", "ansible.builtin")
      schema.options["name"] = OptionSchema.new("name", "list", elements: "str")
      schema.options["state"] = OptionSchema.new("state", "str", choices: %w[absent present latest])
      schema.options["update_cache"] = OptionSchema.new("update_cache", "bool")
      schema.options["force"] = OptionSchema.new("force", "bool", required: true)
      schema.mutually_exclusive = [%w[deb name upgrade]]
      schema.required_together = [%w[a b]]
      schema.required_one_of = [%w[x y]]
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

    it "tags every mutation with a real ChaosKind at 100% chaos" do
      tasks = Generator.new(1, 100.0).generate(apt_schema, 5)
      tasks.each do |task|
        assert(task.chaos?)
        task.mutations.each do |(_, kind)|
          assert_instance_of(ChaosKind, kind)
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
  end
end
