require "./cmd"
require "./version"

module KrikriPlaybookGenerator
  # Best-effort provenance record (versions.txt) written next to every
  # results.jsonl so krikri-role-triager can attribute a results dir to an
  # exact tool/binary/checkout state. The triager splits each line on the
  # first ": " - the format below is part of that contract.
  #
  # Every probe is individually best-effort ("unavailable" on failure, 30s
  # timeout) and the whole write must never fail a run; Runner wraps the
  # call in its own rescue as a second belt.
  module Versions
    PROBE_TIMEOUT = 30.0
    UNAVAILABLE   = "unavailable"
    BUILD_INPUTS  = %w[src lib plugins scripts shard.yml shard.lock build.sh]

    STALE_WARNING =
      "warning: krikri binary is older than its checkout's last build-input commit"

    alias CommandRunner = Proc(String, Array(String), Cmd::Result)

    DEFAULT_RUNNER = CommandRunner.new do |command, args|
      Cmd.run(command, args, timeout: PROBE_TIMEOUT)
    end

    def self.write(results_dir : String, version : String, krikri_bin : String,
                   ansible_playbook_bin : String, control : Bool, started : Time,
                   runner : CommandRunner = DEFAULT_RUNNER) : Nil
      File.write(File.join(results_dir, "versions.txt"),
        render(version, started, krikri_bin, ansible_playbook_bin, control, runner))
    end

    def self.render(version : String, started : Time, krikri_bin : String,
                    ansible_playbook_bin : String, control : Bool,
                    runner : CommandRunner) : String
      binary = Path[krikri_bin].expand(home: true).to_s
      checkout = File.dirname(File.dirname(binary))
      subject_args = ["-C", checkout, "log", "-1", "--format=%s"]

      lines = [
        "tool: krikri-playbook-generator #{version}",
        "started: #{started.to_rfc3339}",
        "krikri binary: #{binary}",
        "krikri binary mtime: #{format_mtime(binary)}",
        "krikri --version: #{flattened(runner, binary, ["--version"])}",
        "krikri commit: #{krikri_commit(runner, checkout)}",
        "krikri commit subject: #{flattened(runner, "git", subject_args)}",
        "ansible-playbook: #{flattened(runner, ansible_playbook_bin, ["--version"])}",
        "control: #{control}",
      ]

      lines << STALE_WARNING if stale?(binary, checkout, runner)
      lines.join("\n") + "\n"
    end

    private def self.format_mtime(binary : String) : String
      mtime = File.info?(binary).try(&.modification_time)
      mtime ? mtime.to_rfc3339 : UNAVAILABLE
    end

    private def self.krikri_commit(runner : CommandRunner, checkout : String) : String
      commit = flattened(runner, "git", ["-C", checkout, "rev-parse", "HEAD"])
      return UNAVAILABLE if commit == UNAVAILABLE

      status = probe(runner, "git", ["-C", checkout, "status", "--porcelain"])
      dirty = status ? !status.strip.empty? : false
      dirty ? "#{commit} (dirty)" : commit
    end

    private def self.stale?(binary : String, checkout : String, runner : CommandRunner) : Bool
      mtime = File.info?(binary).try(&.modification_time)
      return false unless mtime

      date = probe(runner, "git",
        ["-C", checkout, "log", "-1", "--format=%cI", "--"] + BUILD_INPUTS)
      return false unless date

      commit_time = Time.parse_rfc3339(date.strip)
      mtime < commit_time
    rescue
      false
    end

    private def self.flattened(runner : CommandRunner, command : String, args : Array(String)) : String
      text = probe(runner, command, args)
      text ? text.strip.lines.reject(&.blank?).map(&.strip).join(" | ") : UNAVAILABLE
    end

    private def self.probe(runner : CommandRunner, command : String, args : Array(String)) : String?
      result = runner.call(command, args)
      result.rc.zero? ? result.stdout : nil
    rescue
      nil
    end
  end
end
