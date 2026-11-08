require "./krikri_playbook_generator/**"

module KrikriPlaybookGenerator
  # Divergences found; 1 stays "the tool itself failed", so a caller (krikri-loop) can tell them apart.
  DIVERGENT_EXIT = 2

  def self.main(argv : Array(String)) : Int32
    return print_version if version_requested?(argv)

    opts = Options.parse(argv)

    case opts.command
    in Command::Generate
      do_generate(opts)
    in Command::Run
      Preflight.check!(opts.ansible_playbook_bin, opts.krikri_bin)
      playbooks = playbook_paths_for_run(opts)
      results = Runner.new(playbooks, opts.results_dir, opts.atlantic_hosts, opts.ansible_playbook_bin,
        opts.krikri_bin, check_mode: Options.check_mode(opts), run_on_podman: opts.run_on_podman?,
        run_on_atlantic: opts.run_on_atlantic?,
        keep_going: opts.keep_going?, engine_timeout: opts.engine_timeout, control: opts.control?,
        refresh_podman_templates: opts.refresh_podman_templates?,
        podman_parallel: opts.podman_parallel).run
      print_run_summary(results)
      divergences?(results) ? DIVERGENT_EXIT : 0
    in Command::Report
      triage = Triage.new(opts.results_dir)
      findings = triage.report
      print_report(triage, json: opts.json?, findings: findings)
      if !findings.empty?
        DIVERGENT_EXIT
      elsif happy_gate_failed?(triage, opts.min_happy_success)
        1
      else
        0
      end
    in Command::Modules
      print_module_scope(json: opts.json?)
    end
  rescue e : InvalidOptionsError
    STDERR.puts "error: #{e.message}"
    1
  rescue e : PreflightError
    STDERR.puts "error: #{e.message}"
    1
  rescue e : TriageError
    STDERR.puts "error: #{e.message}"
    1
  rescue e : SchemaScanner::ScanError
    STDERR.puts "error: #{e.message}"
    1
  rescue e : PodmanProvisionError
    STDERR.puts "error: #{e.message}"
    1
  rescue e : AtlanticProvisionError
    STDERR.puts "error: #{e.message}"
    1
  end

  # The default scope (ansible.builtin core + promoted supported FQCNs),
  # for callers that need the list without scanning it - krikri-loop
  # builds its kpg rotation from this instead of hand-duplicating it.
  private def self.print_module_scope(json : Bool) : Int32
    scope = SchemaScanner.default_module_names
    puts scope.to_json if json
    scope.each { |name| puts name } unless json
    0
  end

  private def self.version_requested?(argv : Array(String)) : Bool
    argv.includes?("--version") || argv.includes?("-v") || argv.first? == "version"
  end

  private def self.do_generate(opts : Options) : Int32
    Preflight.check!(opts.ansible_playbook_bin, opts.krikri_bin)
    supported = opts.supported_community? ? Dependencies.load.supported : nil
    Log.info("generate", "scanning module schemas " \
                         "(modules=#{opts.modules.try(&.join(",")) || "default"}, all=#{opts.all_modules?}, " \
                         "supported_community=#{opts.supported_community?}, count=#{opts.count}, " \
                         "chaos=#{opts.chaos_percentage}%, seed=#{opts.seed}#{opts.seed_given? ? "" : ", random"})")
    schemas = SchemaScanner.new(opts.modules, all_modules: opts.all_modules?, supported_community: supported).scan
    chaos_kinds = Options.parse_chaos_kinds(opts.chaos_kinds)
    generator = Generator.new(opts.seed, opts.chaos_percentage, chaos_kinds)
    if opts.tasks_per_playbook > 1
      playbooks = build_multi_task_playbooks(opts, generator, schemas)
    else
      tasks = [] of GeneratedTask
      schemas.each do |schema|
        tasks.concat(generator.generate(schema, opts.count))
      end
      Log.info("generate", "building #{tasks.size} playbook(s) into #{opts.out_dir}")
      playbooks = PlaybookBuilder.new(opts.out_dir, opts.seed).build(tasks)
    end
    run_generated(opts, playbooks)
  end

  # v2 multi-task generation: `--tasks-per-playbook N` (N >= 2) assembles
  # playbooks of N tasks from N distinct scanned modules, wired with
  # register/when chains, loops and handlers. Needs at least two scanned
  # modules to be meaningful; a smaller pool falls back to the
  # single-task shape rather than repeating a module inside one play.
  private def self.build_multi_task_playbooks(opts : Options, generator : Generator,
                                              schemas : Array(ModuleSchema)) : Array(String)
    per_playbook = Math.min(opts.tasks_per_playbook, schemas.size)
    if per_playbook < 2
      Log.info("generate", "warning: only #{schemas.size} module(s) scanned; " \
                           "--tasks-per-playbook needs at least 2 - falling back to single-task playbooks")
      tasks = [] of GeneratedTask
      schemas.each { |schema| tasks.concat(generator.generate(schema, opts.count)) }
      Log.info("generate", "building #{tasks.size} playbook(s) into #{opts.out_dir}")
      return PlaybookBuilder.new(opts.out_dir, opts.seed).build(tasks)
    end

    Log.info("generate", "generating #{opts.count} multi-task playbook(s) " \
                         "(#{per_playbook} tasks each, chaos=#{opts.chaos_percentage}%, seed=#{opts.seed})")
    scenarios = generator.generate_scenarios(schemas, per_playbook, opts.count)
    Log.info("generate", "building #{scenarios.size} playbook(s) into #{opts.out_dir}")
    PlaybookBuilder.new(opts.out_dir, opts.seed).build_scenarios(scenarios)
  end

  private def self.print_version : Int32
    puts "krikri-playbook-generator #{VERSION}"
    0
  end

  # Fused `generate` (the podman/Atlantic path): build, run, report, and
  # apply the happy-path success gate. Without a run backend there is
  # nothing to execute, so the batch just stops after building.
  private def self.run_generated(opts : Options, playbooks : Array(String)) : Int32
    return 0 unless opts.run_on_podman? || opts.run_on_atlantic?

    results = Runner.new(playbooks, opts.results_dir, opts.atlantic_hosts, opts.ansible_playbook_bin,
      opts.krikri_bin, check_mode: Options.check_mode(opts), run_on_podman: opts.run_on_podman?, run_on_atlantic: opts.run_on_atlantic?,
      keep_going: opts.keep_going?, engine_timeout: opts.engine_timeout, control: opts.control?,
      refresh_podman_templates: opts.refresh_podman_templates?,
      podman_parallel: opts.podman_parallel).run
    triage = Triage.new(opts.results_dir)
    print_run_summary(results)
    print_full_report(triage)
    return DIVERGENT_EXIT if divergences?(results)

    happy_gate_failed?(triage, opts.min_happy_success) ? 1 : 0
  end

  # `run` accepts either a directory (the whole generated batch, the
  # previous behavior) or a single playbook file path - the copy-paste
  # repro form Triage prints for every finding.
  private def self.playbook_paths_for_run(opts : Options) : Array(String)
    return [opts.out_dir] if File.file?(opts.out_dir)

    Dir.glob("#{opts.out_dir}/**/*.yml")
  end

  private def self.divergences?(results : Array(Runner::PlaybookResult)) : Bool
    results.any?(&.divergent?)
  end

  private def self.print_run_summary(results : Array(Runner::PlaybookResult)) : Nil
    results.each do |result|
      verdict = result.error ? "ERROR" : (result.divergent? ? "DIVERGENT" : "IDENTICAL")
      color = result.error ? Log::RED : (result.divergent? ? Log::RED : Log::GREEN)
      puts Log.paint(color, "[#{verdict}] #{result.playbook}")
    end
  end

  private def self.print_report(triage : Triage, json : Bool, findings : Array(Triage::Finding)? = nil) : Nil
    if json
      puts triage.report_json
    else
      print_full_report(triage, findings)
    end
  end

  private def self.print_full_report(triage : Triage, findings : Array(Triage::Finding)? = nil) : Nil
    print_divergences(findings || triage.report)
    print_quality(triage.quality, triage.expected_failures, triage.happy_coverage, triage.not_applicable_modules)
    print_rates(triage.rates)
  end

  # Batch-level happy-path runnability gate (`--min-happy-success`): a
  # run whose happy-path playbooks mostly fail on the reference engine is
  # measuring almost nothing, so a caller can fail the batch on it. Exit
  # 1 (not 2) keeps "the run's own coverage is too poor" distinct from
  # "krikri diverges from ansible".
  private def self.happy_gate_failed?(triage : Triage, minimum : Float64?) : Bool
    return false unless minimum

    coverage = triage.happy_coverage
    return false if coverage.attempted.zero?
    return false if coverage.success_rate >= minimum

    STDERR.puts "error: happy-path success rate #{coverage.success_rate.round(1)}% " \
                "(#{coverage.succeeded}/#{coverage.attempted}) is below --min-happy-success #{minimum}%"
    true
  end

  private def self.print_divergences(findings : Array(Triage::Finding)) : Nil
    puts "== Divergences (grouped by module + diff signature) =="
    if findings.empty?
      puts "No divergences found."
      return
    end

    findings.each do |finding|
      label = finding.signature ? "signature #{finding.signature}" : "no signature"
      puts "#{finding.module_name} (#{label}): #{finding.count} divergent playbook(s)"
      unless finding.example_mutations.empty?
        puts "  mutations: #{finding.example_mutations.map { |mutation| "#{mutation.kind} #{mutation.option}" }.join(", ")}"
      end
      example = finding.playbooks.first
      puts "  example: #{example}"
      puts "  repro: #{Triage.repro_command(example)}"
    end
  end

  private def self.print_quality(quality : Array(Triage::Quality), expected_failures : Array(String),
                                 coverage : Triage::HappyCoverage, not_applicable : Array(String)) : Nil
    puts "== Generator quality (happy-path failures on real ansible) =="
    if coverage.attempted.zero?
      puts "No happy-path playbooks in these results."
    else
      puts "happy-path success: #{coverage.succeeded}/#{coverage.attempted} " \
           "(#{coverage.success_rate.round(1)}% run successfully on real ansible)"
    end
    if quality.empty?
      puts "Every happy-path playbook ran successfully on real ansible."
    else
      quality.each do |entry|
        puts "#{entry.module_name}: #{entry.failed}/#{entry.total} happy-path playbook(s) failed on real ansible (wasted coverage)"
        puts "  first error: #{entry.example_error}"
      end
    end
    unless expected_failures.empty?
      puts "Not counted as wasted coverage (expected to fail by design): #{expected_failures.join(", ")}"
    end
    unless not_applicable.empty?
      puts "Not counted (cannot run as a single local task): #{not_applicable.join(", ")}"
    end
  end

  private def self.print_rates(rates : Array(Triage::Rate)) : Nil
    puts "== Per-module byte-identical rate (masked comparison) =="
    rates.each do |rate|
      puts "#{rate.module_name}: #{rate.identical}/#{rate.total} byte-identical"
    end
  end
end

exit(KrikriPlaybookGenerator.main(ARGV))
