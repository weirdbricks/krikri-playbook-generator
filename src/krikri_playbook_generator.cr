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
        opts.krikri_bin, check_mode: !opts.allow_mutation?, run_on_podman: opts.run_on_podman?,
        run_on_atlantic: opts.run_on_atlantic?,
        keep_going: opts.keep_going?, engine_timeout: opts.engine_timeout, control: opts.control?).run
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
  rescue e : PodmanProvisionError
    STDERR.puts "error: #{e.message}"
    1
  rescue e : AtlanticProvisionError
    STDERR.puts "error: #{e.message}"
    1
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
                         "chaos=#{opts.chaos_percentage}%, seed=#{opts.seed})")
    schemas = SchemaScanner.new(opts.modules, all_modules: opts.all_modules?, supported_community: supported).scan
    chaos_kinds = Options.parse_chaos_kinds(opts.chaos_kinds)
    tasks = [] of GeneratedTask
    schemas.each do |schema|
      tasks.concat(Generator.new(opts.seed, opts.chaos_percentage, chaos_kinds).generate(schema, opts.count))
    end
    Log.info("generate", "building #{tasks.size} playbook(s) into #{opts.out_dir}")
    playbooks = PlaybookBuilder.new(opts.out_dir).build(tasks)
    run_generated(opts, playbooks)
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
      opts.krikri_bin, run_on_podman: opts.run_on_podman?, run_on_atlantic: opts.run_on_atlantic?,
      keep_going: opts.keep_going?, engine_timeout: opts.engine_timeout, control: opts.control?).run
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
      puts "[#{verdict}] #{result.playbook}"
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
