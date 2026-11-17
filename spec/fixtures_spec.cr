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

    # The generator's get_url/uri happy paths point at Fixtures::HTTP_URLS,
    # served by the backend's http.server out of the fixture root; every
    # URL must map to a file the seed script actually creates, or the happy
    # path 404s instead of exercising the module.
    it "provisions an unprivileged account with passwordless sudo" do
      script = Fixtures::IDENTITY_SCRIPT
      assert_includes(script, "useradd -m")
      assert_includes(script, Fixtures::UNPRIVILEGED_USER)
      assert_includes(script, "mkdir -p /etc/sudoers.d")
      assert_includes(script, "NOPASSWD:ALL")
      assert_includes(script, "chmod 0440 /etc/sudoers.d/#{Fixtures::UNPRIVILEGED_USER}")
    end

    it "re-owns the writable fixture root for the row's identity" do
      nonroot = Fixtures.ownership_command(UserProfile::Nonroot)
      assert_includes(nonroot, "chown -R #{Fixtures::UNPRIVILEGED_USER}:#{Fixtures::UNPRIVILEGED_USER} #{Fixtures::WORK_ROOT}")
      assert_includes(nonroot, "chmod 0755 #{Fixtures::WORK_ROOT}")
      assert_includes(nonroot, "chmod -R a+rX #{Fixtures::FIXTURE_ROOT}")

      root = Fixtures.ownership_command(UserProfile::Root)
      assert_includes(root, "chown -R root:root #{Fixtures::WORK_ROOT}")
      assert_includes(root, "chmod 0555 #{Fixtures::READONLY_DIR}")
      assert_includes(root, "chmod 0444 #{Fixtures::READONLY_DEST}")
    end

    it "seeds a read-only destination parent that even the nonroot fix leaves read-only" do
      with_seeded_fixtures do |fixture_root|
        work = File.join(fixture_root, "..", "work")
        assert(File.info(File.join(work, "readonly", "dest.txt")))
      end
    end

    it "http fixture URLs resolve to files the seed script creates" do
      with_seeded_fixtures do |fixture_root|
        Fixtures::HTTP_URLS.each do |url|
          relative = url.sub("http://127.0.0.1:#{Fixtures::HTTP_PORT}/", "")
          path = File.join(fixture_root, relative)
          assert File.file?(path), "http fixture URL #{url} has no seeded file at #{path}"
        end
      end
    end
  end
end
