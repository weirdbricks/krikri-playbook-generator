require "json"
require "./cmd"
require "./podman_backend"
require "./masks"
require "./fixtures"

module KrikriPlaybookGenerator
  # Executes each generated playbook against both engines and records the
  # outcome.
  #
  # The comparison is BYTE-FOR-BYTE on the podman path (the reliable
  # differential mode): both engines run the identical invocation - same
  # absolute playbook path and cwd inside the container, ANSIBLE_NOCOLOR=1,
  # caching/gathering env vars stripped, stdin </dev/null, per-engine
  # `timeout` (a hang is its own result, rc 124) - inside a FRESH container
  # pair per playbook, so no state leaks between playbooks. Raw stdout,
  # stderr and rc are captured from both engines; divergence is judged
  # after applying ByteDiff::MASKS (the single, explicitly justified mask
  # list) to both sides. The old PLAY RECAP counter comparison is kept as
  # an extra `recap_divergent` field.
  #
  # Two backends:
  #
  # - **Local** (`run_on_podman: false`, the default) - runs directly on
  #   this machine (`-i localhost, -c local`), `--check --diff` unless
  #   `--allow-mutation` is passed, since happy-path tasks are real modules
  #   that would otherwise install packages, create users, etc. on *this*
  #   machine. Byte parity here is best-effort: the two engines run
  #   sequentially on the same (non-fresh) host, so state can legitimately
  #   differ between them.
  # - **Podman** (opt-in via `--run-on-podman`, requires `podman` on PATH)
  #   - `PodmanBackend`, which is where byte-parity claims actually hold.
  #
  # With `keep_going: true` a per-playbook failure (e.g. a podman error
  # mid-batch) is recorded as an errored result and the batch continues;
  # with it false (the default) the error aborts the run.
  #
  # `@atlantic_hosts` is accepted and stored for a possible future
  # remote/Atlantic.net backend but unused by either backend implemented
  # here.
  class Runner
    record Recap, ok : Int32, changed : Int32, unreachable : Int32, failed : Int32,
      skipped : Int32, ignored : Int32 do
      def self.parse(text : String) : Recap?
        # Only the PLAY RECAP section carries the real counters; task
        # output above it can contain incidental ok=N-shaped text that
        # would otherwise corrupt the parse (last match wins per key).
        lines = text.lines
        recap_index = lines.index(&.starts_with?("PLAY RECAP"))
        return unless recap_index

        counts = {} of String => Int32
        lines[(recap_index + 1)..].join('\n').scan(/(ok|changed|unreachable|failed|skipped|ignored)=(\d+)/) { |match| counts[match[1]] = match[2].to_i }
        return unless %w[ok changed unreachable failed skipped ignored].all? { |key| counts.has_key?(key) }

        Recap.new(counts["ok"], counts["changed"], counts["unreachable"], counts["failed"], counts["skipped"], counts["ignored"])
      end
    end

    record EngineRun, engine : String, rc : Int32, recap : Recap?, stdout : String, stderr : String,
      timed_out : Bool = false

    record MetaInfo, module_name : String, chaos : Bool, mutations : Array({String, String})

    class PlaybookResult
      getter playbook : String
      getter ansible : EngineRun
      getter krikri : EngineRun
      getter meta : MetaInfo?
      getter error : String?

      def initialize(@playbook, @ansible, @krikri, @meta, @error = nil)
      end

      def self.errored(playbook : String, meta : MetaInfo?, message : String) : PlaybookResult
        failed = EngineRun.new("ansible", -1, nil, "", "", false)
        PlaybookResult.new(playbook, failed, failed, meta, message)
      end

      def raw_identical? : Bool
        return false if @error
        same_exit? && ansible.stdout == krikri.stdout && ansible.stderr == krikri.stderr
      end

      # The primary byte-parity verdict: identical only when rc, timeout
      # state and masked stdout/stderr all match.
      def masked_identical? : Bool
        return false if @error
        same_exit? &&
          ByteDiff.mask(ansible.stdout) == ByteDiff.mask(krikri.stdout) &&
          ByteDiff.mask(ansible.stderr) == ByteDiff.mask(krikri.stderr)
      end

      def divergent? : Bool
        return false if @error

        !masked_identical?
      end

      # The old counter-only comparison, kept as an extra results field.
      def recap_divergent? : Bool
        return false if @error

        a = ansible.recap
        k = krikri.recap
        return true if a.nil? != k.nil?
        return false if a.nil?

        a != k
      end

      def signature : String?
        return if @error

        ByteDiff.signature(masked_diff)
      end

      def masked_diff : String
        stream_diffs(true)
      end

      def raw_diff : String
        stream_diffs(false)
      end

      # True when the REAL ansible engine failed (a happy-path playbook
      # that failed on the reference engine is wasted coverage, not a
      # divergence candidate). ignore_errors keeps rc at 0 and moves the
      # count to `ignored`, so all three signals matter.
      def ansible_failed? : Bool
        return false if @error

        ansible.rc != 0 || ansible.timed_out ||
          (ansible.recap.try(&.ignored) || 0) > 0 ||
          ansible.stdout.includes?("fatal:") || ansible.stderr.includes?("fatal:")
      end

      def ansible_error_line : String?
        return unless ansible_failed?

        text = ansible.stdout + '\n' + ansible.stderr
        line = text.lines.find { |candidate| candidate =~ /fatal:|FAILED|ERROR!|error:/i }
        candidate = line || text.lines.find { |candidate| !candidate.blank? }
        return unless candidate

        candidate.size > 200 ? candidate[0, 200] : candidate
      end

      private def same_exit? : Bool
        ansible.rc == krikri.rc && ansible.timed_out == krikri.timed_out
      end

      private def stream_diffs(masked : Bool) : String
        a_stdout = masked ? ByteDiff.mask(ansible.stdout) : ansible.stdout
        k_stdout = masked ? ByteDiff.mask(krikri.stdout) : krikri.stdout
        a_stderr = masked ? ByteDiff.mask(ansible.stderr) : ansible.stderr
        k_stderr = masked ? ByteDiff.mask(krikri.stderr) : krikri.stderr

        String.build do |str|
          str << "stdout:\n"
          str << ByteDiff.unified(a_stdout, k_stdout)
          str << "stderr:\n"
          str << ByteDiff.unified(a_stderr, k_stderr)
        end
      end
    end

    def initialize(@playbook_paths : Array(String), @results_dir : String, @atlantic_hosts : Int32 = 22,
                   @ansible_playbook_bin : String = "ansible-playbook",
                   @krikri_bin : String = "/home/labros/git_work/krikri/bin/krikri-playbook",
                   @check_mode : Bool = true, @run_on_podman : Bool = false,
                   @keep_going : Bool = false, @engine_timeout : Int32 = 120)
    end

    def run : Array(PlaybookResult)
      if @run_on_podman && !PodmanBackend.available?
        raise PodmanProvisionError.new("--run-on-podman was requested but `podman` isn't on PATH")
      end

      Dir.mkdir_p(@results_dir)
      results = @run_on_podman ? run_via_podman : run_locally
      write_results(results)
      results
    end

    private def run_via_podman : Array(PlaybookResult)
      backend = PodmanBackend.new(@krikri_bin, @engine_timeout)
      begin
        backend.provision
        @playbook_paths.map { |path| guarded(path) { run_playbook_via_podman(backend, path) } }
      ensure
        backend.teardown
        report_leaks
      end
    end

    private def run_playbook_via_podman(backend : PodmanBackend, path : String) : PlaybookResult
      outcome = backend.run_playbook(path)
      PlaybookResult.new(path, to_engine_run("ansible", outcome[:ansible]),
        to_engine_run("krikri", outcome[:krikri]), load_meta(path))
    end

    private def run_locally : Array(PlaybookResult)
      Fixtures.seed_local
      @playbook_paths.map { |path| guarded(path) { run_playbook_locally(path) } }
    end

    private def run_playbook_locally(path : String) : PlaybookResult
      PlaybookResult.new(path, run_engine_locally(path, "ansible", @ansible_playbook_bin),
        run_engine_locally(path, "krikri", @krikri_bin), load_meta(path))
    end

    private def run_engine_locally(path : String, engine : String, bin : String) : EngineRun
      args = [@engine_timeout.to_s, bin, "-i", "localhost,", "-c", "local"]
      args.concat(["--check", "--diff"]) if @check_mode
      args << path

      to_engine_run(engine, Cmd.run("timeout", args, timeout: @engine_timeout + 30.0))
    end

    private def to_engine_run(engine : String, result : Cmd::Result) : EngineRun
      timed_out = result.timed_out || result.rc == Cmd::TIMEOUT_RC
      EngineRun.new(engine, result.rc, Recap.parse(result.stdout), result.stdout, result.stderr, timed_out)
    end

    private def guarded(path : String, &block : -> PlaybookResult) : PlaybookResult
      block.call
    rescue e : Exception
      raise e unless @keep_going

      STDERR.puts "warning: #{File.basename(path)}: #{e.message} - continuing (--keep-going)"
      PlaybookResult.errored(path, load_meta(path), e.message || e.class.to_s)
    end

    private def report_leaks : Nil
      leaks = PodmanBackend.leak_check
      STDERR.puts "ERROR: leaked containers after teardown: #{leaks.join(", ")}" unless leaks.empty?
    end

    private def load_meta(path : String) : MetaInfo?
      meta_path = path.sub(/\.yml$/, ".meta.json")
      return parse_meta(File.read(meta_path)) if File.exists?(meta_path)

      # fall back to the batch naming convention when no sidecar exists
      match = File.basename(path).match(/\A\d{6}-(.+)-(happy|chaos)\.yml\z/)
      match.try { |filename_match| MetaInfo.new(filename_match[1], filename_match[2] == "chaos", [] of {String, String}) }
    end

    private def parse_meta(text : String) : MetaInfo?
      parsed = JSON.parse(text).as_h?
      return unless parsed

      module_name = parsed["module"]?.try(&.as_s?)
      return unless module_name

      chaos = parsed["chaos"]?.try(&.as_bool?) || false
      mutations = parsed["mutations"]?.try(&.as_a?).try do |entries|
        entries.compact_map do |entry|
          entry_hash = entry.as_h?
          next unless entry_hash

          option = entry_hash["option"]?.try(&.as_s?)
          kind = entry_hash["kind"]?.try(&.as_s?)
          {option, kind} if option && kind
        end
      end || [] of {String, String}

      MetaInfo.new(module_name, chaos, mutations)
    rescue JSON::ParseException
      nil
    end

    private def write_results(results : Array(PlaybookResult)) : Nil
      File.open(File.join(@results_dir, "results.jsonl"), "w") do |file|
        results.each { |result| file.puts(result_json(result)) }
      end
    end

    private def result_json(result : PlaybookResult) : String
      JSON.build do |json|
        json.object do
          json.field "playbook", result.playbook
          write_meta_fields(json, result)
          json.field "error", result.error
          json.field "divergent", result.divergent?
          json.field "masked_identical", result.masked_identical?
          json.field "raw_identical", result.raw_identical?
          json.field "recap_divergent", result.recap_divergent?
          json.field "signature", result.signature
          json.field "ansible_failed", result.ansible_failed?
          json.field "ansible_error", result.ansible_error_line
          json.field "diff" do
            json.object do
              json.field "masked", result.masked_diff
              json.field "raw", result.raw_diff
            end
          end
          json.field "ansible" { engine_json(json, result.ansible) }
          json.field "krikri" { engine_json(json, result.krikri) }
        end
      end
    end

    private def write_meta_fields(json : JSON::Builder, result : PlaybookResult) : Nil
      meta = result.meta
      if meta
        json.field "module", meta.module_name
        json.field "chaos", meta.chaos
        json.field "mutations" do
          json.array do
            meta.mutations.each do |(option, kind)|
              json.object do
                json.field "option", option
                json.field "kind", kind
              end
            end
          end
        end
      else
        json.field "module", nil
        json.field "chaos", nil
        json.field "mutations", nil
      end
    end

    private def engine_json(json : JSON::Builder, engine_run : EngineRun) : Nil
      json.object do
        json.field "rc", engine_run.rc
        json.field "timed_out", engine_run.timed_out
        if recap = engine_run.recap
          json.field "recap" do
            json.object do
              json.field "ok", recap.ok
              json.field "changed", recap.changed
              json.field "unreachable", recap.unreachable
              json.field "failed", recap.failed
              json.field "skipped", recap.skipped
              json.field "ignored", recap.ignored
            end
          end
        else
          json.field "recap", nil
        end
        json.field "stdout", engine_run.stdout
        json.field "stderr", engine_run.stderr
      end
    end
  end
end
