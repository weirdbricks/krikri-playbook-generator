require "./krikri_playbook_generator/**"

module KrikriPlaybookGenerator
  VERSION = "0.0.5"

  def self.main(argv : Array(String)) : Int32
    opts = Options.parse(argv)

    case opts.command
    in Command::Generate
      Preflight.check!(opts.ansible_playbook_bin, opts.krikri_bin)
      schemas = SchemaScanner.new(opts.modules).scan
      tasks = [] of GeneratedTask
      schemas.each do |schema|
        tasks.concat(Generator.new(opts.seed, opts.chaos_percentage).generate(schema, opts.count))
      end
      playbooks = PlaybookBuilder.new(opts.out_dir).build(tasks)

      if opts.run_on_podman?
        results = Runner.new(playbooks, opts.results_dir, opts.atlantic_hosts, opts.ansible_playbook_bin,
          opts.krikri_bin, run_on_podman: true).run
        print_run_summary(results)
        print_findings(Triage.new(opts.results_dir).report)
      end
    in Command::Run
      Preflight.check!(opts.ansible_playbook_bin, opts.krikri_bin)
      playbooks = Dir.glob("#{opts.out_dir}/**/*.yml")
      Runner.new(playbooks, opts.results_dir, opts.atlantic_hosts, opts.ansible_playbook_bin,
        opts.krikri_bin, check_mode: !opts.allow_mutation?, run_on_podman: opts.run_on_podman?).run
    in Command::Report
      print_findings(Triage.new(opts.results_dir).report)
    end
    0
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

  private def self.print_run_summary(results : Array(Runner::PlaybookResult)) : Nil
    results.each do |result|
      verdict = result.divergent? ? "DIVERGENT" : "IDENTICAL"
      puts "[#{verdict}] #{result.playbook}"
    end
  end

  private def self.print_findings(findings : Array(Triage::Finding)) : Nil
    if findings.empty?
      puts "No divergences found."
      return
    end

    findings.each do |finding|
      label = finding.chaos_kind ? "#{finding.chaos_kind} #{finding.option}" : "happy-path"
      puts "#{finding.module_name} (#{label}): #{finding.count} divergent playbook(s)"
      finding.playbooks.each { |playbook| puts "  - #{playbook}" }
    end
  end
end

exit(KrikriPlaybookGenerator.main(ARGV))
