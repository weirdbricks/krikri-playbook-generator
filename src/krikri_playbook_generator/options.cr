require "option_parser"
require "./run_mode"
require "./run_context"
require "./play_keywords"
require "./block_shapes"
require "./handler_shapes"
require "./retry_shapes"
require "./include_shapes"

module KrikriPlaybookGenerator
  class InvalidOptionsError < Exception
  end

  enum Command
    Generate
    Run
    Report
    Modules
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
    property? scope_from_krikri : Bool
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
    property? check : Bool
    property? run_on_podman : Bool
    property? run_on_atlantic : Bool
    property? run_on_microvm : Bool
    property? run_on_mixed : Bool
    property? keep_going : Bool
    property? control : Bool
    property? json : Bool
    property? refresh_podman_templates : Bool
    property podman_parallel : Int32
    property microvm_parallel : Int32
    property microvm_dir : String
    property engine_timeout : Int32
    property min_happy_success : Float64?
    property tasks_per_playbook : Int32
    property play_keywords : Array(String)
    property? play_keywords_given : Bool
    property delegation : DelegationMode
    property? delegation_given : Bool
    property blocks : Array(String)
    property? blocks_given : Bool
    property handlers : Array(String)
    property? handlers_given : Bool
    property retries : Array(String)
    property? retries_given : Bool
    property limits : Array(String)
    property? limits_given : Bool
    property includes : Array(String)
    property? includes_given : Bool
    property? gather_facts : Bool
    property? seed_given : Bool
    property modes : Array(RunMode)
    property? modes_given : Bool
    property user_profiles : Array(UserProfile)
    property? user_profiles_given : Bool
    property umasks : Array(String)
    property? umasks_given : Bool
    property hosts : Array(Int32)
    property? hosts_given : Bool
    property? second_run : Bool
    # On by default: diff output is user-visible behavior and is compared
    # byte-for-byte like the rest of stdout (never masked).
    property? diff : Bool

    def initialize(@command, @modules = nil, @all_modules = false, @seed = 42, @count = 100,
                   @supported_community = false, @scope_from_krikri = false,
                   @chaos_percentage = 0.0, @chaos_kinds = %w[typo hallucinate wrong-type bad-choice violate-constraint jinja],
                   @out_dir = "playbooks/", @results_dir = "~/scratch/mfz-results",
                   @atlantic_hosts = 22, @ansible_playbook_bin = "ansible-playbook",
                   @krikri_bin = "/home/labros/git_work/krikri/bin/krikri-playbook",
                   @allow_mutation = false, @check = false, @run_on_podman = false,
                   @run_on_atlantic = false, @run_on_microvm = false, @run_on_mixed = false,
                   @keep_going = false, @engine_timeout = 120, @control = false,
                   @json = false, @min_happy_success = nil, @refresh_podman_templates = false,
                   @tasks_per_playbook = 1, @seed_given = false, @podman_parallel = 1,
                   @play_keywords = PlayKeywords::KINDS, @play_keywords_given = false,
                   @delegation = DelegationMode::Both, @delegation_given = false,
                   @blocks = BlockShapes::KINDS, @blocks_given = false,
                   @handlers = HandlerShapes::KINDS, @handlers_given = false,
                   @retries = RetryShapes::KINDS, @retries_given = false,
                   @limits = ["off"], @limits_given = false, @gather_facts = false,
                   @includes = IncludeShapes::KINDS, @includes_given = false,
                   @microvm_parallel = 1, @modes = [RunMode::Check, RunMode::Real],
                   @modes_given = false, @second_run = true, @diff = true,
                   @user_profiles = [UserProfile::Root], @user_profiles_given = false,
                   @umasks = [DEFAULT_UMASK], @umasks_given = false,
                   @hosts = [1], @hosts_given = false,
                   @microvm_dir = "/home/labros/.local/share/krikri-playbook-generator/microvm")
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
        dsl.on("--scope-from-krikri", "add every module the --krikri-bin binary reports (--list-modules) to the modules scope, so kpg covers everything the engine implements") { opts.scope_from_krikri = true }
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
        dsl.on("--check", "run the engines with --check (podman runs are real by default; local runs already default to --check --diff)") { opts.check = true }
        dsl.on("--run-on-podman", "run both engines inside throwaway podman containers instead of locally (requires podman)") { opts.run_on_podman = true }
        dsl.on("--run-on-atlantic", "run both engines on disposable Atlantic.net VMs, one per module profile (real mutation, no --check)") { opts.run_on_atlantic = true }
        dsl.on("--run-on-microvm", "run each playbook in a fresh local KVM microVM pair (requires qemu-system-x86_64 and /dev/kvm)") { opts.run_on_microvm = true }
        dsl.on("--run-on-mixed", "podman for the playbooks its containers can host, microVM for the ones needing a service/kernel (db, docker, zfs, firewalld, selinux)") { opts.run_on_mixed = true }
        dsl.on("--microvm-dir DIR", "state dir for the microvm goldens, cloud images and run records (default: ~/.local/share/krikri-playbook-generator/microvm)") { |v| opts.microvm_dir = expand_path(v) }
        dsl.on("--microvm-parallel N", "run N playbooks at once on microvm, each in its own VM pair (default: 1)") { |v| opts.microvm_parallel = parse_int(v, "--microvm-parallel") }
        dsl.on("--control", "noise check: run real ansible on both sides (podman only); every divergence is a missing mask or harness gap") { opts.control = true }
        dsl.on("--refresh-podman-templates", "ignore the podman template image cache and rebuild the templates from scratch") { opts.refresh_podman_templates = true }
        dsl.on("--podman-parallel N", "run N playbooks at once on podman, each in its own container pair (default: 1)") { |v| opts.podman_parallel = parse_int(v, "--podman-parallel") }
        dsl.on("--keep-going", "keep running the remaining playbooks after one fails to run (recorded as an errored result)") { opts.keep_going = true }
        dsl.on("--engine-timeout N", "per-engine timeout in seconds; a hung engine is recorded with rc 124 (default: 120)") { |v| opts.engine_timeout = parse_int(v, "--engine-timeout") }
        dsl.on("--min-happy-success PCT", "exit 1 when the happy-path success rate is below PCT (report, or generate with a run backend)") { |v| opts.min_happy_success = parse_float(v, "--min-happy-success") }
        dsl.on("--json", "print the report as a single JSON object on stdout (report, modules)") { opts.json = true }
        dsl.on("--modes LIST", "which run modes to compare: check, real or both (default: both on isolated backends, check locally)") do |v|
          modes = RunMode.parse_list(v)
          raise InvalidOptionsError.new("unknown --modes value #{v.inspect} (expected: check, real, both)") unless modes
          opts.modes = modes
          opts.modes_given = true
        end
        dsl.on("--no-second-run", "skip the second-run idempotency pass (the default runs a successful playbook twice on the same host)") { opts.second_run = false }
        dsl.on("--user-profile LIST", "which account the engines run as on an isolated backend: root, nonroot or both (default: root)") do |v|
          profiles = UserProfile.parse_list(v)
          raise InvalidOptionsError.new("unknown --user-profile value #{v.inspect} (expected: root, nonroot, both)") unless profiles
          opts.user_profiles = profiles
          opts.user_profiles_given = true
        end
        dsl.on("--umask LIST", "umask the engines run under: 002, 022, 077 (comma-separated; default: #{DEFAULT_UMASK})") do |v|
          umasks = v.split(',').map(&.strip).map do |value|
            KrikriPlaybookGenerator.normalize_umask(value) || raise InvalidOptionsError.new(
              "unknown --umask value #{value.inspect} (expected an octal mode like 002, 022 or 077)")
          end
          opts.umasks = umasks.uniq
          opts.umasks_given = true
        end
        dsl.on("--hosts LIST", "hosts per playbook: 1, 2 or 3 (comma-separated for a matrix; default: 1, the local aliases of one isolated host)") do |v|
          hosts = v.split(',').map(&.strip).map do |value|
            host_count = value.to_i?
            unless host_count && host_count.in?(1..HostInventory::MAX_HOSTS)
              raise InvalidOptionsError.new(
                "unknown --hosts value #{value.inspect} (expected 1, 2 or 3)")
            end
            host_count
          end
          opts.hosts = hosts.uniq
          opts.hosts_given = true
        end
        dsl.on("--diff", "pass --diff to both engines (the default; diff output is part of the compared bytes)") { opts.diff = true }
        dsl.on("--no-diff", "do not pass --diff to either engine (diff output is then never compared)") { opts.diff = false }
        dsl.on("--tasks-per-playbook N", "v2: build N-task playbooks from distinct modules with register/when chains, loops and handlers (default: 1, the single-task v1 shape)") { |v| opts.tasks_per_playbook = parse_int(v, "--tasks-per-playbook") }
        dsl.on("--delegation MODE", "delegate_to spelling for generated tasks: off, literal, templated (a play var) or both (default, drawn per task)") do |v|
          opts.delegation = parse_delegation(v)
          opts.delegation_given = true
        end
        dsl.on("--limit LIST", "host-scope rows: none, one, group, unreachable, negative (comma-separated; every row contacts every host in scope)") do |v|
          opts.limits = parse_limits(v)
          opts.limits_given = true
        end
        dsl.on("--gather-facts", "generate plays with gather_facts: true, so implicit fact gathering is exercised (pair with --limit)") { opts.gather_facts = true }
        dsl.on("--includes LIST", "include/import forms: relative, role-vars, role-inner, loop-tasks, loop-role, import-playbook, import-role (comma-separated; `none` turns it off)") do |v|
          opts.includes = parse_includes(v)
          opts.includes_given = true
        end
        dsl.on("--retries LIST", "retry shapes: retried, exhausted, delegated or delegated-fact (comma-separated; `none` turns it off)") do |v|
          opts.retries = parse_retries(v)
          opts.retries_given = true
        end
        dsl.on("--handlers LIST", "handler shapes: failing, ignoring, delegated or chained (comma-separated; `none` turns it off)") do |v|
          opts.handlers = parse_handlers(v)
          opts.handlers_given = true
        end
        dsl.on("--blocks LIST", "block shapes wrapping the generated task: rescue, always, skipped or undefined (comma-separated; `none` turns it off)") do |v|
          opts.blocks = parse_blocks(v)
          opts.blocks_given = true
        end
        dsl.on("--play-keywords LIST", "play-level keyword axis: one keyword per playbook, drawn from strategy, serial, throttle, any_errors_fatal, run_once, max_fail_percentage, gather_facts, connection and forks (env-only); `none` turns it off") do |v|
          opts.play_keywords = parse_play_keywords(v)
          opts.play_keywords_given = true
        end
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
      opts.microvm_dir = expand_path(opts.microvm_dir)

      check_conflicts!(opts)
      parse_chaos_kinds(opts.chaos_kinds)
      validate!(opts)

      opts
    end

    # The modes Runner actually compares. Both is the default on an
    # isolated backend because a module can be correct in one mode and
    # wrong in the other; local runs stay check-only unless
    # --allow-mutation is explicit (real modules mutate *this* machine),
    # and Atlantic runs are always real.
    def self.effective_modes(opts : Options) : Array(RunMode)
      modes = opts.modes_given? ? opts.modes : default_modes(opts)
      modes = [RunMode::Check] if opts.check? && !opts.modes_given?
      if opts.run_on_atlantic? && modes.includes?(RunMode::Check)
        raise InvalidOptionsError.new("check mode is not available on --run-on-atlantic (Atlantic runs are deliberately real)")
      end
      if local_run?(opts) && modes.includes?(RunMode::Real) && !opts.allow_mutation?
        raise InvalidOptionsError.new("real mode on the local backend needs --allow-mutation (happy-path tasks would mutate this machine)")
      end
      modes.uniq
    end

    # Which identities the matrix runs. The shared local host cannot switch
    # accounts, and Atlantic's VMs are only provisioned as root.
    def self.effective_user_profiles(opts : Options) : Array(UserProfile)
      return [UserProfile::Local] if local_run?(opts)
      return [UserProfile::Root] if opts.run_on_atlantic?

      opts.user_profiles
    end

    def self.effective_umasks(opts : Options) : Array(String)
      opts.umasks
    end

    # The host-count axis. Atlantic reuses one VM per profile and builds
    # its inventory once, so only one count can apply there; every other
    # backend rebuilds the inventory per row.
    def self.effective_hosts(opts : Options) : Array(Int32)
      opts.hosts
    end

    # The `--limit` symbols `--limit` accepts; each maps to an ansible
    # pattern (or to nil for no limit at all).
    LIMIT_CHOICES = %w[off none one group unreachable negative]

    def self.limit_pattern(symbol : String) : String?
      case symbol
      when "off", "none" then nil
      when "one"         then HostInventory.aliases(1).first
      when "group"       then HostInventory::GROUP
      when "unreachable" then HostInventory::UNREACHABLE_HOST
      when "negative"    then "#{HostInventory::GROUP}:!#{HostInventory.aliases(2).last}"
      end
    end

    def self.effective_limits(opts : Options) : Array(String)
      opts.limits
    end

    private def self.default_modes(opts : Options) : Array(RunMode)
      return [RunMode::Real] if opts.run_on_atlantic?
      return [RunMode::Check] if local_run?(opts) && !opts.allow_mutation?
      return [RunMode::Real] if local_run?(opts)

      [RunMode::Check, RunMode::Real]
    end

    private def self.local_run?(opts : Options) : Bool
      !opts.run_on_podman? && !opts.run_on_atlantic? && !opts.run_on_microvm? && !opts.run_on_mixed?
    end

    private def self.check_conflicts!(opts : Options) : Nil
      if opts.all_modules? && opts.modules
        raise InvalidOptionsError.new("--all-modules conflicts with --modules")
      end
      check_scope_conflicts!(opts)
      check_podman_conflicts!(opts)
      check_run_mode_conflicts!(opts)
      check_context_conflicts!(opts)
      raise InvalidOptionsError.new("--json is only valid with the report or modules command") if opts.json? && !opts.command.report? && !opts.command.modules?

      check_happy_gate_target!(opts)
    end

    # The flags that only make sense for (or contradict) --run-on-podman.
    private def self.check_podman_conflicts!(opts : Options) : Nil
      runners = [opts.run_on_podman?, opts.run_on_atlantic?, opts.run_on_microvm?, opts.run_on_mixed?].count(true)
      raise InvalidOptionsError.new("only one of --run-on-podman/--run-on-atlantic/--run-on-microvm may be given") if runners > 1
      raise InvalidOptionsError.new("--control needs a backend (--run-on-podman, --run-on-microvm or --run-on-mixed)") if opts.control? && !opts.run_on_podman? && !opts.run_on_microvm? && !opts.run_on_mixed?
      raise InvalidOptionsError.new("--refresh-podman-templates needs --run-on-podman") if opts.refresh_podman_templates? && !opts.run_on_podman? && !opts.run_on_mixed?
      raise InvalidOptionsError.new("--podman-parallel needs --run-on-podman") if opts.podman_parallel > 1 && !opts.run_on_podman? && !opts.run_on_mixed?
      raise InvalidOptionsError.new("--microvm-parallel needs --run-on-microvm") if opts.microvm_parallel > 1 && !opts.run_on_microvm?
    end

    # Check mode and real mutation are opposite run modes, and an
    # Atlantic run is deliberately real.
    private def self.check_run_mode_conflicts!(opts : Options) : Nil
      raise InvalidOptionsError.new("--check conflicts with --run-on-atlantic (Atlantic runs are deliberately real)") if opts.check? && opts.run_on_atlantic?
      raise InvalidOptionsError.new("--check conflicts with --allow-mutation (check mode and real mutation mean opposite things)") if opts.check? && opts.allow_mutation?
    end

    # The identity and umask axes need a host the tool fully owns: the
    # shared local host cannot switch accounts, and Atlantic's VMs are only
    # provisioned as root (their umask axis is still available).
    private def self.check_context_conflicts!(opts : Options) : Nil
      return unless opts.user_profiles_given? || opts.umasks_given? || opts.hosts_given?

      unless opts.command.run? || opts.command.generate?
        raise InvalidOptionsError.new("--user-profile/--umask/--hosts are only valid with run or generate")
      end

      check_atlantic_host_axis!(opts)

      # Atlantic applies one umask per batch (one VM per profile), so an
      # axis list there would silently drop values.
      if opts.run_on_atlantic? && opts.umasks.size > 1
        raise InvalidOptionsError.new("--umask takes one value on --run-on-atlantic")
      end

      return unless opts.user_profiles_given?

      isolated = opts.run_on_podman? || opts.run_on_microvm? || opts.run_on_mixed?
      return if isolated

      raise InvalidOptionsError.new(
        "--user-profile needs an isolated backend (--run-on-podman, --run-on-microvm or --run-on-mixed)")
    end

    # Atlantic builds one VM (and one inventory) per profile for the whole
    # batch, so a multi-value host axis would silently collapse.
    private def self.check_atlantic_host_axis!(opts : Options) : Nil
      return unless opts.run_on_atlantic? && opts.hosts.size > 1

      raise InvalidOptionsError.new("--hosts takes one value on --run-on-atlantic")
    end

    private def self.check_scope_conflicts!(opts : Options) : Nil
      if opts.scope_from_krikri? && !opts.command.modules?
        raise InvalidOptionsError.new("--scope-from-krikri is only valid with the modules command")
      end
      check_play_keyword_target!(opts)
      check_delegation_target!(opts)
      check_block_target!(opts)
      check_handler_target!(opts)
      check_retry_target!(opts)
      check_include_target!(opts)
      check_limit_target!(opts)
      return unless opts.supported_community?

      raise InvalidOptionsError.new("--supported-community needs generate") unless opts.command.generate?
      raise InvalidOptionsError.new("--all-modules conflicts with --supported-community") if opts.all_modules?
      raise InvalidOptionsError.new("--supported-community conflicts with --modules") if opts.modules
    end

    # The keyword is written into the playbook file (or its sidecar), so it
    # only means anything where playbooks are built.
    private def self.check_play_keyword_target!(opts : Options) : Nil
      return unless opts.play_keywords_given?
      return if opts.command.generate?

      raise InvalidOptionsError.new("--play-keywords is only valid with generate (the playbook carries the keyword)")
    end

    # Delegation is written into the generated playbook (and its probes), so
    # it only means anything where playbooks are built.
    private def self.check_delegation_target!(opts : Options) : Nil
      return unless opts.delegation_given?
      return if opts.command.generate?

      raise InvalidOptionsError.new("--delegation is only valid with generate (the playbook carries delegate_to)")
    end

    # Blocks are playbook structure, so they only mean anything where
    # playbooks are built (and only in the single-task shape, which the
    # caller warns about).
    private def self.check_block_target!(opts : Options) : Nil
      return unless opts.blocks_given?
      return if opts.command.generate?

      raise InvalidOptionsError.new("--blocks is only valid with generate (the playbook carries the block)")
    end

    # Handlers are playbook structure too, so generate-only.
    private def self.check_handler_target!(opts : Options) : Nil
      return unless opts.handlers_given?
      return if opts.command.generate?

      raise InvalidOptionsError.new("--handlers is only valid with generate (the playbook carries the handlers)")
    end

    # Retry shapes are playbook structure too, so generate-only.
    private def self.check_retry_target!(opts : Options) : Nil
      return unless opts.retries_given?
      return if opts.command.generate?

      raise InvalidOptionsError.new("--retries is only valid with generate (the playbook carries retries/until)")
    end

    # `--limit` is a run matrix (generate with a backend, or run); the
    # gather-facts flag is generation-time only.
    private def self.check_limit_target!(opts : Options) : Nil
      if opts.limits_given? && !opts.command.run? && !opts.command.generate?
        raise InvalidOptionsError.new("--limit is only valid with run or generate")
      end
      # Atlantic builds one inventory per profile for the whole batch, so a
      # multi-value limit axis would silently collapse.
      if opts.run_on_atlantic? && opts.limits.size > 1
        raise InvalidOptionsError.new("--limit takes one value on --run-on-atlantic")
      end
      if opts.gather_facts? && !opts.command.generate?
        raise InvalidOptionsError.new("--gather-facts is only valid with generate (the playbook carries gather_facts)")
      end
    end

    # Include forms are playbook structure, so generate-only.
    private def self.check_include_target!(opts : Options) : Nil
      return unless opts.includes_given?
      return if opts.command.generate?

      raise InvalidOptionsError.new("--includes is only valid with generate (the playbook carries the include forms)")
    end

    private def self.parse_includes(value : String) : Array(String)
      shapes = IncludeShapes.parse_list(value)
      return shapes if shapes

      raise InvalidOptionsError.new(
        "unknown --includes value #{value.inspect} (expected: #{IncludeShapes::KINDS.join(", ")}, none)")
    end

    private def self.parse_limits(value : String) : Array(String)
      limits = value.split(',').map(&.strip)
      unknown = limits.reject { |entry| LIMIT_CHOICES.includes?(entry) }
      return limits.uniq if unknown.empty?

      raise InvalidOptionsError.new(
        "unknown --limit value #{unknown.first.inspect} (expected: #{LIMIT_CHOICES.join(", ")})")
    end

    private def self.parse_retries(value : String) : Array(String)
      shapes = RetryShapes.parse_list(value)
      return shapes if shapes

      raise InvalidOptionsError.new(
        "unknown --retries value #{value.inspect} (expected: #{RetryShapes::KINDS.join(", ")}, none)")
    end

    private def self.parse_handlers(value : String) : Array(String)
      shapes = HandlerShapes.parse_list(value)
      return shapes if shapes

      raise InvalidOptionsError.new(
        "unknown --handlers value #{value.inspect} (expected: #{HandlerShapes::KINDS.join(", ")}, none)")
    end

    private def self.parse_blocks(value : String) : Array(String)
      shapes = BlockShapes.parse_list(value)
      return shapes if shapes

      raise InvalidOptionsError.new(
        "unknown --blocks value #{value.inspect} (expected: #{BlockShapes::KINDS.join(", ")}, none)")
    end

    private def self.parse_delegation(value : String) : DelegationMode
      mode = DelegationMode.parse(value)
      return mode if mode

      raise InvalidOptionsError.new(
        "unknown --delegation value #{value.inspect} (expected: off, literal, templated, both)")
    end

    private def self.parse_play_keywords(value : String) : Array(String)
      kinds = PlayKeywords.parse_list(value)
      return kinds if kinds

      raise InvalidOptionsError.new(
        "unknown --play-keywords value #{value.inspect} (expected: #{PlayKeywords::KINDS.join(", ")}, none)")
    end

    private def self.check_happy_gate_target!(opts : Options) : Nil
      return unless opts.min_happy_success

      usable = opts.command.report? || (opts.command.generate? && (opts.run_on_podman? || opts.run_on_atlantic? || opts.run_on_microvm? || opts.run_on_mixed?))
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
      when "modules"  then Command::Modules
      else                 raise InvalidOptionsError.new("unknown command #{arg.inspect} (expected generate|run|report|modules)")
      end
    end

    private def self.validate!(opts : Options) : Nil
      raise InvalidOptionsError.new("--seed must be zero or a positive integer, got #{opts.seed}") if opts.seed.negative?
      raise InvalidOptionsError.new("--count must be zero or a positive integer, got #{opts.count}") if opts.count.negative?
      raise InvalidOptionsError.new("--tasks-per-playbook must be a positive integer, got #{opts.tasks_per_playbook}") if opts.tasks_per_playbook < 1
      raise InvalidOptionsError.new("--engine-timeout must be a positive integer, got #{opts.engine_timeout}") if opts.engine_timeout <= 0
      raise InvalidOptionsError.new("--podman-parallel must be a positive integer, got #{opts.podman_parallel}") if opts.podman_parallel < 1
      raise InvalidOptionsError.new("--microvm-parallel must be a positive integer, got #{opts.microvm_parallel}") if opts.microvm_parallel < 1
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
