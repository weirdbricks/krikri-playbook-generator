require "json"
require "./cmd"

module KrikriPlaybookGenerator
  # Executes each generated playbook against both engines locally
  # (ansible_connection=local) and records the outcome.
  #
  # Defaults to `--check --diff`: happy-path tasks can genuinely mutate a
  # real host (install packages, create users, ...), and this repo has no
  # host-provisioning story of its own — krikri-role-tester's Atlantic.net
  # backend exists exactly to run mutating batches safely against
  # disposable hosts, which is where `--atlantic-hosts` is heading, but
  # reusing that (Galaxy-role-shaped) machinery for raw generated
  # playbooks is real cross-repo work, not done here; `@atlantic_hosts` is
  # accepted and stored for that future wiring but unused by this local
  # runner. Chaos-mode tasks are mostly safe regardless — they fail
  # argument validation before doing anything real — but happy-path tasks
  # are not, hence check mode by default. `--allow-mutation` opts out.
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
                   @check_mode : Bool = true)
    end

    def run : Array(PlaybookResult)
      Dir.mkdir_p(@results_dir)
      results = @playbook_paths.map { |path| run_playbook(path) }
      write_results(results)
      results
    end

    private def run_playbook(path : String) : PlaybookResult
      PlaybookResult.new(path, run_engine(path, "ansible", @ansible_playbook_bin), run_engine(path, "krikri", @krikri_bin))
    end

    private def run_engine(path : String, engine : String, bin : String) : EngineRun
      args = ["-i", "localhost,", "-c", "local"]
      args.concat(["--check", "--diff"]) if @check_mode
      args << path

      result = Cmd.run(bin, args)
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
