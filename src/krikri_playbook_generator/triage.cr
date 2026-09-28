require "json"

module KrikriPlaybookGenerator
  class TriageError < Exception
  end

  # Groups divergences by module + chaos-kind + option, deduping to root
  # cause: if N generated playbooks all diverge from the same
  # option/mutation-kind combination on the same module, that's one bug to
  # fix, not N. Reads `results.jsonl` (Runner's output) and, for each
  # divergent playbook, its `.meta.json` sidecar (PlaybookBuilder's
  # output) to learn which module and which mutation(s) produced it — the
  # only place that link is recorded.
  class Triage
    record MutationEntry, option : String, kind : String
    record Meta, module_name : String, collection : String, chaos : Bool, mutations : Array(MutationEntry)
    record Finding, module_name : String, chaos_kind : String?, option : String?, playbooks : Array(String) do
      def count : Int32
        playbooks.size
      end
    end

    def initialize(@results_dir : String)
    end

    def report : Array(Finding)
      groups = {} of {String, String?, String?} => Array(String)

      skipped_lines = each_divergent_playbook do |playbook_path|
        meta = load_meta(playbook_path)
        next unless meta

        if meta.mutations.empty?
          group(groups, meta.module_name, nil, nil, playbook_path)
        else
          meta.mutations.each { |mutation| group(groups, meta.module_name, mutation.kind, mutation.option, playbook_path) }
        end
      end

      if skipped_lines.positive?
        STDERR.puts "warning: skipped #{skipped_lines} malformed results.jsonl line(s)"
      end

      groups.map { |(module_name, kind, option), playbooks| Finding.new(module_name, kind, option, playbooks) }
        .sort_by! { |finding| -finding.count }
    end

    private def group(groups : Hash({String, String?, String?}, Array(String)),
                      module_name : String, kind : String?, option : String?, playbook_path : String) : Nil
      key = {module_name, kind, option}
      (groups[key] ||= [] of String) << playbook_path
    end

    # A truncated final line (e.g. a batch killed mid-write) is skipped
    # and reported, not fatal: one bad line shouldn't sink the whole
    # report over the results that did parse.
    private def each_divergent_playbook(& : String ->) : Int32
      results_path = File.join(@results_dir, "results.jsonl")
      unless File.exists?(results_path)
        raise TriageError.new("no results.jsonl under #{@results_dir.inspect} - run `run` first")
      end

      skipped = 0
      File.each_line(results_path) do |line|
        next if line.blank?

        parsed = begin
          JSON.parse(line).as_h?
        rescue JSON::ParseException
          skipped += 1
          nil
        end
        next unless parsed
        next unless parsed["divergent"]?.try(&.as_bool?)

        playbook_path = parsed["playbook"]?.try(&.as_s?)
        yield playbook_path if playbook_path
      end
      skipped
    end

    private def load_meta(playbook_path : String) : Meta?
      meta_path = playbook_path.sub(/\.yml$/, ".meta.json")
      return unless File.exists?(meta_path)

      parsed = JSON.parse(File.read(meta_path)).as_h?
      return unless parsed

      module_name = parsed["module"]?.try(&.as_s?)
      return unless module_name

      collection = parsed["collection"]?.try(&.as_s?) || "ansible.builtin"
      chaos = parsed["chaos"]?.try(&.as_bool?) || false
      mutations = parsed["mutations"]?.try(&.as_a?).try { |entries| parse_mutations(entries) } || [] of MutationEntry

      Meta.new(module_name, collection, chaos, mutations)
    end

    private def parse_mutations(entries : Array(JSON::Any)) : Array(MutationEntry)
      entries.compact_map do |entry|
        entry_hash = entry.as_h?
        next unless entry_hash

        option = entry_hash["option"]?.try(&.as_s?)
        kind = entry_hash["kind"]?.try(&.as_s?)
        next unless option && kind

        MutationEntry.new(option, kind)
      end
    end
  end
end
