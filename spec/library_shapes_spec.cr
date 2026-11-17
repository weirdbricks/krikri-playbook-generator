require "./spec_helper"
require "../src/krikri_playbook_generator/library_shapes"
require "../src/krikri_playbook_generator/overrides"

module KrikriPlaybookGenerator
  describe ModuleUtilsSurface do
    it "enumerates the public ansible.module_utils import surface" do
      names = ModuleUtilsSurface.names

      assert_includes(names, "ansible.module_utils.basic")
      assert_includes(names, "ansible.module_utils.common.text.converters")
      # ansible itself tells custom modules not to import its private tree,
      # so `all` leaves those out instead of drowning the batch in them.
      refute(names.any? { |name| name.split(".").any?(&.starts_with?("_")) })
    end

    it "splits the requested names into probes and overrides-driven skips" do
      overrides = Overrides.new(<<-YAML)
        modules: {}
        module_utils_skip:
          ansible.module_utils.optional: needs an optional third-party library
        YAML

      kept, skipped = ModuleUtilsSurface.select(
        ["ansible.module_utils.basic", "ansible.module_utils.optional"], overrides)

      assert_equal(["ansible.module_utils.basic"], kept)
      assert_equal([{"ansible.module_utils.optional", "needs an optional third-party library"}], skipped)
    end

    it "keeps an explicitly named private module instead of silently dropping it" do
      kept, _skipped = ModuleUtilsSurface.select(["ansible.module_utils.internal_probe"], Overrides.new("modules: {}"))

      assert_equal(["ansible.module_utils.internal_probe"], kept)
    end

    it "builds one uniquely named probe per import path, with the import in the source" do
      probes = ModuleUtilsSurface.probes(
        ["ansible.module_utils.basic", "ansible.module_utils.facts.system.distribution"])

      assert_equal(%w[kpg_mu_basic kpg_mu_facts_system_distribution], probes.map(&.module_name))
      assert_equal(probes.map(&.module_name).size, probes.map(&.module_name).uniq!.size)
      probes.each do |probe|
        assert_equal("module-utils", probe.shape)
        assert_includes(probe.source, "import #{probe.target} as kpg_probe_target")
        assert_includes(probe.source, "from ansible.module_utils.basic import AnsibleModule")
        assert_empty(probe.args)
        refute(probe.deliberate_failure)
      end
    end

    it "imports the module's public names, not just the module" do
      probe = ModuleUtilsSurface.probes(["ansible.module_utils.common.text.converters"]).first

      assert_includes(probe.source, "from ansible.module_utils.common.text.converters import ")
      assert_includes(probe.source, "to_text")
      assert_includes(probe.source, "to_native")
    end

    it "sanitizes a dotted import path into a valid module name" do
      assert_equal("kpg_mu_common_text_converters",
        ModuleUtilsSurface.probe_name("ansible.module_utils.common.text.converters"))
    end
  end

  describe ModuleUtilsShapes do
    it "parses `all`, explicit paths and `none`" do
      assert_equal(["all"], ModuleUtilsShapes.parse_list("all"))
      assert_equal(["ansible.module_utils.basic"], ModuleUtilsShapes.parse_list("ansible.module_utils.basic"))
      assert_equal([] of String, ModuleUtilsShapes.parse_list("none"))
      assert_nil(ModuleUtilsShapes.parse_list(" "))
    end
  end

  describe LibraryShapes do
    it "parses `all`, named shapes and `none`, and refuses an unknown shape" do
      assert_equal(LibraryShapes::KINDS, LibraryShapes.parse_list("all"))
      assert_equal(%w[check-mode dict-arg], LibraryShapes.parse_list("check-mode,dict-arg"))
      assert_equal([] of String, LibraryShapes.parse_list("none"))
      assert_nil(LibraryShapes.parse_list("telepathy"))
    end

    it "builds one uniquely named module per shape, with the shape recorded" do
      shapes = LibraryShapes::KINDS.map { |kind| LibraryShape.parse(kind) || raise("bad shape") }
      probes = LibraryShapes.probes(shapes)

      assert_equal(shapes.size, probes.size)
      assert_equal(probes.map(&.module_name).size, probes.map(&.module_name).uniq!.size)
      probes.each do |probe|
        assert_equal("library", probe.shape)
        assert(probe.module_name.starts_with?("kpg_lib_"))
        assert_includes(probe.source, "from ansible.module_utils.basic import AnsibleModule")
      end
    end

    it "passes exactly the arguments that trip a rejected shape" do
      choices = LibraryShapes.probes([LibraryShape::Choices]).first
      assert_equal("three", choices.args["mode_choice"].as_s)
      assert(choices.deliberate_failure)

      mutually_exclusive = LibraryShapes.probes([LibraryShape::MutuallyExclusive]).first
      assert(mutually_exclusive.args.has_key?("left"))
      assert(mutually_exclusive.args.has_key?("right"))
      assert(mutually_exclusive.deliberate_failure)

      assert(LibraryShapes.probes([LibraryShape::Required]).first.args.empty?)
      assert(LibraryShapes.probes([LibraryShape::RequiredOneOf]).first.args.empty?)
      assert(LibraryShapes.probes([LibraryShape::Warnings]).first.args.empty?)
    end

    it "marks only the shapes whose reference run fails by design" do
      failing = LibraryShapes::KINDS.map { |kind| LibraryShape.parse(kind) || raise("bad shape") }
        .select(&.deliberate_failure?).map(&.label)
      assert_equal(%w[required choices mutually-exclusive required-one-of fail-traceback], failing)
    end

    it "keeps the probed surface in the module source" do
      check = LibraryShapes.probes([LibraryShape::CheckMode]).first
      assert_includes(check.source, "supports_check_mode=True")
      refute(check.deliberate_failure)

      no_check = LibraryShapes.probes([LibraryShape::NoCheck]).first
      refute(no_check.source.includes?("supports_check_mode"))

      no_log = LibraryShapes.probes([LibraryShape::NoLog]).first
      assert_includes(no_log.source, "\"no_log\": True")
      assert_equal("kpg-secret-value", no_log.args["secret"].as_s)

      dict_arg = LibraryShapes.probes([LibraryShape::DictArg]).first
      assert_includes(dict_arg.source, "\"type\": \"dict\"")
      assert_equal("kpg", dict_arg.args["config"]["name"].as_s)

      common = LibraryShapes.probes([LibraryShape::CommonImport]).first
      assert_includes(common.source, "from ansible.module_utils.common.text.converters import to_bytes, to_native, to_text")

      collection = LibraryShapes.probes([LibraryShape::CollectionImport]).first
      assert_includes(collection.source,
        "from ansible_collections.community.general.plugins.module_utils.version import LooseVersion")
    end
  end
end
