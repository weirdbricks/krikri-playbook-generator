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

    it "normalizes every collection requirement to the data file's pin" do
      deps = Dependencies.new(pinned_yaml_for_spec)

      assert_equal("community.general:==12.5.0", deps.package_sets(["community.general.sudoers"]).collections.first)
      # A hand-written pin and the FQCN-derived name collapse to one.
      assert_equal(["community.general:==12.5.0"], deps.package_sets(["community.general.ini_file"]).collections)
      # Collections the file does not pin stay floating rather than guessed at.
      assert_equal(["unpinned.collection"], deps.package_sets(["unpinned.collection.mod"]).collections)
    end

    it "reads installed collection versions from ansible-galaxy's JSON listing" do
      listing = <<-JSON
        {"/root/.ansible/collections/ansible_collections": {"community.general": {"version": "12.5.0"}},
         "/usr/share/ansible/collections/ansible_collections": {"community.general": {"version": "11.2.1"},
                                                               "ansible.posix": {"version": "2.1.0"}}}
        JSON
      installed = Dependencies.installed_collection_versions(listing)
      assert_equal(["12.5.0", "11.2.1"], installed["community.general"])
      assert_equal(["2.1.0"], installed["ansible.posix"])
    end

    it "accepts a pinned copy ahead of the distro one and reports a shadowed, missing or drifted pin" do
      requirements = ["community.general:==12.5.0", "community.docker:==5.2.1",
                      "ansible.posix:==2.1.0", "community.mysql:==5.0.2"]
      installed = {
        # the pinned copy comes first in search order, Debian's older one behind it
        "community.general" => ["12.5.0", "11.2.1"],
        # the distro copy would win, which is exactly the failure mode
        "community.docker" => ["4.7.0", "5.2.1"],
        "ansible.posix"    => ["2.1.0"],
      }

      mismatches = Dependencies.collection_version_mismatches(requirements, installed)
      assert_equal(2, mismatches.size)
      assert(mismatches[0].includes?("community.docker"))
      assert(mismatches[0].includes?("4.7.0 then 5.2.1"))
      assert(mismatches[1].includes?("community.mysql"))
      assert(mismatches[1].includes?("no installed copy"))
    end

    it "supported_module_names filters the ansible-doc listing to installed ones" do
      listing = JSON.parse(%({"community.general.sudoers": {}, "ansible.builtin.copy": {}, "ansible.builtin.apt": {}}))
      names = SchemaScanner.supported_module_names(listing, ["community.general.sudoers", "community.general.missing"])
      assert_equal(["community.general.sudoers"], names)
    end

    PINNED_YAML_HELPER = <<-YAML
      collection_pins:
        community.general: "12.5.0"

      community.general.sudoers:
        real:
          debian_packages: [sudo]
          collections: [community.general:==12.5.0]

      community.general.ini_file:
        real:
          debian_packages: []
          collections: [community.general]

      unpinned.collection.mod:
        real:
          debian_packages: []
      YAML

    def pinned_yaml_for_spec : String
      PINNED_YAML_HELPER
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
