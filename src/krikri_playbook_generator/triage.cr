require "json"

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
  #   first error line explaining why.
  # - `rates`: per-module byte-identical rate over all compared playbooks.
  class Triage
    record MutationEntry, option : String, kind : String
    record ResultLine, playbook : String, module_name : String, chaos : Bool,
      divergent : Bool, signature : String?, ansible_failed : Bool, ansible_error : String?,
      mutations : Array(MutationEntry), errored : Bool
    record Finding, module_name : String, signature : String?, playbooks : Array(String),
      example_mutations : Array(MutationEntry) do
      def count : Int32
        playbooks.size
      end
    end
    record Quality, module_name : String, failed : Int32, total : Int32, example_error : String
    record Rate, module_name : String, identical : Int32, total : Int32

    def initialize(@results_dir : String)
    end

    def report : Array(Finding)
      groups = {} of {String, String?} => Array(ResultLine)

      lines.each do |line|
        next unless line.divergent

        key = {line.module_name, line.signature}
        (groups[key] ||= [] of ResultLine) << line
      end

      groups.map do |(module_name, signature), entries|
        playbooks = entries.map(&.playbook).uniq
        Finding.new(module_name, signature, playbooks, entries.first.mutations)
      end.sort_by! { |finding| -finding.count }
    end

    def quality : Array(Quality)
      groups = Hash(String, Array(ResultLine)).new { |hash, key| hash[key] = [] of ResultLine }

      lines.each do |line|
        next if line.chaos || line.errored
        next unless line.ansible_failed

        groups[line.module_name] << line
      end

      groups.map do |module_name, entries|
        total = lines.count { |line| !line.chaos && !line.errored && line.module_name == module_name }
        Quality.new(module_name, entries.size, total, entries.first.ansible_error || "unknown error")
      end.sort_by! { |quality| -quality.failed }
    end

    def rates : Array(Rate)
      groups = Hash(String, Array(ResultLine)).new { |hash, key| hash[key] = [] of ResultLine }

      lines.each do |line|
        next if line.errored

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

    private def lines : Array(ResultLine)
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
      return nil unless playbook && module_name

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
        errored
      )
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
