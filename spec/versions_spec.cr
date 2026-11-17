require "./spec_helper"
require "../src/krikri_playbook_generator/versions"
require "file_utils"

module KrikriPlaybookGenerator
  describe Versions do
    def fake_runner(handlers : Hash(String, Cmd::Result)) : Versions::CommandRunner
      Versions::CommandRunner.new do |command, args|
        handlers.fetch("#{command} #{args.join(" ")}") { Cmd::Result.new(1, "", "not found") }
      end
    end

    def make_binary(dir : String, mtime : Time? = nil) : String
      binary = File.join(dir, "checkout", "bin", "krikri-playbook")
      Dir.mkdir_p(File.dirname(binary))
      File.write(binary, "#!/bin/sh\n")
      File.touch(binary, mtime) if mtime
      binary
    end

    it "renders every key: value line in the triager's exact format" do
      dir = File.tempname("kpg-spec-versions")
      Dir.mkdir_p(dir)
      binary = make_binary(dir, Time.utc(2026, 1, 2, 3, 4, 5))
      checkout = File.join(dir, "checkout")
      ansible_output = "ansible-playbook [core 2.19.11]\n  config file = None\n"

      handlers = {
        "#{binary} --version"                                                                             => Cmd::Result.new(0, "krikri 1.2.3\n", ""),
        "git -C #{checkout} rev-parse HEAD"                                                               => Cmd::Result.new(0, "abc123def\n", ""),
        "git -C #{checkout} status --porcelain"                                                           => Cmd::Result.new(0, " M src/x.cr\n", ""),
        "git -C #{checkout} log -1 --format=%s"                                                           => Cmd::Result.new(0, "Add a thing\n", ""),
        "git -C #{checkout} log -1 --format=%cI -- src lib plugins scripts shard.yml shard.lock build.sh" => Cmd::Result.new(0, "2020-06-01T00:00:00+00:00\n", ""),
        "#{dir}/bin/ansible-playbook --version"                                                           => Cmd::Result.new(0, ansible_output, ""),
      }

      text = Versions.render(VERSION, Time.utc(2026, 2, 3, 4, 5, 6), binary,
        "#{dir}/bin/ansible-playbook", true, [RunMode::Check], true, true, 12.5.seconds, fake_runner(handlers))

      lines = text.lines
      assert_equal("tool: krikri-playbook-generator #{VERSION}", lines[0])
      assert_equal("started: 2026-02-03T04:05:06Z", lines[1])
      assert_equal("krikri binary: #{binary}", lines[2])
      assert_equal("krikri binary mtime: 2026-01-02T03:04:05Z", lines[3])
      assert_equal("krikri --version: krikri 1.2.3", lines[4])
      assert_equal("krikri commit: abc123def (dirty)", lines[5])
      assert_equal("krikri commit subject: Add a thing", lines[6])
      assert_equal("ansible-playbook: ansible-playbook [core 2.19.11] | config file = None", lines[7])
      assert_equal("control: true", lines[8])
      assert_equal("modes: check", lines[9])
      assert_equal("idempotency: true", lines[10])
      assert_equal("diff: true", lines[11])
      assert_equal("batch duration: 12.5s", lines[12])
      assert_equal("check: true", lines[13])
      assert_equal(14, lines.size)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "records the host-count matrix next to the identity and umask axes" do
      dir = File.tempname("kpg-spec-versions")
      Dir.mkdir_p(dir)
      binary = make_binary(dir)

      text = Versions.render(VERSION, Time.utc(2026, 2, 3, 4, 5, 6), binary,
        "#{dir}/bin/ansible-playbook", false, [RunMode::Check], false, true, 1.5.seconds,
        fake_runner({} of String => Cmd::Result), user_profiles: ["root"], umasks: ["022"],
        hosts: [1, 2], limits: ["one"])

      assert(text.lines.includes?("user-profiles: root"))
      assert(text.lines.includes?("umasks: 022"))
      assert(text.lines.includes?("hosts: 1,2"))
      assert(text.lines.includes?("limits: one"))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "writes versions.txt identical to the rendered text" do
      dir = File.tempname("kpg-spec-versions")
      Dir.mkdir_p(dir)
      binary = make_binary(dir)

      Versions.write(dir, "9.9.9", binary, "ansible-playbook", false, [RunMode::Check], false, false,
        3.seconds, Time.utc(2026, 1, 1), fake_runner({} of String => Cmd::Result))

      text = File.read(File.join(dir, "versions.txt"))
      assert(text.ends_with?("\n"))
      assert_equal("tool: krikri-playbook-generator 9.9.9", text.lines.first)
      assert(text.lines.includes?("control: false"))
      assert(text.lines.includes?("modes: check"))
      assert(text.lines.includes?("idempotency: false"))
      assert(text.lines.includes?("batch duration: 3.0s"))
      assert_equal("check: true", text.lines.last)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "falls back to unavailable when every probe fails" do
      dir = File.tempname("kpg-spec-versions")
      Dir.mkdir_p(dir)
      binary = File.join(dir, "missing", "bin", "krikri-playbook")

      text = Versions.render(VERSION, Time.utc(2026, 2, 3, 4, 5, 6), binary,
        "ansible-playbook", false, [RunMode::Check], false, true, 0.seconds,
        fake_runner({} of String => Cmd::Result))

      lines = text.lines
      assert_equal("krikri binary mtime: unavailable", lines[3])
      assert_equal("krikri --version: unavailable", lines[4])
      assert_equal("krikri commit: unavailable", lines[5])
      assert_equal("krikri commit subject: unavailable", lines[6])
      assert_equal("ansible-playbook: unavailable", lines[7])
      refute(lines.any?(&.includes?("binary is older than")))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "never raises when a probe itself raises" do
      dir = File.tempname("kpg-spec-versions")
      Dir.mkdir_p(dir)
      binary = make_binary(dir)
      exploding = Versions::CommandRunner.new { |_command, _args| raise "boom" }

      text = Versions.render(VERSION, Time.utc(2026, 2, 3, 4, 5, 6), binary,
        "ansible-playbook", false, [RunMode::Check], false, true, 0.seconds, exploding)

      assert_equal("krikri commit: unavailable", text.lines[5])
      assert_equal("ansible-playbook: unavailable", text.lines[7])
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "flattens probe output dropping blank lines and stripping each line" do
      dir = File.tempname("kpg-spec-versions")
      Dir.mkdir_p(dir)
      binary = make_binary(dir)
      checkout = File.join(dir, "checkout")
      handlers = {
        "#{binary} --version"                   => Cmd::Result.new(0, "krikri 4.5.6\n\n  build: xyz \n", ""),
        "git -C #{checkout} rev-parse HEAD"     => Cmd::Result.new(0, "abc123def\n", ""),
        "git -C #{checkout} status --porcelain" => Cmd::Result.new(0, "", ""),
      }

      text = Versions.render(VERSION, Time.utc(2026, 2, 3, 4, 5, 6), binary,
        "ansible-playbook", false, [RunMode::Check], false, true, 0.seconds,
        fake_runner(handlers))

      assert_equal("krikri --version: krikri 4.5.6 | build: xyz", text.lines[4])
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "warns when the binary is older than the last build-input commit" do
      dir = File.tempname("kpg-spec-versions")
      Dir.mkdir_p(dir)
      binary = make_binary(dir, Time.utc(2026, 1, 1, 0, 0, 0))
      checkout = File.join(dir, "checkout")
      handlers = {
        "git -C #{checkout} log -1 --format=%cI -- src lib plugins scripts shard.yml shard.lock build.sh" => Cmd::Result.new(0, "2026-06-01T00:00:00+00:00\n", ""),
        "git -C #{checkout} status --porcelain"                                                           => Cmd::Result.new(0, "", ""),
      }

      text = Versions.render(VERSION, Time.utc(2026, 2, 3, 4, 5, 6), binary,
        "ansible-playbook", false, [RunMode::Check], false, true, 0.seconds,
        fake_runner(handlers))

      assert_equal(Versions::STALE_WARNING, text.lines.last)
      assert_equal("krikri commit: unavailable", text.lines[5])
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "does not warn when the binary is newer than the last build-input commit" do
      dir = File.tempname("kpg-spec-versions")
      Dir.mkdir_p(dir)
      binary = make_binary(dir, Time.utc(2026, 12, 1, 0, 0, 0))
      checkout = File.join(dir, "checkout")
      handlers = {
        "git -C #{checkout} log -1 --format=%cI -- src lib plugins scripts shard.yml shard.lock build.sh" => Cmd::Result.new(0, "2026-06-01T00:00:00+00:00\n", ""),
      }

      text = Versions.render(VERSION, Time.utc(2026, 2, 3, 4, 5, 6), binary,
        "ansible-playbook", false, [RunMode::Check], false, true, 0.seconds,
        fake_runner(handlers))

      refute(text.includes?("binary is older than"))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "records the reference core versions the batch compared against" do
      dir = File.tempname("kpg-spec-versions")
      Dir.mkdir_p(dir)
      binary = make_binary(dir, Time.utc(2026, 1, 2, 3, 4, 5))

      text = Versions.render(VERSION, Time.utc(2026, 2, 3, 4, 5, 6), binary,
        "ansible-playbook", false, [RunMode::Real], false, true, 0.seconds,
        fake_runner({} of String => Cmd::Result), reference_versions: %w[2.21.6 2.20.1])

      assert(text.lines.includes?("reference cores: 2.21.6,2.20.1"))
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end
