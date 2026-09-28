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

    def initialize(@command, @modules = nil, @seed = 42, @count = 100,
                    @chaos_percentage = 0.0, @chaos_kinds = %w[typo hallucinate wrong-type bad-choice violate-constraint],
                    @out_dir = "playbooks/", @results_dir = "~/scratch/mfz-results",
                    @atlantic_hosts = 22)
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

      parser = OptionParser.new do |p|
        p.on("--modules LIST", "comma-separated module names") { |v| opts.modules = v.split(',') }
        p.on("--seed N", "RNG seed") { |v| opts.seed = v.to_i }
        p.on("--count N", "generated tasks per module") { |v| opts.count = v.to_i }
        p.on("--chaos-percentage N", "per-option-slot chaos mutation probability") { |v| opts.chaos_percentage = v.to_f }
        p.on("--chaos-kinds LIST", "comma-separated chaos kinds") { |v| opts.chaos_kinds = v.split(',') }
        p.on("--out DIR", "playbook output dir") { |v| opts.out_dir = v }
        p.on("--results-dir DIR", "results output dir") { |v| opts.results_dir = v }
        p.on("--atlantic-hosts N", "max concurrent Atlantic.net hosts") { |v| opts.atlantic_hosts = v.to_i }
      end
      parser.parse(rest)

      opts
    end
  end
end
