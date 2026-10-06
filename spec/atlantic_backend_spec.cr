require "./spec_helper"
require "../src/krikri_playbook_generator/atlantic_backend"

module KrikriPlaybookGenerator
  describe AtlanticBackend do
    it "maps every profile module to a defined profile" do
      missing = AtlanticBackend::PROFILE_FOR_MODULE.values.uniq.reject { |profile| AtlanticBackend::PROFILES.has_key?(profile) }
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
  end
end
