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
      "jinja"              => ChaosKind::Jinja,
    }

    property command : Command
    property modules : Array(String)?
    property? all_modules : Bool
    property? supported_community : Bool
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
    property? run_on_atlantic : Bool
    property? keep_going : Bool
    property? control : Bool
    property? json : Bool
    property? refresh_podman_templates : Bool
    property engine_timeout : Int32
    property min_happy_success : Float64?
    property tasks_per_playbook : Int32
    property? seed_given : Bool

    def initialize(@command, @modules = nil, @all_modules = false, @seed = 42, @count = 100,
                   @supported_community = false,
                   @chaos_percentage = 0.0, @chaos_kinds = %w[typo hallucinate wrong-type bad-choice violate-constraint jinja],
                   @out_dir = "playbooks/", @results_dir = "~/scratch/mfz-results",
                   @atlantic_hosts = 22, @ansible_playbook_bin = "ansible-playbook",
                   @krikri_bin = "/home/labros/git_work/krikri/bin/krikri-playbook",
                   @allow_mutation = false, @run_on_podman = false,
                   @run_on_atlantic = false,
                   @keep_going = false, @engine_timeout = 120, @control = false,
                   @json = false, @min_happy_success = nil, @refresh_podman_templates = false,
                   @tasks_per_playbook = 1, @seed_given = false)
    end

    def self.parse_chaos_kinds(values : Array(String)) : Array(ChaosKind)
      values.map do |value|
        CHAOS_KIND_LOOKUP[value]? || raise InvalidOptionsError.new(
          "unknown --chaos-kinds value #{value.inspect} (expected: #{CHAOS_KIND_LOOKUP.keys.join(", ")})")
      end
    end

    def self.parse(argv : Array(String)) : Options
      raise InvalidOptionsError.new("missing command (generate|run|report)") if argv.empty?

      command = parse_command(argv[0])

      opts = Options.new(command)
      rest = argv[1..]

      parser = OptionParser.new do |dsl|
        dsl.on("--modules LIST", "comma-separated module names") { |v| opts.modules = v.split(',') }
        dsl.on("--all-modules", "scan every installed module, collections included (default: ansible.builtin core only)") { opts.all_modules = true }
        dsl.on("--supported-community", "also scan the community modules chosen for support (data/module_dependencies.yml: supported)") { opts.supported_community = true }
        dsl.on("--seed N", "RNG seed (default: a fresh random seed, echoed in the log and in each playbook's first-line comment)") do |v|
          opts.seed = parse_int(v, "--seed")
          opts.seed_given = true
        end
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
        dsl.on("--run-on-atlantic", "run both engines on disposable Atlantic.net VMs, one per module profile (real mutation, no --check)") { opts.run_on_atlantic = true }
        dsl.on("--control", "noise check: run real ansible on both sides (podman only); every divergence is a missing mask or harness gap") { opts.control = true }
        dsl.on("--refresh-podman-templates", "ignore the podman template image cache and rebuild the templates from scratch") { opts.refresh_podman_templates = true }
        dsl.on("--keep-going", "keep running the remaining playbooks after one fails to run (recorded as an errored result)") { opts.keep_going = true }
        dsl.on("--engine-timeout N", "per-engine timeout in seconds; a hung engine is recorded with rc 124 (default: 120)") { |v| opts.engine_timeout = parse_int(v, "--engine-timeout") }
        dsl.on("--min-happy-success PCT", "exit 1 when the happy-path success rate is below PCT (report, or generate with a run backend)") { |v| opts.min_happy_success = parse_float(v, "--min-happy-success") }
        dsl.on("--json", "print the report as a single JSON object on stdout (report only)") { opts.json = true }
        dsl.on("--tasks-per-playbook N", "v2: build N-task playbooks from distinct modules with register/when chains, loops and handlers (default: 1, the single-task v1 shape)") { |v| opts.tasks_per_playbook = parse_int(v, "--tasks-per-playbook") }
      end
      parser.parse(rest)

      # A seedless generate gets a fresh random seed per invocation - the
      # playbook files themselves are the repro artifact (each one carries
      # the seed in its first-line comment), so determinism by default
      # would only replay stale coverage.
      opts.seed = random_seed unless opts.seed_given?

      opts.out_dir = expand_path(rest.first) if opts.command.run? && !rest.empty?
      opts.results_dir = expand_path(rest.first) if opts.command.report? && !rest.empty?
      opts.out_dir = expand_path(opts.out_dir)
      opts.results_dir = expand_path(opts.results_dir)

      check_conflicts!(opts)
      parse_chaos_kinds(opts.chaos_kinds)
      validate!(opts)

      opts
    end

    private def self.check_conflicts!(opts : Options) : Nil
      if opts.all_modules? && opts.modules
        raise InvalidOptionsError.new("--all-modules conflicts with --modules")
      end
      check_scope_conflicts!(opts)
      raise InvalidOptionsError.new("--run-on-podman and --run-on-atlantic are mutually exclusive") if opts.run_on_podman? && opts.run_on_atlantic?
      raise InvalidOptionsError.new("--control needs --run-on-podman") if opts.control? && !opts.run_on_podman?
      raise InvalidOptionsError.new("--refresh-podman-templates needs --run-on-podman") if opts.refresh_podman_templates? && !opts.run_on_podman?
      raise InvalidOptionsError.new("--json is only valid with the report command") if opts.json? && !opts.command.report?

      check_happy_gate_target!(opts)
    end

    private def self.check_scope_conflicts!(opts : Options) : Nil
      return unless opts.supported_community?

      raise InvalidOptionsError.new("--supported-community needs generate") unless opts.command.generate?
      raise InvalidOptionsError.new("--all-modules conflicts with --supported-community") if opts.all_modules?
      raise InvalidOptionsError.new("--supported-community conflicts with --modules") if opts.modules
    end

    private def self.check_happy_gate_target!(opts : Options) : Nil
      return unless opts.min_happy_success

      usable = opts.command.report? || (opts.command.generate? && (opts.run_on_podman? || opts.run_on_atlantic?))
      return if usable

      raise InvalidOptionsError.new("--min-happy-success needs a report, or a generate that runs a backend (--run-on-podman/--run-on-atlantic)")
    end

    private def self.random_seed : Int32
      Random.new.rand(1..1073741823)
    end

    private def self.parse_command(arg : String) : Command
      case arg
      when "generate" then Command::Generate
      when "run"      then Command::Run
      when "report"   then Command::Report
      else                 raise InvalidOptionsError.new("unknown command #{arg.inspect} (expected generate|run|report)")
      end
    end

    private def self.validate!(opts : Options) : Nil
      raise InvalidOptionsError.new("--seed must be zero or a positive integer, got #{opts.seed}") if opts.seed.negative?
      raise InvalidOptionsError.new("--count must be zero or a positive integer, got #{opts.count}") if opts.count.negative?
      raise InvalidOptionsError.new("--tasks-per-playbook must be a positive integer, got #{opts.tasks_per_playbook}") if opts.tasks_per_playbook < 1
      raise InvalidOptionsError.new("--engine-timeout must be a positive integer, got #{opts.engine_timeout}") if opts.engine_timeout <= 0
      unless opts.chaos_percentage.in?(0.0..100.0)
        raise InvalidOptionsError.new("--chaos-percentage must be between 0 and 100, got #{opts.chaos_percentage}")
      end
      if (threshold = opts.min_happy_success) && !threshold.in?(0.0..100.0)
        raise InvalidOptionsError.new("--min-happy-success must be between 0 and 100, got #{threshold}")
      end
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
