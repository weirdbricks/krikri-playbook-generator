require "./cmd"
require "./run_mode"
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
                   ansible_playbook_bin : String, control : Bool, modes : Array(RunMode),
                   second_run : Bool, diff : Bool, duration : Time::Span, started : Time,
                   runner : CommandRunner = DEFAULT_RUNNER,
                   user_profiles : Array(String)? = nil, umasks : Array(String)? = nil,
                   hosts : Array(Int32)? = nil, limits : Array(String)? = nil) : Nil
      File.write(File.join(results_dir, "versions.txt"),
        render(version, started, krikri_bin, ansible_playbook_bin, control, modes, second_run, diff,
          duration, runner, user_profiles: user_profiles, umasks: umasks, hosts: hosts, limits: limits))
    end

    def self.render(version : String, started : Time, krikri_bin : String,
                    ansible_playbook_bin : String, control : Bool, modes : Array(RunMode),
                    second_run : Bool, diff : Bool, duration : Time::Span,
                    runner : CommandRunner, user_profiles : Array(String)? = nil,
                    umasks : Array(String)? = nil, hosts : Array(Int32)? = nil,
                    limits : Array(String)? = nil) : String
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
        "modes: #{modes.map(&.label).join(",")}",
        "idempotency: #{second_run}",
        "diff: #{diff}",
        "batch duration: #{duration.total_seconds.round(1)}s",
      ]

      # The identity/umask matrix, so a repro can pin both; omitted for a
      # legacy call that predates the axes.
      lines.insert(10, "user-profiles: #{user_profiles.join(",")}") if user_profiles
      lines.insert(11, "umasks: #{umasks.join(",")}") if umasks
      lines.insert(12, "hosts: #{hosts.join(",")}") if hosts
      lines.insert(13, "limits: #{limits.join(",")}") if limits

      # krikri-role-triager uses "check: true" to tell a check-mode repro
      # from a real one; a mixed-mode batch is not a check run.
      lines << "check: true" if modes == [RunMode::Check]
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
