require "json"
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
    record ResultLine, playbook : String, module_name : String, chaos : Bool,
      divergent : Bool, signature : String?, ansible_failed : Bool, ansible_error : String?,
      mutations : Array(MutationEntry), error : String?, masked_diff : String do
      def errored? : Bool
        !error.nil?
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

    def initialize(@results_dir : String, @overrides : Overrides = Overrides.load)
    end

    def report : Array(Finding)
      findings_from(result_lines)
    end

    def findings_from(lines : Array(ResultLine)) : Array(Finding)
      groups = {} of {String, String?} => Array(ResultLine)

      lines.each do |line|
        next unless line.divergent

        key = {line.module_name, line.signature}
        (groups[key] ||= [] of ResultLine) << line
      end

      groups.map do |(module_name, signature), entries|
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
          json.field "findings" do
            json.array do
              findings_from(lines).each { |finding| finding_json(json, finding) }
            end
          end
          json.field "errors" do
            json.array do
              lines.select(&.errored?).each { |line| error_json(json, line) }
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
        next if @overrides.expect_failure?(line.module_name)
        next unless line.ansible_failed

        groups[line.module_name] << line
      end

      groups.map do |module_name, entries|
        total = lines.count do |line|
          !line.chaos && !line.errored? && line.module_name == module_name
        end
        Quality.new(module_name, entries.size, total, entries.first.ansible_error || "unknown error")
      end.sort_by! { |quality| -quality.failed }
    end

    # Modules seen in the results that the override table marks as
    # intentionally failing - reported alongside the quality section so
    # the exclusion is visible rather than silent.
    def expected_failures : Array(String)
      result_lines.map(&.module_name).uniq!.select { |name| @overrides.expect_failure?(name) }.sort!
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
        Rate.new(module_name, entries.count { |line| !line.divergent }, entries.size)
      end.sort_by!(&.module_name)
    end

    # Copy-paste repro for a single divergent playbook: `run` accepts a
    # playbook file path directly and re-runs it in a fresh container pair.
    def self.repro_command(playbook_path : String) : String
      "krikri-playbook-generator run #{playbook_path} --run-on-podman --results-dir /tmp/kpg-repro"
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

      ResultLine.new(
        playbook, module_name,
        parsed["chaos"]?.try(&.as_bool?) || false,
        parsed["divergent"]?.try(&.as_bool?) || false,
        parsed["signature"]?.try(&.as_s?),
        parsed["ansible_failed"]?.try(&.as_bool?) || false,
        parsed["ansible_error"]?.try(&.as_s?),
        mutations,
        errored ? error_field.try(&.as_s?) : nil,
        parse_masked_diff(parsed)
      )
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
