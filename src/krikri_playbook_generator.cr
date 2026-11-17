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
        opts.krikri_bin, modes: Options.effective_modes(opts), run_on_podman: opts.run_on_podman?,
        run_on_atlantic: opts.run_on_atlantic?, run_on_microvm: opts.run_on_microvm?,
        run_on_mixed: opts.run_on_mixed?, second_run: opts.second_run?, diff: opts.diff?,
        keep_going: opts.keep_going?, engine_timeout: opts.engine_timeout, control: opts.control?,
        refresh_podman_templates: opts.refresh_podman_templates?,
        podman_parallel: opts.podman_parallel, microvm_dir: opts.microvm_dir,
        microvm_parallel: opts.microvm_parallel,
        user_profiles: Options.effective_user_profiles(opts),
        umasks: Options.effective_umasks(opts),
        hosts: Options.effective_hosts(opts)).run
      print_run_summary(results)
      divergences?(results) ? DIVERGENT_EXIT : 0
    in Command::Report
      triage = Triage.new(opts.results_dir)
      findings = triage.report
      state_findings = triage.state_report
      check_mode_findings = triage.check_mode_report
      print_report(triage, json: opts.json?, findings: findings, state_findings: state_findings,
        check_mode_findings: check_mode_findings)
      report_exit_code(triage, findings, state_findings, check_mode_findings, opts.min_happy_success)
    in Command::Modules
      print_module_scope(json: opts.json?, opts: opts)
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
  rescue e : MicrovmProvisionError
    STDERR.puts "error: #{e.message}"
    1
  end

  # The default scope (ansible.builtin core + promoted supported FQCNs),
  # for callers that need the list without scanning it - krikri-loop
  # builds its kpg rotation from this instead of hand-duplicating it.
  # `--scope-from-krikri` widens it to everything the engine itself reports,
  # so the rotation reaches the collection modules krikri implements instead
  # of only the ansible.builtin core.
  private def self.print_module_scope(json : Bool, opts : Options) : Int32
    extra = opts.scope_from_krikri? ? SchemaScanner.krikri_module_names(opts.krikri_bin) : [] of String
    if opts.scope_from_krikri? && extra.empty?
      STDERR.puts "warning: #{opts.krikri_bin.inspect} reported no supported modules (no --list-modules support?); scope stays core-only"
    end
    # `--json` is a machine payload (krikri-loop parses it and still echoes
    # the command's stderr), so the missing-module count stays out of it.
    scope = SchemaScanner.default_module_names(Dependencies.load.supported + extra, warn_missing: !json)
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
      sampler = PlaySettingSampler.new(opts.seed, opts.play_keywords)
      settings = tasks.map { |task| sampler.sample(task.chaos?) }
      playbooks = PlaybookBuilder.new(opts.out_dir, opts.seed, settings).build(tasks)
    end
    run_generated(opts, playbooks)
  end

  # v2 multi-task generation: `--tasks-per-playbook N` (N >= 2) assembles
  # playbooks of N tasks from N distinct scanned modules, wired with
  # register/when chains, loops and handlers. Needs at least two scanned
  # modules to be meaningful; a smaller pool falls back to the
  # single-task shape rather than repeating a module inside one play.
  # Each playbook stays on one host profile (see Generator#generate_scenarios),
  # so its task count can be below `per_playbook`.
  private def self.build_multi_task_playbooks(opts : Options, generator : Generator,
                                              schemas : Array(ModuleSchema)) : Array(String)
    per_playbook = Math.min(opts.tasks_per_playbook, schemas.size)
    if per_playbook < 2
      Log.info("generate", "warning: only #{schemas.size} module(s) scanned; " \
                           "--tasks-per-playbook needs at least 2 - falling back to single-task playbooks")
      tasks = [] of GeneratedTask
      schemas.each { |schema| tasks.concat(generator.generate(schema, opts.count)) }
      Log.info("generate", "building #{tasks.size} playbook(s) into #{opts.out_dir}")
      sampler = PlaySettingSampler.new(opts.seed, opts.play_keywords)
      settings = tasks.map { |task| sampler.sample(task.chaos?) }
      return PlaybookBuilder.new(opts.out_dir, opts.seed, settings).build(tasks)
    end

    Log.info("generate", "generating #{opts.count} multi-task playbook(s) " \
                         "(up to #{per_playbook} tasks each, one host profile per playbook, " \
                         "chaos=#{opts.chaos_percentage}%, seed=#{opts.seed})")
    scenarios = generator.generate_scenarios(schemas, per_playbook, opts.count)
    Log.info("generate", "building #{scenarios.size} playbook(s) into #{opts.out_dir}")
    sampler = PlaySettingSampler.new(opts.seed, opts.play_keywords)
    settings = scenarios.map { |tasks| sampler.sample(tasks.any?(&.chaos?)) }
    PlaybookBuilder.new(opts.out_dir, opts.seed, settings).build_scenarios(scenarios)
  end

  private def self.print_version : Int32
    puts "krikri-playbook-generator #{VERSION}"
    0
  end

  # Fused `generate` (the podman/Atlantic path): build, run, report, and
  # apply the happy-path success gate. Without a run backend there is
  # nothing to execute, so the batch just stops after building.
  private def self.run_generated(opts : Options, playbooks : Array(String)) : Int32
    unless opts.run_on_podman? || opts.run_on_atlantic? || opts.run_on_microvm? || opts.run_on_mixed?
      return 0
    end

    results = Runner.new(playbooks, opts.results_dir, opts.atlantic_hosts, opts.ansible_playbook_bin,
      opts.krikri_bin, modes: Options.effective_modes(opts), run_on_podman: opts.run_on_podman?,
      run_on_atlantic: opts.run_on_atlantic?, run_on_microvm: opts.run_on_microvm?,
      run_on_mixed: opts.run_on_mixed?, second_run: opts.second_run?, diff: opts.diff?,
      keep_going: opts.keep_going?, engine_timeout: opts.engine_timeout, control: opts.control?,
      refresh_podman_templates: opts.refresh_podman_templates?,
      podman_parallel: opts.podman_parallel, microvm_dir: opts.microvm_dir,
      microvm_parallel: opts.microvm_parallel,
      user_profiles: Options.effective_user_profiles(opts),
      umasks: Options.effective_umasks(opts),
      hosts: Options.effective_hosts(opts)).run
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
      next unless result.error || result.divergent?
      verdict = result.error ? "ERROR" : "DIVERGENT"
      color = result.error ? Log::RED : Log::YELLOW
      puts Log.paint(color, "[#{verdict}] #{result.playbook} #{result.context_label}")
    end
  end

  private def self.print_report(triage : Triage, json : Bool, findings : Array(Triage::Finding)? = nil,
                                state_findings : Array(Triage::Finding)? = nil,
                                check_mode_findings : Array(Triage::Finding)? = nil) : Nil
    if json
      puts triage.report_json
    else
      print_full_report(triage, findings, state_findings, check_mode_findings)
    end
  end

  private def self.print_full_report(triage : Triage, findings : Array(Triage::Finding)? = nil,
                                     state_findings : Array(Triage::Finding)? = nil,
                                     check_mode_findings : Array(Triage::Finding)? = nil) : Nil
    print_batch_info(triage)
    diff = triage.batch_info[:diff]
    print_divergences(findings || triage.report, diff)
    print_state_divergences(state_findings || triage.state_report, diff)
    print_check_mode_mutations(check_mode_findings || triage.check_mode_report, diff)
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

  # Divergences (output, state-only or a check-mode mutation) exit 2; a
  # batch whose own happy-path coverage is too poor exits 1, keeping the
  # two failures distinguishable.
  private def self.report_exit_code(triage : Triage, findings : Array(Triage::Finding),
                                    state_findings : Array(Triage::Finding),
                                    check_mode_findings : Array(Triage::Finding),
                                    minimum : Float64?) : Int32
    return DIVERGENT_EXIT if !findings.empty? || !state_findings.empty? || !check_mode_findings.empty?

    happy_gate_failed?(triage, minimum) ? 1 : 0
  end

  # The cost of the mode matrix and the second-run pass is part of the
  # result: a 4x batch that finds nothing is a different decision from a
  # 2x one.
  private def self.print_batch_info(triage : Triage) : Nil
    info = triage.batch_info
    modes = info[:modes].empty? ? "unknown" : info[:modes].join(",")
    duration = info[:duration] || "unknown"
    puts "== Batch =="
    puts "modes: #{modes} | idempotency pass: #{info[:second_run] ? "on" : "off"} | wall time: #{duration}"
  end

  # (mode, run, identity, umask, host count, signature label) for one
  # finding's example; the host count only shows when it is not the default.
  private def self.finding_context(example : Triage::ResultLine, label : String) : String
    context = "#{example.mode}, run #{example.run}, #{example.user}, umask #{example.umask}"
    context += ", hosts #{example.hosts}" unless example.hosts == 1
    "(#{context}, #{label})"
  end

  private def self.print_divergences(findings : Array(Triage::Finding), diff : Bool = true) : Nil
    puts "== Divergences (grouped by module + diff signature) =="
    if findings.empty?
      puts "No divergences found."
      return
    end

    findings.each do |finding|
      label = finding.signature ? "signature #{finding.signature}" : "no signature"
      example = finding.example
      puts "#{finding.module_name} #{finding_context(example, label)}: #{finding.count} divergent playbook(s)"
      unless finding.example_mutations.empty?
        puts "  mutations: #{finding.example_mutations.map { |mutation| "#{mutation.kind} #{mutation.option}" }.join(", ")}"
      end
      puts "  example: #{finding.playbooks.first}"
      puts "  repro: #{Triage.repro_command(finding.playbooks.first, [finding.module_name], example.mode, example.run, diff, example.user, example.umask, example.hosts, example.env)}"
    end
  end

  private def self.print_state_divergences(findings : Array(Triage::Finding), diff : Bool = true) : Nil
    return if findings.empty?

    puts "== State divergences (same printed result, different host state) =="
    findings.each do |finding|
      label = finding.signature ? "state signature #{finding.signature}" : "no signature"
      example = finding.example
      puts "#{finding.module_name} #{finding_context(example, label)}: #{finding.count} state-only playbook(s)"
      puts "  example: #{example.playbook}"
      puts "  repro: #{Triage.repro_command(example.playbook, [finding.module_name], example.mode, example.run, diff, example.user, example.umask, example.hosts, example.env)}"
      print_state_diff(example.state_diff)
      unless example.leftover_temps.empty?
        puts "  leftover staging files:"
        example.leftover_temps.lines.first(10).each { |line| puts "    #{line}" }
        puts "    ... #{example.leftover_temps.lines.size - 10} more line(s)" if example.leftover_temps.lines.size > 10
      end
    end
  end

  private def self.print_state_diff(diff : String) : Nil
    changed = diff.lines.select { |line| line.starts_with?('-') || line.starts_with?('+') }
    changed.first(10).each { |line| puts "  #{line}" }
    puts "  ... #{changed.size - 10} more changed line(s)" if changed.size > 10
  end

  private def self.print_check_mode_mutations(findings : Array(Triage::Finding), diff : Bool = true) : Nil
    return if findings.empty?

    puts "== Check-mode mutations (--check changed the host) =="
    findings.each do |finding|
      label = finding.signature ? "check-mode signature #{finding.signature}" : "no signature"
      example = finding.example
      puts "#{finding.module_name} #{finding_context(example, label)}: " \
           "#{finding.count} playbook(s) mutated the host in check mode"
      puts "  example: #{example.playbook}"
      puts "  repro: #{Triage.repro_command(example.playbook, [finding.module_name], example.mode, example.run, diff, example.user, example.umask, example.hosts, example.env)}"
      lines = example.check_mode_diff.lines
      lines.first(10).each { |line| puts "  #{line}" }
      puts "  ... #{lines.size - 10} more line(s)" if lines.size > 10
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
