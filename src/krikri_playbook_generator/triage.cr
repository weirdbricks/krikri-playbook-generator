require "json"
require "./masks"
require "./host_state"
require "./run_mode"
require "./microvm_backend"
require "./overrides"

module KrikriPlaybookGenerator
  class TriageError < Exception
  end

  # Reads `results.jsonl` (Runner's output) and produces three report
  # sections:
  #
  # - `report`: divergences grouped by module + diff SIGNATURE. The
  #   signature (ByteDiff#signature - changed lines with digits/paths/
  #   random names generalized, hashed) is the root-cause key: N playbooks
  #   whose masked diffs shape to the same hash are one bug to fix, not N.
  #   Each finding carries its count, one example playbook path and a
  #   copy-paste repro command for it.
  # - `quality`: generator-quality metric - per module, how many
  #   happy-path playbooks FAILED on real ansible (wasted coverage: real
  #   ansible is the reference engine, so if the reference can't even run
  #   the generated task, comparing engines tells you nothing) and the
  #   first error line explaining why. Modules whose whole purpose is to
  #   fail (`fail`) carry an `expect_failure` override and are left out -
  #   see `expected_failures`.
  # - `rates`: per-module byte-identical rate over all compared playbooks.
  class Triage
    record MutationEntry, option : String, kind : String
    record ResultLine, playbook : String, module_name : String, mode : String, run : Int32,
      chaos : Bool, divergent : Bool, signature : String?, ansible_failed : Bool,
      ansible_error : String?, mutations : Array(MutationEntry), error : String?,
      masked_diff : String, masked_identical : Bool, state_divergent : Bool,
      state_signature : String?, state_diff : String do
      def errored? : Bool
        !error.nil?
      end

      # The playbook differs on printed output (the byte-for-byte engine
      # comparison), not just on host state.
      def output_divergent? : Bool
        divergent && !masked_identical
      end
    end
    record Finding, module_name : String, signature : String?, playbooks : Array(String),
      example_mutations : Array(MutationEntry), example : ResultLine do
      def count : Int32
        playbooks.size
      end
    end
    record Quality, module_name : String, failed : Int32, total : Int32, example_error : String
    record Rate, module_name : String, identical : Int32, total : Int32

    # Batch-level happy-path runnability: how many generated happy-path
    # playbooks the REFERENCE engine could actually run. A failed one is
    # wasted coverage - there is no success-path comparison to make - so
    # this is the metric `--min-happy-success` gates on.
    record HappyCoverage, attempted : Int32, failed : Int32 do
      def succeeded : Int32
        attempted - failed
      end

      def success_rate : Float64
        return 100.0 if attempted.zero?

        succeeded.to_f / attempted * 100.0
      end
    end

    def initialize(@results_dir : String, @overrides : Overrides = Overrides.load)
    end

    def report : Array(Finding)
      findings_from(result_lines)
    end

    # State-only findings: the engines printed the same thing but left the
    # host in a different state. Kept apart from the stdout findings so a
    # playbook that differs on both is counted once (in `report`), not
    # twice.
    def state_report : Array(Finding)
      state_findings_from(result_lines)
    end

    def findings_from(lines : Array(ResultLine)) : Array(Finding)
      groups = {} of {String, String, Int32, String?} => Array(ResultLine)

      lines.each do |line|
        next unless line.output_divergent?

        key = {line.module_name, line.mode, line.run, line.signature}
        (groups[key] ||= [] of ResultLine) << line
      end

      groups.map do |(module_name, _mode, _run, signature), entries|
        playbooks = entries.map(&.playbook).uniq!
        Finding.new(module_name, signature, playbooks, entries.first.mutations, entries.first)
      end.sort_by! { |finding| -finding.count }
    end

    def state_findings_from(lines : Array(ResultLine)) : Array(Finding)
      groups = {} of {String, String, Int32, String?} => Array(ResultLine)

      lines.each do |line|
        next unless line.state_divergent
        next if line.output_divergent? || line.errored?

        key = {line.module_name, line.mode, line.run, line.state_signature}
        (groups[key] ||= [] of ResultLine) << line
      end

      groups.map do |(module_name, _mode, _run, signature), entries|
        playbooks = entries.map(&.playbook).uniq!
        Finding.new(module_name, signature, playbooks, entries.first.mutations, entries.first)
      end.sort_by! { |finding| -finding.count }
    end

    # Single-object JSON rendering of the whole report for machine
    # consumption (`report --json`); one JSON object on stdout, warnings on
    # stderr, exit code unchanged.
    def report_json : String
      lines = result_lines

      JSON.build do |json|
        json.object do
          json.field "results_dir", Path[@results_dir].expand.to_s
          json.field "total", lines.size
          json.field "errored", lines.count(&.errored?)
          json.field "divergent", lines.count(&.divergent)
          json.field "state_divergent", lines.count(&.state_divergent)
          info = batch_info
          json.field "batch" do
            json.object do
              json.field "modes", info[:modes]
              json.field "duration", info[:duration]
              json.field "second_run", info[:second_run]
              json.field "diff", info[:diff]
            end
          end
          json.field "findings" do
            json.array do
              findings_from(lines).each { |finding| finding_json(json, finding) }
            end
          end
          json.field "state_findings" do
            json.array do
              state_findings_from(lines).each { |finding| finding_json(json, finding) }
            end
          end
          json.field "errors" do
            json.array do
              lines.select(&.errored?).each { |line| error_json(json, line) }
            end
          end
          json.field "not_applicable" do
            json.array do
              lines.map(&.module_name).uniq!.select { |name| @overrides.not_applicable?(name) }.sort!.each { |name| json.string(name) }
            end
          end
          coverage = happy_coverage_from(lines)
          json.field "happy_coverage" do
            json.object do
              json.field "attempted", coverage.attempted
              json.field "failed", coverage.failed
              json.field "succeeded", coverage.succeeded
              json.field "success_percent", coverage.success_rate.round(1)
            end
          end
          json.field "rates" do
            json.array do
              rates_from(lines).each { |rate| rate_json(json, rate) }
            end
          end
        end
      end
    end

    private def finding_json(json : JSON::Builder, finding : Finding) : Nil
      json.object do
        json.field "module", finding.module_name
        json.field "kind", finding.signature.try(&.starts_with?("state:")) ? "state" : "output"
        if signature = finding.signature
          json.field "signature", signature
        else
          json.field "signature", nil
        end
        json.field "count", finding.count
        json.field "playbooks" do
          json.array { finding.playbooks.each { |path| json.scalar path } }
        end
        json.field "example" do
          example = finding.example
          json.object do
            json.field "playbook", example.playbook
            json.field "mode", example.mode
            json.field "run", example.run
            json.field "chaos", example.chaos
            json.field "mutations" do
              json.array do
                example.mutations.each do |mutation|
                  json.object do
                    json.field "option", mutation.option
                    json.field "kind", mutation.kind
                  end
                end
              end
            end
            json.field "masked_diff", example.masked_diff
            json.field "state_diff", example.state_diff.empty? ? nil : example.state_diff
            if error = example.ansible_error
              json.field "ansible_error", error
            else
              json.field "ansible_error", nil
            end
          end
        end
      end
    end

    private def error_json(json : JSON::Builder, line : ResultLine) : Nil
      json.object do
        json.field "playbook", line.playbook
        json.field "module", line.module_name
        json.field "error", line.error
      end
    end

    private def rate_json(json : JSON::Builder, rate : Rate) : Nil
      json.object do
        json.field "module", rate.module_name
        json.field "identical", rate.identical
        json.field "total", rate.total
      end
    end

    def quality : Array(Quality)
      lines = result_lines
      groups = Hash(String, Array(ResultLine)).new { |hash, key| hash[key] = [] of ResultLine }

      lines.each do |line|
        next if line.chaos || line.errored?
        next if line.run > 1
        next if @overrides.expect_failure?(line.module_name)
        next if @overrides.not_applicable?(line.module_name)
        next unless line.ansible_failed

        groups[line.module_name] << line
      end

      groups.map do |module_name, entries|
        total = lines.count do |line|
          !line.chaos && !line.errored? && line.run == 1 && line.module_name == module_name
        end
        Quality.new(module_name, entries.size, total, entries.first.ansible_error || "unknown error")
      end.sort_by! { |quality| -quality.failed }
    end

    # Batch-level version of the quality metric, counting every happy-path
    # playbook (all modules together) the reference engine ran or failed.
    def happy_coverage : HappyCoverage
      happy_coverage_from(result_lines)
    end

    private def happy_coverage_from(lines : Array(ResultLine)) : HappyCoverage
      attempted = 0
      failed = 0
      lines.each do |line|
        next if line.chaos || line.errored?
        # A second-run row re-runs an already counted playbook: it measures
        # idempotency, not whether the reference engine can run the task.
        next if line.run > 1
        next if @overrides.expect_failure?(line.module_name)
        next if @overrides.not_applicable?(line.module_name)

        attempted += 1
        failed += 1 if line.ansible_failed
      end
      HappyCoverage.new(attempted, failed)
    end

    # Modules seen in the results that the override table marks as
    # intentionally failing - reported alongside the quality section so
    # the exclusion is visible rather than silent.
    def expected_failures : Array(String)
      result_lines.map(&.module_name).uniq!.select { |name| @overrides.expect_failure?(name) }.sort!
    end

    # Modules that a single-task local playbook cannot exercise at all
    # (reboot, apt_key) - excluded from the coverage metric for the same
    # reason, and reported so the exclusion stays visible.
    def not_applicable_modules : Array(String)
      result_lines.map(&.module_name).uniq!.select { |name| @overrides.not_applicable?(name) }.sort!
    end

    # Provenance written next to results.jsonl by Runner: which mode matrix
    # the batch covered, whether the second-run pass was on, and how long
    # the batch took (so the cost of both is visible in the report).
    # `diff` defaults to false for a legacy versions.txt written before the
    # flag was recorded: those batches never passed --diff, so a repro of
    # one has to skip it too or it compares different bytes.
    def batch_info : NamedTuple(modes: Array(String), duration: String?, second_run: Bool, diff: Bool)
      path = File.join(@results_dir, "versions.txt")
      modes = [] of String
      duration = nil
      second_run = false
      diff = false
      if File.exists?(path)
        File.each_line(path) do |line|
          key, value = line.split(": ", 2)
          next unless value
          case key
          when "modes"          then modes = value.split(',').map(&.strip)
          when "batch duration" then duration = value.strip
          when "idempotency"    then second_run = value.strip == "true"
          when "diff"           then diff = value.strip == "true"
          end
        end
      end
      {modes: modes, duration: duration, second_run: second_run, diff: diff}
    end

    def rates : Array(Rate)
      rates_from(result_lines)
    end

    private def rates_from(lines : Array(ResultLine)) : Array(Rate)
      groups = Hash(String, Array(ResultLine)).new { |hash, key| hash[key] = [] of ResultLine }

      lines.each do |line|
        next if line.errored?

        groups[line.module_name] << line
      end

      groups.map do |module_name, entries|
        Rate.new(module_name, entries.count(&.masked_identical), entries.size)
      end.sort_by!(&.module_name)
    end

    # Copy-paste repro for a single divergent playbook: `run` accepts a
    # playbook file path directly and re-runs it in a fresh host pair. The
    # backend must be one that can host the playbook's module at all - a
    # database or container module needs the microVM path, and sending it to
    # podman would "reproduce" nowhere.
    def self.repro_command(playbook_path : String, module_names : Array(String) = [] of String,
                           mode : String? = nil, run : Int32 = 1, diff : Bool = true) : String
      backend = MicrovmBackend.microvm_only?(module_names) ? "--run-on-mixed" : "--run-on-podman"
      command = "krikri-playbook-generator run #{playbook_path} #{backend} --results-dir /tmp/kpg-repro"
      command += " --modes #{mode}" if mode && mode.in?(%w[check real])
      command += " --no-second-run" if run <= 1
      command += " --no-diff" unless diff
      command
    end

    private def result_lines : Array(ResultLine)
      collected = [] of ResultLine

      skipped = 0
      each_results_line do |line|
        parsed = begin
          JSON.parse(line).as_h?
        rescue JSON::ParseException
          skipped += 1
          nil
        end
        next unless parsed

        result = parse_result_line(parsed)
        collected << result if result
      end

      STDERR.puts "warning: skipped #{skipped} malformed results.jsonl line(s)" if skipped.positive?
      collected
    end

    private def parse_result_line(parsed : Hash(String, JSON::Any)) : ResultLine?
      playbook = parsed["playbook"]?.try(&.as_s?)
      module_name = parsed["module"]?.try(&.as_s?)
      return unless playbook && module_name

      mutations = parsed["mutations"]?.try(&.as_a?).try do |entries|
        entries.compact_map do |entry|
          entry_hash = entry.as_h?
          next unless entry_hash

          option = entry_hash["option"]?.try(&.as_s?)
          kind = entry_hash["kind"]?.try(&.as_s?)
          MutationEntry.new(option, kind) if option && kind
        end
      end || [] of MutationEntry

      error_field = parsed["error"]?
      errored = error_field ? !error_field.raw.nil? : false

      masked_diff = parse_masked_diff(parsed)
      divergent = parsed["divergent"]?.try(&.as_bool?) || false
      masked_identical, state_divergent, state_signature, state_diff = parse_state_fields(parsed, divergent)

      ResultLine.new(
        playbook, module_name,
        parsed["mode"]?.try(&.as_s?) || RunMode::Real.label,
        parsed["run"]?.try(&.as_i?) || 1,
        parsed["chaos"]?.try(&.as_bool?) || false,
        divergent,
        result_signature(masked_diff, parsed),
        parsed["ansible_failed"]?.try(&.as_bool?) || false,
        parsed["ansible_error"]?.try(&.as_s?),
        mutations,
        errored ? error_field.try(&.as_s?) : nil,
        masked_diff,
        masked_identical,
        state_divergent,
        state_signature,
        state_diff
      )
    end

    private def parse_state_fields(parsed : Hash(String, JSON::Any),
                                   divergent : Bool) : {Bool, Bool, String?, String}
      # Legacy lines predate the state oracle, so their divergence can only
      # have come from the printed output.
      masked_identical = parsed["masked_identical"]?.try(&.as_bool?) || !divergent
      state_divergent = parsed["state_divergent"]?.try(&.as_bool?) || false
      state_diff = parsed["state_diff"]?.try(&.as_s?) || ""
      {masked_identical, state_divergent, parse_state_signature(state_diff, parsed), state_diff}
    end

    # Recompute a state signature from the stored diff, same reasoning as
    # result_signature; the stored one is the fallback when there is no diff.
    private def parse_state_signature(state_diff : String, parsed : Hash(String, JSON::Any)) : String?
      stored = parsed["state_signature"]?.try(&.as_s?)
      return stored if state_diff.empty?

      HostState.signature(state_diff) || stored
    end

    # Recompute the signature from the stored masked diff rather than
    # trusting the stored one: signature-shaping rules evolve (e.g.
    # unsupported-parameter name normalization), and recomputing lets
    # already-collected results benefit without re-running them. The
    # stored signature is only a fallback for lines with no diff.
    private def result_signature(masked_diff : String, parsed : Hash(String, JSON::Any)) : String?
      ByteDiff.signature(masked_diff) || parsed["signature"]?.try(&.as_s?)
    end

    private def parse_masked_diff(parsed : Hash(String, JSON::Any)) : String
      parsed.dig?("diff", "masked").try(&.as_s?) || ""
    end

    # A truncated final line (e.g. a batch killed mid-write) is skipped
    # and reported, not fatal: one bad line shouldn't sink the whole
    # report over the results that did parse.
    private def each_results_line(& : String ->) : Nil
      results_path = File.join(@results_dir, "results.jsonl")
      unless File.exists?(results_path)
        raise TriageError.new("no results.jsonl under #{@results_dir.inspect} - run `run` first")
      end

      File.each_line(results_path) do |line|
        yield line unless line.blank?
      end
    end
  end
end
