require "./spec_helper"
require "../src/krikri_playbook_generator/dependencies"
require "../src/krikri_playbook_generator/schema"

module KrikriPlaybookGenerator
  describe Dependencies do
    it "loads the empty supported set from the data file (promote a module there, not in code)" do
      deps = Dependencies.load
      assert_equal([] of String, deps.supported)
    end

    it "installs expect's and uri's python libraries on both real template families" do
      sets = Dependencies.load.package_sets([] of String)

      assert_includes(sets.real_debian, "python3-pexpect")
      assert_includes(sets.real_rpm, "python3-pexpect")
      assert_includes(sets.real_debian, "python3-idna")
      assert_includes(sets.real_rpm, "python3-idna")
    end

    it "unions base + selected module packages, partitioned by side" do
      deps = Dependencies.new(cluster_yaml_for_spec)
      sets = deps.package_sets(["community.general.sudoers"])

      assert_includes(sets.real_debian, "ansible")
      assert_includes(sets.real_debian, "python3-pexpect")
      assert_includes(sets.real_debian, "sudo")
      assert_includes(sets.krikri_debian, "sudo")
      refute_includes(sets.krikri_debian, "python3-pexpect")
      assert_includes(sets.collections, "community.general:==13.4.0")
    end

    it "keeps krikri-only packages off the real side and real-only off krikri" do
      deps = Dependencies.new(cluster_yaml_for_spec)
      sets = deps.package_sets(["ansible.builtin.expect"])

      assert_includes(sets.real_debian, "python3-pexpect")
      assert_includes(sets.python, "passlib")
      assert_includes(sets.krikri_debian, "libxml2")
      refute_includes(sets.real_debian, "libxml2")
    end

    it "reports unknown module FQCNs rather than silently ignoring them" do
      deps = Dependencies.new(cluster_yaml_for_spec)
      assert_equal(["community.general.nope"], deps.unknown?(["community.general.nope"]))
      assert_empty(deps.unknown?(["community.general.sudoers"]))
    end

    it "finds a module by its short name, so a hand-written repro still gets its packages" do
      deps = Dependencies.new(cluster_yaml_for_spec)
      sets = deps.package_sets(["sudoers"])

      assert_includes(sets.real_debian, "sudo")
      assert_includes(sets.collections, "community.general:==13.4.0")
      assert_empty(deps.unknown?(["sudoers"]))
      assert_equal(["does_not_exist"], deps.unknown?(["does_not_exist"]))
    end

    it "keeps the base package sections out of the module list" do
      deps = Dependencies.new(cluster_yaml_for_spec)
      assert_equal(%w[ansible.builtin.expect community.general.sudoers], deps.installed_modules)
    end

    it "derives the collection to install from a module's FQCN" do
      assert_equal("community.general", Dependencies.collection_for("community.general.ini_file"))
      assert_equal("ansible.posix", Dependencies.collection_for("ansible.posix.synchronize"))
      assert_nil(Dependencies.collection_for("ansible.builtin.copy"))
      assert_nil(Dependencies.collection_for("copy"))

      deps = Dependencies.new(<<-YAML)
        deb_modules:
          both: [python3]
        rpm_modules:
          both: [python3]
        community.general.ini_file:
          real:
            debian_packages: []
        YAML
      sets = deps.package_sets(["community.general.ini_file"])
      assert_includes(sets.collections, "community.general")
      assert_equal(["community.general"], deps.package_sets(["ansible.builtin.copy"]).collections.empty? ? ["community.general"] : [] of String,
        "core modules must not add a collection install")
    end

    it "supported_module_names filters the ansible-doc listing to installed ones" do
      listing = JSON.parse(%({"community.general.sudoers": {}, "ansible.builtin.copy": {}, "ansible.builtin.apt": {}}))
      names = SchemaScanner.supported_module_names(listing, ["community.general.sudoers", "community.general.missing"])
      assert_equal(["community.general.sudoers"], names)
    end

    CLUSTER_YAML_HELPER = <<-YAML
      supported: []

      deb_modules:
        both: [ansible, python3]
        real: [python3-pexpect]
        krikri: [libxml2]

      rpm_modules:
        both: [python3]
        real: [python3-dnf]
        krikri: []

      community.general.sudoers:
        real:
          debian_packages: [sudo]
          collections: [community.general:==13.4.0]
          python_packages: []
        krikri:
          debian_packages: [sudo]
        both:
          debian_packages: []
          rpm_packages: []

      ansible.builtin.expect:
        real:
          debian_packages: [python3-pexpect]
          python_packages: [passlib]
        krikri:
          debian_packages: []
      YAML

    def cluster_yaml_for_spec : String
      CLUSTER_YAML_HELPER
    end
  end
end
