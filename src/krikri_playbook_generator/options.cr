require "option_parser"

module KrikriPlaybookGenerator
  class InvalidOptionsError < Exception
  end

  enum Command
    Generate
    Run
    Report
  end

  class Options
    property command : Command
    property modules : Array(String)?
    property seed : Int32
    property count : Int32
    property chaos_percentage : Float64
    property chaos_kinds : Array(String)
    property out_dir : String
    property results_dir : String
    property atlantic_hosts : Int32
    property ansible_playbook_bin : String
    property krikri_bin : String
    property? allow_mutation : Bool

    def initialize(@command, @modules = nil, @seed = 42, @count = 100,
                   @chaos_percentage = 0.0, @chaos_kinds = %w[typo hallucinate wrong-type bad-choice violate-constraint],
                   @out_dir = "playbooks/", @results_dir = "~/scratch/mfz-results",
                   @atlantic_hosts = 22, @ansible_playbook_bin = "ansible-playbook",
                   @krikri_bin = "/home/labros/git_work/krikri/bin/krikri-playbook",
                   @allow_mutation = false)
    end

    def self.parse(argv : Array(String)) : Options
      raise InvalidOptionsError.new("missing command (generate|run|report)") if argv.empty?

      command = case argv[0]
                when "generate" then Command::Generate
                when "run"      then Command::Run
                when "report"   then Command::Report
                else
                  raise InvalidOptionsError.new("unknown command #{argv[0].inspect} (expected generate|run|report)")
                end

      opts = Options.new(command)
      rest = argv[1..]

      parser = OptionParser.new do |dsl|
        dsl.on("--modules LIST", "comma-separated module names") { |v| opts.modules = v.split(',') }
        dsl.on("--seed N", "RNG seed") { |v| opts.seed = v.to_i }
        dsl.on("--count N", "generated tasks per module") { |v| opts.count = v.to_i }
        dsl.on("--chaos-percentage N", "per-option-slot chaos mutation probability") { |v| opts.chaos_percentage = v.to_f }
        dsl.on("--chaos-kinds LIST", "comma-separated chaos kinds") { |v| opts.chaos_kinds = v.split(',') }
        dsl.on("--out DIR", "playbook output dir") { |v| opts.out_dir = v }
        dsl.on("--results-dir DIR", "results output dir") { |v| opts.results_dir = v }
        dsl.on("--atlantic-hosts N", "max concurrent Atlantic.net hosts") { |v| opts.atlantic_hosts = v.to_i }
        dsl.on("--ansible-playbook-bin PATH", "ansible-playbook executable (default: on PATH)") { |v| opts.ansible_playbook_bin = v }
        dsl.on("--krikri-bin PATH", "path to the krikri-playbook binary") { |v| opts.krikri_bin = v }
        dsl.on("--allow-mutation", "run without --check: real modules may actually change the local host") { opts.allow_mutation = true }
      end
      parser.parse(rest)

      opts.out_dir = rest.first if opts.command.run? && !rest.empty?

      opts
    end
  end
end
