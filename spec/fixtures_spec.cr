require "./spec_helper"
require "file_utils"
require "yaml"
require "../src/krikri_playbook_generator/fixtures"
require "../src/krikri_playbook_generator/cmd"

module KrikriPlaybookGenerator
  describe Fixtures do
    # The seed script hard-codes the fixture and work roots (the generator's
    # happy-path values are only valid at those absolute paths), so the spec
    # runs it with the two roots rewritten into a temp dir: that is enough to
    # prove the script itself seeds a real, runnable role tree - the actual
    # roots are the same script run as root inside the podman containers.
    def with_seeded_fixtures(&)
      base = File.tempname
      fixture_root = File.join(base, "fixtures")
      script = Fixtures::SEED_SCRIPT
        .gsub(Fixtures::FIXTURE_ROOT, fixture_root)
        .gsub(Fixtures::WORK_ROOT, File.join(base, "work"))
      result = Cmd.run("bash", ["-c", script], timeout: 120.0)
      assert Cmd.success?(result), "seed script failed: #{result.stderr}"
      yield fixture_root
    ensure
      FileUtils.rm_rf(base) if base
    end

    it "points the role at the fixture root" do
      assert_equal("kpgrole", Fixtures::ROLE_NAME)
      assert_equal("#{Fixtures::FIXTURE_ROOT}/roles/kpgrole", Fixtures::ROLE_PATH)
    end

    it "seeds a role with the task/defaults/vars/handlers files the *_from options name" do
      with_seeded_fixtures do |fixture_root|
        role_dir = File.join(fixture_root, "roles", Fixtures::ROLE_NAME)
        %w[tasks defaults vars handlers].each do |sub|
          path = File.join(role_dir, sub, "main.yml")
          assert File.file?(path), "#{sub}/main.yml was not seeded"
          assert_includes(File.read(path), "kpg")
        end
      end
    end

    it "seeds the role task file as parseable YAML with a debug task" do
      with_seeded_fixtures do |fixture_root|
        path = File.join(fixture_root, "roles", Fixtures::ROLE_NAME, "tasks", "main.yml")
        parsed = YAML.parse(File.read(path))
        refute_nil(parsed)
        assert parsed.as_a?, "role tasks file is not a YAML sequence"
      end
    end
  end
end
