require "json"
require "./generator"

module KrikriPlaybookGenerator
  # Assembles generated tasks into playbook YAML, one task per module per
  # play (v1 scope per KRIKRI_PLAYBOOK_GENERATOR.md: single-task-per-module
  # playbooks, like krikri's own testing/test-*-quick.yml fixtures —
  # multi-task interaction fuzzing is a v2 concern, not this one), plus a
  # `.meta.json` sidecar per playbook carrying the module/mutation
  # metadata Triage needs (the playbook YAML alone doesn't say which slots
  # were mutated or how).
  class PlaybookBuilder
    # Only files this tool itself generates (in the current batch naming
    # convention, directly inside @out_dir) are cleared before a rebuild;
    # nothing else in the directory is touched.
    STALE_PLAYBOOK = /\A\d{6}-.+-(?:happy|chaos)\.yml\z/
    STALE_META     = /\A\d{6}-.+-(?:happy|chaos)\.meta\.json\z/

    def initialize(@out_dir : String)
    end

    def build(tasks : Array(GeneratedTask)) : Array(String)
      Dir.mkdir_p(@out_dir)
      remove_stale_outputs
      tasks.map_with_index { |task, index| write_playbook(task, index) }
    end

    private def remove_stale_outputs : Nil
      Dir.each_child(@out_dir) do |name|
        next unless name.matches?(STALE_PLAYBOOK) || name.matches?(STALE_META)
        next unless File.file?(File.join(@out_dir, name))

        File.delete(File.join(@out_dir, name))
      end
    end

    private def write_playbook(task : GeneratedTask, index : Int32) : String
      basename = "#{index.to_s.rjust(6, '0')}-#{task.module_name}-#{task.chaos? ? "chaos" : "happy"}"
      playbook_path = File.join(@out_dir, "#{basename}.yml")
      meta_path = File.join(@out_dir, "#{basename}.meta.json")

      File.write(playbook_path, playbook_yaml(task, index))
      File.write(meta_path, metadata_json(task, playbook_path))

      playbook_path
    end

    private def playbook_yaml(task : GeneratedTask, index : Int32) : String
      args = {} of YAML::Any => YAML::Any
      task.args.each { |name, value| args[YAML::Any.new(name)] = value }

      task_body = {} of YAML::Any => YAML::Any
      task_body[YAML::Any.new("name")] = YAML::Any.new("#{task.module_name} ##{index}")
      task_body[YAML::Any.new(task.fqcn)] = task.free_form ? YAML::Any.new(task.free_form) : YAML::Any.new(args)
      task_body[YAML::Any.new("register")] = YAML::Any.new("krikri_playbook_generator_result")
      task_body[YAML::Any.new("ignore_errors")] = YAML::Any.new(true)

      play = {} of YAML::Any => YAML::Any
      play[YAML::Any.new("name")] = YAML::Any.new("krikri-playbook-generator: #{task.module_name} ##{index}")
      play[YAML::Any.new("hosts")] = YAML::Any.new("all")
      play[YAML::Any.new("gather_facts")] = YAML::Any.new(false)
      play[YAML::Any.new("tasks")] = YAML::Any.new([YAML::Any.new(task_body)])

      YAML::Any.new([YAML::Any.new(play)]).to_yaml
    end

    private def metadata_json(task : GeneratedTask, playbook_path : String) : String
      JSON.build do |json|
        json.object do
          json.field "playbook", playbook_path
          json.field "module", task.module_name
          json.field "collection", task.collection
          json.field "chaos", task.chaos?
          json.field "mutations" do
            json.array do
              task.mutations.each do |(name, kind)|
                json.object do
                  json.field "option", name
                  json.field "kind", kind.to_s
                end
              end
            end
          end
        end
      end
    end
  end
end
