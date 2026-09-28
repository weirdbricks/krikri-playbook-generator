require "./spec_helper"
require "../src/krikri_playbook_generator/schema"

module KrikriPlaybookGenerator
  # These specs shell out to the real, locally-installed ansible-doc/python3
  # (no fake — the whole point of SchemaScanner is to track whatever
  # ansible-core is actually installed). Unfiltered discovery (no
  # --modules) isn't covered here: it scans every installed module
  # (~9000+), one ansible-doc + one python3 subprocess each, far too slow
  # for a unit spec — verify that path live instead.
  describe SchemaScanner do
    it "scans a real installed core module via ansible-doc" do
      schemas = SchemaScanner.new(["apt"]).scan
      assert_equal(1, schemas.size)

      schema = schemas.first
      assert_equal("apt", schema.module_name)
      assert_equal("ansible.builtin", schema.collection)
      refute_empty(schema.options)

      name_option = schema.options["name"]?
      refute_nil(name_option)
      assert_equal("list", name_option.as(OptionSchema).type)
    end

    it "statically extracts literal cross-option constraints from module source" do
      schema = SchemaScanner.new(["apt"]).scan.first
      assert_includes(schema.mutually_exclusive, %w[deb package upgrade])
    end

    it "extracts a required_if constraint (heterogeneous entries) from module source" do
      schema = SchemaScanner.new(["iptables"]).scan.first
      refute_empty(schema.required_if)

      first = schema.required_if.first.as_a
      assert_equal("jump", first[0].as_s)
    end

    it "skips a module name ansible-doc doesn't recognize rather than raising" do
      schemas = SchemaScanner.new(["definitely_not_a_real_module_xyz"]).scan
      assert_empty(schemas)
    end

    it "still scans the valid modules when the requested list also contains a bogus one" do
      schemas = SchemaScanner.new(["apt", "definitely_not_a_real_module_xyz"]).scan
      assert_equal(1, schemas.size)
      assert_equal("apt", schemas.first.module_name)
      refute_empty(schemas.first.options)
    end
  end
end
