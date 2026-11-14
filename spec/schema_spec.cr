require "./spec_helper"
require "../src/krikri_playbook_generator/schema"

module KrikriPlaybookGenerator
  # These specs shell out to the real, locally-installed ansible-doc/python3
  # (no fake — the whole point of SchemaScanner is to track whatever
  # ansible-core is actually installed). Full discovery (the default
  # ansible.builtin-only slice, or --all-modules' every-installed-module
  # pass) isn't covered here: either way it scans hundreds of modules,
  # one ansible-doc + one python3 subprocess each, far too slow for a
  # unit spec — verify those paths live instead.
  describe SchemaScanner do
    it "filters the ansible-doc listing down to sorted, stripped core module names" do
      listing = JSON.parse(%({"community.general.sudoers": {}, "ansible.posix.synchronize": {}, "ansible.builtin.copy": {}, "ansible.builtin.apt": {}}))
      assert_equal(%w[apt copy], SchemaScanner.core_module_names(listing))
    end

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

module KrikriPlaybookGenerator
  describe SchemaScanner do
    it "keeps a krikri module that ansible-doc can resolve and drops the ones it cannot" do
      listing = JSON.parse(%({"ansible.builtin.copy": {}, "ansible.builtin.apt": {},
                              "ansible.posix.synchronize": {}, "community.crypto.openssl_privatekey": {}}))
      names = SchemaScanner.names_from_listing(listing, %w[
        ansible.posix.synchronize community.crypto.openssl_privatekey ansible.builtin.py_module virt_net
      ])
      assert_includes(names, "ansible.posix.synchronize")
      assert_includes(names, "community.crypto.openssl_privatekey")
      refute_includes(names, "py_module")
      refute_includes(names, "virt_net")
      assert_includes(names, "copy")
    end

    it "excludes modules the harness cannot exercise even when krikri implements them" do
      listing = JSON.parse(%({"ansible.builtin.copy": {},
                              "amazon.aws.ec2_instance": {}, "amazon.aws.iam_user_info": {}}))
      names = SchemaScanner.names_from_listing(listing, %w[
        amazon.aws.ec2_instance amazon.aws.iam_user_info
      ])
      refute_includes(names, "amazon.aws.ec2_instance")
      refute_includes(names, "amazon.aws.iam_user_info")
    end

    it "maps krikri's bare virt_net spelling to the collection FQCN ansible-doc can scan" do
      assert_equal("community.libvirt.virt_net", SchemaScanner::SCOPE_ALIASES["virt_net"])
    end

    it "reads the supported-module list from the engine binary" do
      bin = File.tempname("kpg-scope-bin")
      File.write(bin, <<-SH)
        #!/bin/sh
        printf '["ansible.builtin.copy","ansible.posix.synchronize","virt_net"]'
      SH
      File.chmod(bin, 0o755)
      assert_equal(%w[ansible.builtin.copy ansible.posix.synchronize community.libvirt.virt_net],
        SchemaScanner.krikri_module_names(bin))
    ensure
      File.delete(bin) if bin
    end

    it "yields no scope when the engine binary cannot list modules" do
      bin = File.tempname("kpg-scope-bad")
      File.write(bin, "#!/bin/sh\necho 'unknown option' >&2\nexit 1\n")
      File.chmod(bin, 0o755)
      assert_equal([] of String, SchemaScanner.krikri_module_names(bin))
    ensure
      File.delete(bin) if bin
    end
  end
end
