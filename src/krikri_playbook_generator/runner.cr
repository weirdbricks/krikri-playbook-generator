require "json"
require "./cmd"
require "./podman_backend"

module KrikriPlaybookGenerator
  # Executes each generated playbook against both engines and records the
  # outcome.
  #
  # Two backends, neither the default:
  #
  # - **Local** (the actual default: `run_on_podman: false`) — runs directly
  #   on this machine (`-i localhost, -c local`), `--check --diff` unless
  #   `--allow-mutation` is passed, since happy-path tasks are real
  #   modules that would otherwise install packages, create users, etc.
  #   on *this* machine.
  # - **Podman** (opt-in via `--run-on-podman`/`run_on_podman: true`, requires
  #   `podman` on PATH) — a pair of throwaway, `--privileged` podman
  #   containers (`PodmanBackend`), the same pattern krikri's own
  #   testing/podman-diff/run.sh already uses. Since those containers are
  #   disposable, happy-path tasks run for real there — faster to iterate
  #   with than spinning up real hosts, at the cost of the fixed, generic
  #   dependency set `PodmanBackend` installs (see its own doc comment) —
  #   real Atlantic.net hosts are still what a wide/production batch
  #   needs, not a replacement for them.
  #
  # `@atlantic_hosts` is accepted and stored for a possible future
  # remote/Atlantic.net backend but unused by either backend implemented
  # here.
  class Runner
    record Recap, ok : Int32, changed : Int32, unreachable : Int32, failed : Int32, skipped : Int32 do
      def self.parse(text : String) : Recap?
        counts = {} of String => Int32
        text.scan(/(ok|changed|unreachable|failed|skipped)=(\d+)/) { |match| counts[match[1]] = match[2].to_i }
        return unless %w[ok changed unreachable failed skipped].all? { |key| counts.has_key?(key) }

        Recap.new(counts["ok"], counts["changed"], counts["unreachable"], counts["failed"], counts["skipped"])
      end
    end

    record EngineRun, engine : String, rc : Int32, recap : Recap?, stdout : String, stderr : String

    record PlaybookResult, playbook : String, ansible : EngineRun, krikri : EngineRun do
      def divergent? : Bool
        ansible.recap != krikri.recap || (ansible.rc == 0) != (krikri.rc == 0)
      end
    end

    def initialize(@playbook_paths : Array(String), @results_dir : String, @atlantic_hosts : Int32 = 22,
                   @ansible_playbook_bin : String = "ansible-playbook",
                   @krikri_bin : String = "/home/labros/git_work/krikri/bin/krikri-playbook",
                   @check_mode : Bool = true, @run_on_podman : Bool = false)
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
      backend = PodmanBackend.new(@krikri_bin)
      backend.provision
      @playbook_paths.map do |path|
        outcome = backend.run_playbook(path)
        PlaybookResult.new(path, to_engine_run("ansible", outcome[:ansible]), to_engine_run("krikri", outcome[:krikri]))
      end
    ensure
      backend.try(&.teardown)
    end

    private def run_locally : Array(PlaybookResult)
      @playbook_paths.map { |path| run_playbook_locally(path) }
    end

    private def run_playbook_locally(path : String) : PlaybookResult
      PlaybookResult.new(path, run_engine_locally(path, "ansible", @ansible_playbook_bin),
        run_engine_locally(path, "krikri", @krikri_bin))
    end

    private def run_engine_locally(path : String, engine : String, bin : String) : EngineRun
      args = ["-i", "localhost,", "-c", "local"]
      args.concat(["--check", "--diff"]) if @check_mode
      args << path

      to_engine_run(engine, Cmd.run(bin, args))
    end

    private def to_engine_run(engine : String, result : Cmd::Result) : EngineRun
      EngineRun.new(engine, result.rc, Recap.parse(result.stdout), result.stdout, result.stderr)
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
          json.field "divergent", result.divergent?
          json.field "ansible" { engine_json(json, result.ansible) }
          json.field "krikri" { engine_json(json, result.krikri) }
        end
      end
    end

    private def engine_json(json : JSON::Builder, engine_run : EngineRun) : Nil
      json.object do
        json.field "rc", engine_run.rc
        if recap = engine_run.recap
          json.field "recap" do
            json.object do
              json.field "ok", recap.ok
              json.field "changed", recap.changed
              json.field "unreachable", recap.unreachable
              json.field "failed", recap.failed
              json.field "skipped", recap.skipped
            end
          end
        else
          json.field "recap", nil
        end
      end
    end
  end
end
