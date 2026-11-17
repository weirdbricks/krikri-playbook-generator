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

    # File::Permissions only carries the nine permission bits, so the
    # setgid/sticky entries need the full mode stat prints. Compared as an
    # octal number because stat drops the leading zero of a 3-digit mode.
    def mode_of(path : String) : Int32
      result = Cmd.run("stat", ["-c", "%a", path], timeout: 30.0)
      assert Cmd.success?(result), "stat #{path} failed: #{result.stderr}"
      result.stdout.strip.to_i(8)
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
        assert_equal(0o555, mode_of(File.join(work, "readonly")))
      end
    end

    # Real playbooks meet locked files in a writable directory (replace via
    # rename) and directories with setgid/sticky/owner-only modes. Both
    # engines must start from exactly these modes, so the seed has to set
    # them and the per-row ownership fix has to restore them.
    it "seeds read-only and unusual destination modes in the writable work root" do
      with_seeded_fixtures do |fixture_root|
        work = File.join(fixture_root, "..", "work")
        Fixtures::UNUSUAL_FILES.each do |path, mode|
          local = path.sub(Fixtures::WORK_ROOT, work)
          assert File.file?(local), "#{local} was not seeded"
          assert_equal(mode.to_i(8), mode_of(local), "#{local} mode")
        end
        Fixtures::UNUSUAL_DIRS.each do |path, mode|
          local = path.sub(Fixtures::WORK_ROOT, work)
          assert File.directory?(local), "#{local} was not seeded"
          assert_equal(mode.to_i(8), mode_of(local), "#{local} mode")
        end
        Fixtures::UNUSUAL_FILES.each_key do |path|
          assert Fixtures::DEST_PATHS.includes?(path), "#{path} is not a generator destination"
        end
      end
    end

    it "restores the unusual destination state idempotently before every row" do
      with_seeded_fixtures do |fixture_root|
        work = File.join(fixture_root, "..", "work")
        restore = Fixtures::RESTORE_UNUSUAL_SCRIPT
          .gsub(Fixtures::WORK_ROOT, work)
        # Simulate an earlier row that rewrote content and modes.
        Fixtures::UNUSUAL_FILES.each_key do |path|
          local = path.sub(Fixtures::WORK_ROOT, work)
          File.chmod(local, 0o600)
          File.write(local, "rewritten by an earlier row")
        end
        File.chmod(File.join(work, "dir-setgid"), 0o755)

        2.times do
          result = Cmd.run("bash", ["-c", restore], timeout: 60.0)
          assert Cmd.success?(result), "restore script failed: #{result.stderr}"
          Fixtures::UNUSUAL_FILES.each do |path, mode|
            local = path.sub(Fixtures::WORK_ROOT, work)
            assert_equal(mode.to_i(8), mode_of(local), "#{local} mode after restore")
            refute_includes File.read(local), "rewritten by an earlier row"
          end
          Fixtures::UNUSUAL_DIRS.each do |path, mode|
            assert_equal(mode.to_i(8), mode_of(path.sub(Fixtures::WORK_ROOT, work)), "#{path} mode after restore")
          end
          assert_equal(0o444, mode_of(File.join(work, "readonly", "dest.txt")))
          assert_equal(0o555, mode_of(File.join(work, "readonly")))
        end
      end
    end

    it "restores the unusual destinations as part of the ownership fix" do
      [UserProfile::Root, UserProfile::Nonroot].each do |profile|
        command = Fixtures.ownership_command(profile)
        assert_includes(command, Fixtures::RESTORE_UNUSUAL_SCRIPT)
        assert_includes(command, "chmod 0555 #{Fixtures::READONLY_DIR}")
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
