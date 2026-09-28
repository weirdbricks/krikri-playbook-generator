require "./krikri_playbook_generator/**"

module KrikriPlaybookGenerator
  VERSION = "0.0.1"

  def self.main(argv : Array(String)) : Int32
    opts = Options.parse(argv)

    case opts.command
    in Command::Generate
      schemas = SchemaScanner.new(opts.modules).scan
      tasks = schemas.flat_map do |schema|
        Generator.new(opts.seed, opts.chaos_percentage).generate(schema, opts.count)
      end
      PlaybookBuilder.new(opts.out_dir).build(tasks)
    in Command::Run
      Runner.new(Dir.glob("#{opts.out_dir}/**/*.yml"), opts.results_dir, opts.atlantic_hosts).run
    in Command::Report
      Triage.new(opts.results_dir).report
    end
    0
  rescue e : InvalidOptionsError
    STDERR.puts "error: #{e.message}"
    1
  end
end

exit(KrikriPlaybookGenerator.main(ARGV))
