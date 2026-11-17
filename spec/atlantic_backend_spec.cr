require "./spec_helper"
require "../src/krikri_playbook_generator/atlantic_backend"

module KrikriPlaybookGenerator
  describe AtlanticBackend do
    it "maps every profile module to a defined profile" do
      missing = AtlanticBackend::PROFILE_FOR_MODULE.values.uniq!.reject { |profile| AtlanticBackend::PROFILES.has_key?(profile) }
      assert_equal [] of String, missing
    end

    it "defines no empty profile module set" do
      AtlanticBackend::PROFILES.each_key do |profile|
        modules = AtlanticBackend::PROFILE_FOR_MODULE.select { |_module, mapped| mapped == profile }.keys
        refute_empty modules, "profile #{profile} has no modules mapped to it"
      end
    end

    it "generates RFC 4122 v4-shaped guids" do
      backend = AtlanticBackend.new("/dev/null", 1, 1)
      guid = backend.random_guid
      assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, guid)
    end

    it "strips the caching/gathering env vars in the engine invocation" do
      assert_equal true, !AtlanticBackend::ENGINE_ENV_STRIP.includes?("ANSIBLE_GATHERING=")
      assert_equal true, AtlanticBackend::ENGINE_ENV_STRIP.includes?("ANSIBLE_NOCOLOR=1")
    end

    it "installs every pinned collection at its pinned version" do
      pins = Dependencies.load.collection_pins
      expected = pins.keys.sort!.map { |name| "#{name}:==#{pins[name]}" }
      assert_equal(expected, AtlanticBackend.collection_requirements)
      assert_includes(AtlanticBackend.collection_requirements, "community.docker:==#{pins["community.docker"]}")
    end

    it "reports a resolved collection version that does not match its pin" do
      pin = Dependencies.load.collection_pins["community.docker"]
      requirements = ["community.docker:==#{pin}"]
      mismatches = Dependencies.collection_version_mismatches(
        requirements, {"community.docker" => ["0.0.1"]})
      assert_equal(["expected community.docker #{pin}, resolved 0.0.1"], mismatches)
      assert_equal([] of String, Dependencies.collection_version_mismatches(
        requirements, {"community.docker" => [pin]}))
    end
  end
end
