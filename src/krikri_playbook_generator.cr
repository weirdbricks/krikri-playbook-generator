require "./krikri_playbook_generator/**"

module KrikriPlaybookGenerator
  VERSION = "0.0.8"

  def self.main(argv : Array(String)) : Int32
    opts = Options.parse(argv)

    case opts.command
    in Command::Generate
      Preflight.check!(opts.ansible_playbook_bin, opts.krikri_bin)
      schemas = SchemaScanner.new(opts.modules).scan
      chaos_kinds = Options.parse_chaos_kinds(opts.chaos_kinds)
      tasks = [] of GeneratedTask
      schemas.each do |schema|
        tasks.concat(Generator.new(opts.seed, opts.chaos_percentage, chaos_kinds).generate(schema, opts.count))
      end
      playbooks = PlaybookBuilder.new(opts.out_dir).build(tasks)

      if opts.run_on_podman?
        results = Runner.new(playbooks, opts.results_dir, opts.atlantic_hosts, opts.ansible_playbook_bin,
          opts.krikri_bin, run_on_podman: true, keep_going: opts.keep_going?,
          engine_timeout: opts.engine_timeout).run
        print_run_summary(results)
        print_full_report(Triage.new(opts.results_dir))
        divergences?(results) ? 1 : 0
      else
        0
      end
    in Command::Run
      Preflight.check!(opts.ansible_playbook_bin, opts.krikri_bin)
      playbooks = playbook_paths_for_run(opts)
      results = Runner.new(playbooks, opts.results_dir, opts.atlantic_hosts, opts.ansible_playbook_bin,
        opts.krikri_bin, check_mode: !opts.allow_mutation?, run_on_podman: opts.run_on_podman?,
        keep_going: opts.keep_going?, engine_timeout: opts.engine_timeout).run
      print_run_summary(results)
      divergences?(results) ? 1 : 0
    in Command::Report
      triage = Triage.new(opts.results_dir)
      print_full_report(triage)
      triage.report.empty? ? 0 : 1
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

  private def self.print_full_report(triage : Triage) : Nil
    print_divergences(triage.report)
    print_quality(triage.quality, triage.expected_failures)
    print_rates(triage.rates)
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

  private def self.print_quality(quality : Array(Triage::Quality), expected_failures : Array(String)) : Nil
    puts "== Generator quality (happy-path failures on real ansible) =="
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
  end

  private def self.print_rates(rates : Array(Triage::Rate)) : Nil
    puts "== Per-module byte-identical rate (masked comparison) =="
    rates.each do |rate|
      puts "#{rate.module_name}: #{rate.identical}/#{rate.total} byte-identical"
    end
  end
end

exit(KrikriPlaybookGenerator.main(ARGV))
