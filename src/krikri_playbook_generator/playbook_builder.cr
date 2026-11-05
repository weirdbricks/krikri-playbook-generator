require "json"
require "./generator"

module KrikriPlaybookGenerator
  # Assembles generated tasks into playbook YAML. Two shapes:
  #
  # - v1 single-task (default): one play, one task per module per
  #   playbook, `register: krikri_playbook_generator_result`.
  # - v2 multi-task (`build_scenarios`): one play with several tasks from
  #   DIFFERENT modules, each registering `kpg_task_<i>`, later tasks
  #   gated by `when:` on the previous register, optionally iterating a
  #   `loop:` over the fixture sources, and optionally notifying a shared
  #   play-level handler - the multi-task interaction fuzzing the
  #   proposal deferred to v2. The `.meta.json` sidecar keeps the
  #   first task's module as top-level `module` (runner profile
  #   selection and triage keep working unchanged) and adds a `modules`
  #   array carrying each task's own module/chaos/mutations/wiring.
  class PlaybookBuilder
    # Only files this tool itself generates (in the current batch naming
    # convention, directly inside @out_dir) are cleared before a rebuild;
    # nothing else in the directory is touched.
    STALE_PLAYBOOK = /\A\d{6}-.+-(?:happy|chaos)\.yml\z/
    STALE_META     = /\A\d{6}-.+-(?:happy|chaos)\.meta\.json\z/

    HANDLER_NAME    = "kpg handler"
    HANDLER_MESSAGE = "kpg multi-task handler ran"

    def initialize(@out_dir : String, @seed : Int32? = nil)
    end

    # First-line provenance comment: since the default seed is random,
    # the playbook file itself must carry the seed that produced it.
    private def seed_comment : String
      seed = @seed
      seed ? "# krikri-playbook-generator seed=#{seed}\n" : ""
    end

    def build(tasks : Array(GeneratedTask)) : Array(String)
      Dir.mkdir_p(@out_dir)
      remove_stale_outputs
      tasks.map_with_index { |task, index| write_playbook(task, index) }
    end

    def build_scenarios(scenarios : Array(Array(GeneratedTask))) : Array(String)
      Dir.mkdir_p(@out_dir)
      remove_stale_outputs
      scenarios.map_with_index { |tasks, index| write_scenario(tasks, index) }
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

      File.write(playbook_path, "#{seed_comment}#{playbook_yaml(task, index)}")
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

    private def write_scenario(tasks : Array(GeneratedTask), index : Int32) : String
      chaos = tasks.any?(&.chaos?)
      basename = "#{index.to_s.rjust(6, '0')}-multi-#{tasks.first.module_name}-#{chaos ? "chaos" : "happy"}"
      playbook_path = File.join(@out_dir, "#{basename}.yml")
      meta_path = File.join(@out_dir, "#{basename}.meta.json")

      File.write(playbook_path, "#{seed_comment}#{scenario_yaml(tasks, index)}")
      File.write(meta_path, scenario_metadata_json(tasks, playbook_path))

      playbook_path
    end

    private def scenario_yaml(tasks : Array(GeneratedTask), index : Int32) : String
      task_bodies = tasks.map_with_index do |task, task_index|
        body = {} of YAML::Any => YAML::Any
        body[YAML::Any.new("name")] = YAML::Any.new("#{task.module_name} ##{index}.#{task_index}")
        body[YAML::Any.new(task.fqcn)] = task.free_form ? YAML::Any.new(task.free_form) : scenario_args(task)
        body[YAML::Any.new("register")] = YAML::Any.new("kpg_task_#{task_index}")
        body[YAML::Any.new("ignore_errors")] = YAML::Any.new(true)
        body[YAML::Any.new("when")] = YAML::Any.new(task.when_condition) if task.when_condition
        if task.loop_option && (items = task.loop_items)
          body[YAML::Any.new("loop")] = YAML::Any.new(items.map { |item| YAML::Any.new(item) })
        end
        body[YAML::Any.new("notify")] = YAML::Any.new(task.notify) if task.notify
        YAML::Any.new(body)
      end

      play = {} of YAML::Any => YAML::Any
      play[YAML::Any.new("name")] = YAML::Any.new("krikri-playbook-generator: multi-task ##{index}")
      play[YAML::Any.new("hosts")] = YAML::Any.new("all")
      play[YAML::Any.new("gather_facts")] = YAML::Any.new(false)
      play[YAML::Any.new("tasks")] = YAML::Any.new(task_bodies)
      if tasks.any?(&.notify)
        handler = {} of YAML::Any => YAML::Any
        handler[YAML::Any.new("name")] = YAML::Any.new(HANDLER_NAME)
        handler_args = {} of YAML::Any => YAML::Any
        handler_args[YAML::Any.new("msg")] = YAML::Any.new(HANDLER_MESSAGE)
        handler[YAML::Any.new("ansible.builtin.debug")] = YAML::Any.new(handler_args)
        play[YAML::Any.new("handlers")] = YAML::Any.new([YAML::Any.new(handler)])
      end

      YAML::Any.new([YAML::Any.new(play)]).to_yaml
    end

    private def scenario_args(task : GeneratedTask) : YAML::Any
      args = {} of YAML::Any => YAML::Any
      task.args.each { |name, value| args[YAML::Any.new(name)] = value }
      YAML::Any.new(args)
    end

    private def scenario_metadata_json(tasks : Array(GeneratedTask), playbook_path : String) : String
      JSON.build do |json|
        json.object do
          json.field "playbook", playbook_path
          json.field "module", tasks.first.module_name
          json.field "collection", tasks.first.collection
          json.field "chaos", tasks.any?(&.chaos?)
          json.field "mutations" do
            json.array do
              tasks.each_with_index do |task, task_index|
                task.mutations.each do |(name, kind)|
                  json.object do
                    json.field "option", "t#{task_index}:#{name}"
                    json.field "kind", kind.to_s
                  end
                end
              end
            end
          end
          json.field "modules" do
            json.array do
              tasks.each do |task|
                json.object do
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
                  json.field "wiring", wiring_descriptions(task)
                end
              end
            end
          end
        end
      end
    end

    private def wiring_descriptions(task : GeneratedTask) : Array(String)
      wiring = [] of String
      wiring << "when:#{task.when_condition}" if task.when_condition
      wiring << "loop:#{task.loop_option}" if task.loop_option && task.loop_items
      wiring << "notify:#{task.notify}" if task.notify
      wiring
    end
  end
end
