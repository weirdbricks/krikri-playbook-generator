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
    CHAOS_KIND_LOOKUP = {
      "typo"               => ChaosKind::Typo,
      "hallucinate"        => ChaosKind::Hallucinate,
      "wrong-type"         => ChaosKind::WrongType,
      "bad-choice"         => ChaosKind::BadChoice,
      "violate-constraint" => ChaosKind::ViolateConstraint,
    }

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
    property? run_on_podman : Bool

    def initialize(@command, @modules = nil, @seed = 42, @count = 100,
                   @chaos_percentage = 0.0, @chaos_kinds = %w[typo hallucinate wrong-type bad-choice violate-constraint],
                   @out_dir = "playbooks/", @results_dir = "~/scratch/mfz-results",
                   @atlantic_hosts = 22, @ansible_playbook_bin = "ansible-playbook",
                   @krikri_bin = "/home/labros/git_work/krikri/bin/krikri-playbook",
                   @allow_mutation = false, @run_on_podman = false)
    end

    def self.parse_chaos_kinds(values : Array(String)) : Array(ChaosKind)
      values.map do |value|
        CHAOS_KIND_LOOKUP[value]? || raise InvalidOptionsError.new(
          "unknown --chaos-kinds value #{value.inspect} (expected: #{CHAOS_KIND_LOOKUP.keys.join(", ")})")
      end
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
        dsl.on("--seed N", "RNG seed") { |v| opts.seed = parse_int(v, "--seed") }
        dsl.on("--count N", "generated tasks per module") { |v| opts.count = parse_int(v, "--count") }
        dsl.on("--chaos-percentage N", "per-option-slot chaos mutation probability") { |v| opts.chaos_percentage = parse_float(v, "--chaos-percentage") }
        dsl.on("--chaos-kinds LIST", "comma-separated chaos kinds") { |v| opts.chaos_kinds = v.split(',') }
        dsl.on("--out DIR", "playbook output dir") { |v| opts.out_dir = expand_path(v) }
        dsl.on("--results-dir DIR", "results output dir") { |v| opts.results_dir = expand_path(v) }
        dsl.on("--atlantic-hosts N", "max concurrent Atlantic.net hosts") { |v| opts.atlantic_hosts = parse_int(v, "--atlantic-hosts") }
        dsl.on("--ansible-playbook-bin PATH", "ansible-playbook executable (default: on PATH)") { |v| opts.ansible_playbook_bin = expand_tilde(v) }
        dsl.on("--krikri-bin PATH", "path to the krikri-playbook binary") { |v| opts.krikri_bin = expand_tilde(v) }
        dsl.on("--allow-mutation", "run without --check: real modules may actually change the local host") { opts.allow_mutation = true }
        dsl.on("--run-on-podman", "run both engines inside throwaway podman containers instead of locally (requires podman)") { opts.run_on_podman = true }
      end
      parser.parse(rest)

      opts.out_dir = expand_path(rest.first) if opts.command.run? && !rest.empty?
      opts.results_dir = expand_path(rest.first) if opts.command.report? && !rest.empty?
      opts.out_dir = expand_path(opts.out_dir)
      opts.results_dir = expand_path(opts.results_dir)

      parse_chaos_kinds(opts.chaos_kinds)

      raise InvalidOptionsError.new("--seed must be zero or a positive integer, got #{opts.seed}") if opts.seed.negative?
      raise InvalidOptionsError.new("--count must be zero or a positive integer, got #{opts.count}") if opts.count.negative?
      unless opts.chaos_percentage.in?(0.0..100.0)
        raise InvalidOptionsError.new("--chaos-percentage must be between 0 and 100, got #{opts.chaos_percentage}")
      end

      opts
    end

    private def self.parse_int(value : String, flag : String) : Int32
      parsed = value.to_i?
      parsed || raise InvalidOptionsError.new("#{flag} expects an integer, got #{value.inspect}")
    end

    private def self.parse_float(value : String, flag : String) : Float64
      parsed = value.to_f?
      parsed || raise InvalidOptionsError.new("#{flag} expects a number, got #{value.inspect}")
    end

    # File.expand_path doesn't expand a leading ~, but Path#expand(home:)
    # does - and it also anchors relative paths to the current directory,
    # so a value like ~/scratch/kpg-results can't end up as a literal
    # ./~/scratch directory under the CWD.
    private def self.expand_path(value : String) : String
      Path[value].expand(home: true).to_s
    end

    # Binaries keep their bare form ("ansible-playbook") so PATH lookup
    # still works; only a ~-leading path is expanded.
    private def self.expand_tilde(value : String) : String
      value.starts_with?("~") ? expand_path(value) : value
    end
  end
end
