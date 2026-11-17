require "json"
require "file_utils"
require "./generator"
require "./play_keywords"
require "./block_shapes"
require "./handler_shapes"
require "./retry_shapes"
require "./include_shapes"
require "./plugin_shapes"

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

    HANDLER_MESSAGE = "kpg multi-task handler ran"

    # The sibling directory a playbook-relative include shape writes next to
    # the playbook; every backend copies it along with the playbook.
    def self.include_dir(playbook_path : String) : String
      playbook_path.sub(/\.yml\z/, "") + "-inc"
    end

    # The sibling directory a playbook-adjacent plugin row writes next to
    # the playbook. Each backend copies its loader directories into the
    # playbook's working directory, which is where ansible and krikri both
    # look for `lookup_plugins/`, `filter_plugins/` and `strategy_plugins/`.
    def self.plugins_dir(playbook_path : String) : String
      playbook_path.sub(/\.yml\z/, "") + "-plugins"
    end

    # The loader directories of one playbook's plugin layout that actually
    # exist (only the kinds the row needs are written).
    def self.plugin_loader_dirs(playbook_path : String) : Array(String)
      dir = plugins_dir(playbook_path)
      return [] of String unless Dir.exists?(dir)

      dirs = [] of String
      PluginShapes::DIRS.each_value do |name|
        path = File.join(dir, name)
        dirs << path if Dir.exists?(path)
      end
      dirs
    end

    # The play-level variables the lookup and expression shapes render;
    # each is probed through both `debug: var:` and `debug: msg:`.
    LOOKUP_VALUE_VARIABLE     = "kpg_lookup_value"
    LOOKUP_TASK_VARIABLE      = "kpg_lookup_task_value"
    EXPRESSION_VALUE_VARIABLE = "kpg_expr_value"
    STATEMENT_IF_VARIABLE     = "kpg_stmt_if"
    STATEMENT_FOR_VARIABLE    = "kpg_stmt_for"

    # The forced-failure task a block shape adds: a real command that exits
    # non-zero, so the failure path is deterministic and comes from the
    # playbook's own structure rather than from a chaos mutation.
    FAILURE_COMMAND = "/bin/false"
    # The variable a skipped/undefined block-level `when:` reads; the
    # Skipped shape defines it false, the Undefined shape never defines it.
    BLOCK_GATE = "kpg_block_gate"

    # The plugin axes resolved for one playbook row: the sampled lookup and
    # expression shapes, where the plugin files are discovered, and whether
    # the row's play setting names the custom strategy plugin.
    record PluginAxes,
      lookup : LookupShape,
      expression : ExpressionShape,
      discovery : PluginDiscovery,
      strategy : Bool do
      # The plugin types whose files this row must install.
      def kinds : Array(String)
        kinds = [] of String
        kinds << PluginShapes::LOOKUP_KIND unless lookup.off?
        kinds << PluginShapes::FILTER_KIND if expression.custom_filter?
        kinds << PluginShapes::STRATEGY_KIND if strategy
        kinds
      end
    end

    def initialize(@out_dir : String, @seed : Int32? = nil,
                   @play_settings : Array(PlaySetting?) = [] of PlaySetting?,
                   @block_shapes : Array(BlockShape) = [] of BlockShape,
                   @handler_shapes : Array(HandlerShape) = [] of HandlerShape,
                   @retry_shapes : Array(RetryShape) = [] of RetryShape,
                   @gather_facts : Bool = false,
                   @include_shapes : Array(IncludeShape) = [] of IncludeShape,
                   @profiles : Array(Array(String)) = [] of Array(String),
                   @lookup_shapes : Array(LookupShape) = [] of LookupShape,
                   @expression_shapes : Array(ExpressionShape) = [] of ExpressionShape,
                   @plugin_discovery : Array(PluginDiscovery?) = [] of PluginDiscovery?)
    end

    # First-line provenance comment: since the default seed is random,
    # the playbook file itself must carry the seed that produced it.
    private def seed_comment : String
      seed = @seed
      seed ? "# krikri-playbook-generator seed=#{seed}\n" : ""
    end

    # ansible-lint's name[casing] rule wants an uppercase first letter on
    # every play, task and handler name; only the first character is touched
    # so the rest of the name stays exactly as generated.
    private def named(name : String) : String
      name.empty? ? name : name[0].upcase.to_s + name[1..]
    end

    # Crystal's own YAML emitter un-indents a sequence under its key
    # (`tasks:` followed by `- name:` at the same column), which ansible-lint
    # reports as yaml[indentation]. Rendering the document here keeps the
    # scalars exactly as libyaml formats them (same quoting, same escaping)
    # while indenting nested blocks by two, the ansible standard.
    private def yaml_document(node : YAML::Any) : String
      String.build do |io|
        io << "---\n"
        emit(io, node, 0)
      end
    end

    private def emit(io : IO, node : YAML::Any, indent : Int32) : Nil
      raw = node.raw
      case raw
      when Hash
        if raw.empty?
          io << " " * indent << "{}\n"
        else
          emit_map(io, raw, indent)
        end
      when Array
        if raw.empty?
          io << " " * indent << "[]\n"
        else
          emit_sequence(io, raw, indent)
        end
      else
        emit_scalar(io, node, indent, inline_prefix: nil)
      end
    end

    private def emit_map(io : IO, hash : Hash(YAML::Any, YAML::Any), indent : Int32,
                         after_dash : Bool = false) : Nil
      hash.each_with_index do |(key, value), index|
        io << (index == 0 && after_dash ? " " : " " * indent)
        io << scalar_text(key) << ":"
        emit_value(io, value, indent)
      end
    end

    private def emit_sequence(io : IO, array : Array(YAML::Any), indent : Int32) : Nil
      array.each do |element|
        raw = element.raw
        io << " " * indent << "-"
        case raw
        when Hash
          if raw.empty?
            io << " {}\n"
          else
            emit_map(io, raw, indent + 2, after_dash: true)
          end
        when Array
          if raw.empty?
            io << " []\n"
          else
            io << "\n"
            emit(io, element, indent + 2)
          end
        else
          emit_scalar(io, element, indent, inline_prefix: " ")
        end
      end
    end

    private def emit_value(io : IO, value : YAML::Any, indent : Int32) : Nil
      raw = value.raw
      case raw
      when Hash
        if raw.empty?
          io << " {}\n"
        else
          io << "\n"
          emit(io, value, indent + 2)
        end
      when Array
        if raw.empty?
          io << " []\n"
        else
          io << "\n"
          emit(io, value, indent + 2)
        end
      else
        emit_scalar(io, value, indent, inline_prefix: " ")
      end
    end

    private def emit_scalar(io : IO, value : YAML::Any, indent : Int32, inline_prefix : String?) : Nil
      lines = scalar_text(value).lines
      io << inline_prefix.to_s << lines.first
      lines[1..].each do |line|
        io << "\n"
        io << " " * (indent + 2) << line unless line.blank?
      end
      io << "\n"
    end

    # One scalar rendered the way libyaml would (quoting, escaping and
    # multi-line folding all included), minus the `--- ` document start
    # YAML::Any#to_yaml prepends.
    private def scalar_text(value : YAML::Any) : String
      text = value.to_yaml.sub(/\A--- ?/, "").strip
      text.empty? ? "null" : text
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

      write_include_layout(basename, @include_shapes[index]? || IncludeShape::Off)
      write_plugin_layout(basename, plugin_axes(index))
      File.write(playbook_path, "#{seed_comment}#{playbook_yaml(task, index, basename)}")
      File.write(meta_path, metadata_json(task, playbook_path, index))

      playbook_path
    end

    private def playbook_yaml(task : GeneratedTask, index : Int32, basename : String) : String
      args = {} of YAML::Any => YAML::Any
      task.args.each { |name, value| args[YAML::Any.new(name)] = value }

      task_body = {} of YAML::Any => YAML::Any
      task_body[YAML::Any.new("name")] = YAML::Any.new(named("#{task.module_name} ##{index}"))
      task_body[YAML::Any.new(task.fqcn)] = task.free_form ? YAML::Any.new(task.free_form) : YAML::Any.new(args)
      task_body[YAML::Any.new("register")] = YAML::Any.new("krikri_playbook_generator_result")
      task_body[YAML::Any.new("ignore_errors")] = YAML::Any.new(true)
      delegate_fields(task_body, task)

      play = {} of YAML::Any => YAML::Any
      play[YAML::Any.new("name")] = YAML::Any.new(named("krikri-playbook-generator: #{task.module_name} ##{index}"))
      play[YAML::Any.new("hosts")] = YAML::Any.new(HostInventory::GROUP)
      play[YAML::Any.new("gather_facts")] = YAML::Any.new(@gather_facts)
      apply_play_setting(play, @play_settings[index]?)
      play[YAML::Any.new("gather_facts")] = YAML::Any.new(true) if @gather_facts
      shape = @handler_shapes[index]? || HandlerShape::Off
      axes = plugin_axes(index)
      apply_play_vars(play, task, @block_shapes[index]? || BlockShape::None, axes)
      bodies = block_bodies(task_body, task, @block_shapes[index]? || BlockShape::None)
      bodies << notifier_body unless shape.off?
      bodies.concat(retry_bodies(@retry_shapes[index]? || RetryShape::Off))
      include_shape = @include_shapes[index]? || IncludeShape::Off
      bodies.concat(include_task_bodies(include_shape, basename))
      bodies.concat(plugin_task_bodies(axes))
      play[YAML::Any.new("tasks")] = YAML::Any.new(bodies)
      apply_handlers(play, shape)

      document = [YAML::Any.new(play)]
      if include_shape.import_playbook?
        document << YAML::Any.new({YAML::Any.new("ansible.builtin.import_playbook") => YAML::Any.new(Fixtures::CHILD_PLAYBOOK)})
      end
      yaml_document(YAML::Any.new(document))
    end

    private def metadata_json(task : GeneratedTask, playbook_path : String, index : Int32) : String
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
          json.field "choice_sources" do
            json.object { choice_sources_json(json, task) }
          end
          play_setting_json(json, @play_settings[index]?)
          json.field "delegate_to", task.delegate_to
          json.field "delegate_facts", task.delegate_facts? if task.delegate_to
          json.field "block", (@block_shapes[index]? || BlockShape::None).label
          json.field "handlers", (@handler_shapes[index]? || HandlerShape::Off).label
          json.field "retries", (@retry_shapes[index]? || RetryShape::Off).label
          json.field "includes", (@include_shapes[index]? || IncludeShape::Off).label
          plugin_json(json, index)
          json.field "structural_failure", structural_failure?(index)
          json.field "profiles", playbook_profiles(index)
        end
      end
    end

    # The host images this playbook runs on (a distro-polymorphic module
    # runs once per image; see Dependencies.playbook_profiles).
    private def playbook_profiles(index : Int32) : Array(String)
      @profiles[index]? || ["debian"]
    end

    # A shape that deliberately fails (a rescued forced failure, an
    # undefined block condition, a failing/ignoring handler, a
    # never-satisfied retry) makes the play report those signals by design.
    # Runner keeps such a playbook out of the happy-path quality metric -
    # the failure IS the comparison under test - while the byte and state
    # findings still report it.
    private def structural_failure?(index : Int32) : Bool
      block = @block_shapes[index]? || BlockShape::None
      handlers = @handler_shapes[index]? || HandlerShape::Off
      retries = @retry_shapes[index]? || RetryShape::Off
      lookup = @lookup_shapes[index]? || LookupShape::Off
      block.rescue? || block.undefined? || handlers.failing? ||
        handlers.ignoring? || retries.exhausted? || lookup.failing?
    end

    private def choice_sources_json(json : JSON::Builder, task : GeneratedTask) : Nil
      task.choice_sources.each { |name, source| json.field name, source.label }
    end

    private def write_scenario(tasks : Array(GeneratedTask), index : Int32) : String
      chaos = tasks.any?(&.chaos?)
      basename = "#{index.to_s.rjust(6, '0')}-multi-#{tasks.first.module_name}-#{chaos ? "chaos" : "happy"}"
      playbook_path = File.join(@out_dir, "#{basename}.yml")
      meta_path = File.join(@out_dir, "#{basename}.meta.json")

      write_include_layout(basename, @include_shapes[index]? || IncludeShape::Off)
      write_plugin_layout(basename, plugin_axes(index))
      File.write(playbook_path, "#{seed_comment}#{scenario_yaml(tasks, index, basename)}")
      File.write(meta_path, scenario_metadata_json(tasks, playbook_path, index))

      playbook_path
    end

    private def scenario_yaml(tasks : Array(GeneratedTask), index : Int32, basename : String) : String
      task_bodies = tasks.map_with_index do |task, task_index|
        body = {} of YAML::Any => YAML::Any
        body[YAML::Any.new("name")] = YAML::Any.new(named("#{task.module_name} ##{index}.#{task_index}"))
        body[YAML::Any.new(task.fqcn)] = task.free_form ? YAML::Any.new(task.free_form) : scenario_args(task)
        body[YAML::Any.new("register")] = YAML::Any.new("kpg_task_#{task_index}") unless task.static_import?
        body[YAML::Any.new("ignore_errors")] = YAML::Any.new(true)
        body[YAML::Any.new("when")] = YAML::Any.new(task.when_condition) if task.when_condition
        if task.loop_option && (items = task.loop_items)
          body[YAML::Any.new("loop")] = YAML::Any.new(items.map { |item| YAML::Any.new(item) })
        end
        if task.notify_allowed? && (target = task.notify)
          body[YAML::Any.new("notify")] = YAML::Any.new(target)
        end
        delegate_fields(body, task)
        YAML::Any.new(body)
      end

      play = {} of YAML::Any => YAML::Any
      play[YAML::Any.new("name")] = YAML::Any.new(named("krikri-playbook-generator: multi-task ##{index}"))
      play[YAML::Any.new("hosts")] = YAML::Any.new(HostInventory::GROUP)
      play[YAML::Any.new("gather_facts")] = YAML::Any.new(false)
      apply_play_setting(play, @play_settings[index]?)
      apply_delegate_vars(play, tasks, plugin_axes(index))
      apply_scenario_conditions(play, task_bodies, tasks, index, basename)

      document = [YAML::Any.new(play)]
      document.concat(import_playbook_items(@include_shapes[index]? || IncludeShape::Off))
      yaml_document(YAML::Any.new(document))
    end

    private def scenario_args(task : GeneratedTask) : YAML::Any
      args = {} of YAML::Any => YAML::Any
      task.args.each { |name, value| args[YAML::Any.new(name)] = value }
      YAML::Any.new(args)
    end

    private def scenario_metadata_json(tasks : Array(GeneratedTask), playbook_path : String,
                                       index : Int32) : String
      JSON.build do |json|
        json.object do
          json.field "playbook", playbook_path
          json.field "module", tasks.first.module_name
          json.field "collection", tasks.first.collection
          json.field "chaos", tasks.any?(&.chaos?)
          play_setting_json(json, @play_settings[index]?)
          json.field "handlers", (@handler_shapes[index]? || HandlerShape::Off).label
          json.field "retries", (@retry_shapes[index]? || RetryShape::Off).label
          json.field "includes", (@include_shapes[index]? || IncludeShape::Off).label
          plugin_json(json, index)
          json.field "structural_failure", structural_failure?(index)
          json.field "profiles", playbook_profiles(index)
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
                  json.field "choice_sources" do
                    json.object { choice_sources_json(json, task) }
                  end
                  json.field "wiring", wiring_descriptions(task)
                end
              end
            end
          end
        end
      end
    end

    # A play-level keyword goes into the play as a typed scalar (ansible
    # coerces most of them, but a real bool/int also keeps the generated
    # playbook lint-clean and readable). An environment variant writes no
    # play key at all: the runner exports it for both engines, and the
    # sidecar records which door the value used.
    private def apply_play_setting(play : Hash(YAML::Any, YAML::Any), setting : PlaySetting?) : Nil
      return unless setting
      return if setting.env?

      play[YAML::Any.new(setting.keyword)] = play_value(setting)
    end

    private def play_value(setting : PlaySetting) : YAML::Any
      case setting.keyword
      when "any_errors_fatal", "run_once", "gather_facts"
        case setting.value
        when "true"  then YAML::Any.new(true)
        when "false" then YAML::Any.new(false)
        else              YAML::Any.new(setting.value)
        end
      when "serial", "throttle", "max_fail_percentage", "forks"
        setting.value.matches?(/\A\d+\z/) ? YAML::Any.new(setting.value.to_i64) : YAML::Any.new(setting.value)
      else
        YAML::Any.new(setting.value)
      end
    end

    private def play_setting_json(json : JSON::Builder, setting : PlaySetting?) : Nil
      json.field "play", nil unless setting
      return unless setting

      json.field "play" do
        json.object do
          json.field "keyword", setting.keyword
          json.field "value", setting.value
          json.field "source", setting.source
          json.field "env" do
            json.object { setting.env.each { |name, value| json.field name, value } }
          end
        end
      end
    end

    # The play's `vars:` needs the delegate play variable (templated
    # delegation) and/or the block gate (the Skipped shape). Both are
    # defined by the playbook itself so no row inherits them from outside.
    private def apply_play_vars(play : Hash(YAML::Any, YAML::Any), task : GeneratedTask,
                                shape : BlockShape, axes : PluginAxes) : Nil
      vars = {} of YAML::Any => YAML::Any
      if task.delegate_to.try(&.includes?("{{"))
        vars[YAML::Any.new(Generator::DELEGATE_VARIABLE)] = YAML::Any.new(Generator::DELEGATE_HOST)
      end
      vars[YAML::Any.new(BLOCK_GATE)] = YAML::Any.new(false) if shape.skipped?
      plugin_play_vars(axes, vars)
      return if vars.empty?

      play[YAML::Any.new("vars")] = YAML::Any.new(vars)
    end

    # The play's task list for one generated task under a block shape.
    # `None` keeps the flat v1 shape (the task, then its delegation probes).
    private def block_bodies(task_body : Hash(YAML::Any, YAML::Any), task : GeneratedTask,
                             shape : BlockShape) : Array(YAML::Any)
      probes = delegate_probe_bodies(task)
      return [YAML::Any.new(task_body)] + probes if shape.none?

      inner = [YAML::Any.new(task_body)] + probes
      inner << forced_failure_body unless shape.always?
      block = {} of YAML::Any => YAML::Any
      block[YAML::Any.new("name")] = YAML::Any.new("Kpg block")
      block[YAML::Any.new("block")] = YAML::Any.new(inner)
      block[YAML::Any.new("rescue")] = YAML::Any.new([debug_body("Kpg rescue ran", "kpg-rescue")])
      block[YAML::Any.new("always")] = YAML::Any.new([debug_body("Kpg always ran", "kpg-always")])
      block[YAML::Any.new("when")] = YAML::Any.new(block_condition(shape)) unless shape.rescue? || shape.always?
      [YAML::Any.new(block)]
    end

    private def block_condition(shape : BlockShape) : String
      shape.undefined? ? BLOCK_GATE : "#{BLOCK_GATE} | bool"
    end

    private def forced_failure_body : YAML::Any
      body = {} of YAML::Any => YAML::Any
      body[YAML::Any.new("name")] = YAML::Any.new("Kpg forced failure")
      args = {} of YAML::Any => YAML::Any
      args[YAML::Any.new("cmd")] = YAML::Any.new(FAILURE_COMMAND)
      body[YAML::Any.new("ansible.builtin.command")] = YAML::Any.new(args)
      body[YAML::Any.new("changed_when")] = YAML::Any.new(false)
      YAML::Any.new(body)
    end

    private def debug_body(name : String, message : String) : YAML::Any
      debug_task_body(name, "msg", message, ignore_errors: false)
    end

    # A debug task on one key (`msg` or `var`). `ignore_errors` keeps the
    # rest of the row runnable when the probed value fails by design.
    private def debug_task_body(name : String, key : String, value : String,
                                ignore_errors : Bool = true) : YAML::Any
      body = {} of YAML::Any => YAML::Any
      body[YAML::Any.new("name")] = YAML::Any.new(name)
      args = {} of YAML::Any => YAML::Any
      args[YAML::Any.new(key)] = YAML::Any.new(value)
      body[YAML::Any.new("ansible.builtin.debug")] = YAML::Any.new(args)
      body[YAML::Any.new("ignore_errors")] = YAML::Any.new(true) if ignore_errors
      YAML::Any.new(body)
    end

    # A real module consuming a value the axis rendered, so the same
    # expression is compared as a module argument as well as through
    # `debug:`.
    private def module_task_body(name : String, module_name : String,
                                 args : Hash(String, String)) : YAML::Any
      body = {} of YAML::Any => YAML::Any
      body[YAML::Any.new("name")] = YAML::Any.new(name)
      module_args = {} of YAML::Any => YAML::Any
      args.each { |key, value| module_args[YAML::Any.new(key)] = YAML::Any.new(value) }
      body[YAML::Any.new(module_name)] = YAML::Any.new(module_args)
      body[YAML::Any.new("ignore_errors")] = YAML::Any.new(true)
      YAML::Any.new(body)
    end

    # `debug: var:` and `debug: msg:` take different rendering paths, which
    # is exactly where the production expression reports come from.
    private def probe_pair(variable : String, label : String) : Array(YAML::Any)
      [debug_task_body("Kpg #{label} var", "var", variable),
       debug_task_body("Kpg #{label} msg", "msg", "{{ #{variable} }}")]
    end

    private def plugin_axes(index : Int32) : PluginAxes
      lookup = @lookup_shapes[index]? || LookupShape::Off
      expression = @expression_shapes[index]? || ExpressionShape::Off
      setting = @play_settings[index]?
      strategy = setting.try(&.keyword) == "strategy" && setting.try(&.value) == Fixtures::CUSTOM_STRATEGY
      discovery = @plugin_discovery[index]? || PluginDiscovery::Relative
      PluginAxes.new(lookup, expression, discovery, strategy)
    end

    private def plugin_env(axes : PluginAxes) : Hash(String, String)
      Fixtures.plugin_env(axes.discovery, axes.kinds)
    end

    # The play variables the lookup and expression probes render; each one
    # is defined by the playbook itself so no row depends on outside vars.
    private def plugin_play_vars(axes : PluginAxes, vars : Hash(YAML::Any, YAML::Any)) : Nil
      unless axes.lookup.off? || axes.lookup.vars?
        vars[YAML::Any.new(LOOKUP_VALUE_VARIABLE)] = YAML::Any.new(lookup_expression(axes.lookup))
      end

      case axes.expression
      when .off?
      when .statement?
        vars[YAML::Any.new(STATEMENT_IF_VARIABLE)] =
          YAML::Any.new("{% if true %}kpg-true{% else %}kpg-false{% endif %}")
        vars[YAML::Any.new(STATEMENT_FOR_VARIABLE)] =
          YAML::Any.new("{% for item in [1, 2] %}{{ item }}{% endfor %}")
      else
        vars[YAML::Any.new(EXPRESSION_VALUE_VARIABLE)] = YAML::Any.new(expression_value(axes.expression))
      end
    end

    private def plugin_task_bodies(axes : PluginAxes) : Array(YAML::Any)
      bodies = [] of YAML::Any
      bodies.concat(lookup_task_bodies(axes.lookup)) unless axes.lookup.off?
      bodies.concat(expression_task_bodies(axes.expression)) unless axes.expression.off?
      bodies
    end

    private def lookup_expression(shape : LookupShape) : String
      name = case shape
             when .none?        then Fixtures::LOOKUP_NONE
             when .undefined?   then Fixtures::LOOKUP_UNDEFINED
             when .raise?       then Fixtures::LOOKUP_RAISE
             when .side_effect? then Fixtures::LOOKUP_SIDE_EFFECT
             when .unknown?     then Fixtures::LOOKUP_UNKNOWN
             else                    Fixtures::LOOKUP_LIST
             end
      shape.query? ? "{{ query('#{name}') }}" : "{{ lookup('#{name}') }}"
    end

    private def lookup_task_bodies(shape : LookupShape) : Array(YAML::Any)
      return vars_probe_bodies if shape.vars?

      bodies = probe_pair(LOOKUP_VALUE_VARIABLE, "lookup")
      if shape.module_arg?
        bodies << module_task_body("Kpg lookup module arg", "ansible.builtin.copy",
          {"content" => "{{ #{LOOKUP_VALUE_VARIABLE} | join('-') }}",
           "dest"    => "#{Fixtures::WORK_ROOT}/lookup-module-arg.txt"})
      end
      bodies
    end

    # The lookup result through a task-level `vars:` entry, probed by both
    # tasks because each task has to carry the expression itself.
    private def vars_probe_bodies : Array(YAML::Any)
      value = "{{ lookup('#{Fixtures::LOOKUP_LIST}') }}"
      vars = {YAML::Any.new(LOOKUP_TASK_VARIABLE) => YAML::Any.new(value)}
      [{"Kpg lookup task vars var", "var", LOOKUP_TASK_VARIABLE},
       {"Kpg lookup task vars msg", "msg", "{{ #{LOOKUP_TASK_VARIABLE} }}"}].map do |(name, key, probe)|
        body = debug_task_body(name, key, probe)
        raws = body.as_h
        raws[YAML::Any.new("vars")] = YAML::Any.new(vars)
        YAML::Any.new(raws)
      end
    end

    private def expression_task_bodies(shape : ExpressionShape) : Array(YAML::Any)
      case shape
      when .statement?
        [debug_task_body("Kpg statement msg",
          "msg", "[{{ #{STATEMENT_IF_VARIABLE} }}][{{ #{STATEMENT_FOR_VARIABLE} }}]"),
         debug_task_body("Kpg statement if var", "var", STATEMENT_IF_VARIABLE),
         debug_task_body("Kpg statement for var", "var", STATEMENT_FOR_VARIABLE)]
      when .empty_render?
        [debug_task_body("Kpg empty var", "var", EXPRESSION_VALUE_VARIABLE),
         debug_task_body("Kpg empty msg", "msg", "")]
      when .star_args?
        probe_pair(EXPRESSION_VALUE_VARIABLE, "star args") + [
          module_task_body("Kpg star args module arg", "ansible.builtin.copy",
            {"content" => expression_value(shape),
             "dest"    => "#{Fixtures::WORK_ROOT}/expr-star-args.txt"}),
        ]
      else
        probe_pair(EXPRESSION_VALUE_VARIABLE, shape.label)
      end
    end

    # The value each expression shape renders. The syntax is deliberately
    # production-shaped: multi-backreference regex calls, filter chains
    # with several positional arguments, Jinja statement blocks and a
    # `*args` splice (the forms krikri's template layer has diverged on).
    private def expression_value(shape : ExpressionShape) : String
      case shape
      when .regex_search?
        "{{ 'abc-123' | regex_search('([a-z]+)-(\\d+)', '\\2', '\\1') }}"
      when .regex_replace?
        "{{ 'abc-123' | regex_replace('([a-z]+)-(\\d+)', '\\2-\\1') }}"
      when .chain?
        "{{ 'b,a,c' | split(',') | map('upper') | select('ne', 'B') | list | join('|') }}"
      when .positional?
        "{{ 'x' | #{Fixtures::FILTER_PLUGIN_NAME}('a', 'b') }}"
      when .star_args?
        "{{ 'x' | #{Fixtures::FILTER_PLUGIN_NAME}(*['a', 'b']) }}"
      when .empty_render?
        "{{ '' }}"
      else
        "{{ 'kpg' }}"
      end
    end

    # The plugin layout for a playbook-adjacent row: one loader directory
    # per plugin type the row needs, next to the playbook. Every isolated
    # backend copies these into the playbook's working directory.
    private def write_plugin_layout(basename : String, axes : PluginAxes) : Nil
      root = PlaybookBuilder.plugins_dir(File.join(@out_dir, "#{basename}.yml"))
      FileUtils.rm_rf(root) if Dir.exists?(root)
      return unless axes.discovery.relative?

      kinds = axes.kinds
      return if kinds.empty?

      kinds.each do |kind|
        dir = File.join(root, PluginShapes::DIRS[kind])
        Dir.mkdir_p(dir)
        Fixtures.plugin_sources(kind).each do |name, source|
          File.write(File.join(dir, name), source + "\n")
        end
      end
    end

    private def plugin_json(json : JSON::Builder, index : Int32) : Nil
      axes = plugin_axes(index)
      json.field "plugins" do
        json.object do
          json.field "lookup", axes.lookup.label
          json.field "expression", axes.expression.label
          json.field "strategy", axes.strategy ? Fixtures::CUSTOM_STRATEGY : nil
          json.field "discovery", axes.discovery.label
          json.field "env" do
            json.object do
              plugin_env(axes).each { |name, value| json.field name, value }
            end
          end
        end
      end
    end

    # An include/import shape as extra play tasks. `import_playbook` is
    # play-level, so it is added to the document by the caller instead.
    private def include_task_bodies(shape : IncludeShape, basename : String) : Array(YAML::Any)
      case shape
      when .relative?
        [include_tasks_body("#{basename}-inc/a.yml")]
      when .role_vars?
        [include_role_body(Fixtures::ROLE_PATH,
          vars: {Fixtures::ROLE_DEFAULT_VAR => "two", Fixtures::ROLE_VARS_VAR => "three"})]
      when .role_inner?
        [include_role_body(Fixtures::ROLE_PATH, tasks_from: "inner")]
      when .loop_tasks?
        [include_tasks_body("{{ item }}", loop: [Fixtures::TASKS_FILE, Fixtures::TASKS_FILE_2])]
      when .loop_role?
        [include_role_body("{{ item }}", loop: [Fixtures::ROLE_PATH])]
      when .import_role?
        [import_role_body]
      else
        [] of YAML::Any
      end
    end

    private def include_tasks_body(file : String, loop : Array(String)? = nil) : YAML::Any
      body = {} of YAML::Any => YAML::Any
      body[YAML::Any.new("name")] = YAML::Any.new("Kpg include tasks")
      body[YAML::Any.new("ansible.builtin.include_tasks")] = YAML::Any.new(file)
      body[YAML::Any.new("loop")] = YAML::Any.new(loop.map { |item| YAML::Any.new(item) }) if loop
      YAML::Any.new(body)
    end

    private def include_role_body(name : String, tasks_from : String? = nil,
                                  vars : Hash(String, String)? = nil,
                                  loop : Array(String)? = nil) : YAML::Any
      body = {} of YAML::Any => YAML::Any
      body[YAML::Any.new("name")] = YAML::Any.new("Kpg include role")
      args = {} of YAML::Any => YAML::Any
      args[YAML::Any.new("name")] = YAML::Any.new(name)
      args[YAML::Any.new("tasks_from")] = YAML::Any.new(tasks_from) if tasks_from
      body[YAML::Any.new("ansible.builtin.include_role")] = YAML::Any.new(args)
      if vars
        body[YAML::Any.new("vars")] = YAML::Any.new(
          vars.to_h { |key, value| {YAML::Any.new(key), YAML::Any.new(value)} })
      end
      body[YAML::Any.new("loop")] = YAML::Any.new(loop.map { |item| YAML::Any.new(item) }) if loop
      YAML::Any.new(body)
    end

    private def import_role_body : YAML::Any
      body = {} of YAML::Any => YAML::Any
      body[YAML::Any.new("name")] = YAML::Any.new("Kpg import role")
      args = {} of YAML::Any => YAML::Any
      args[YAML::Any.new("name")] = YAML::Any.new(Fixtures::ROLE_PATH)
      args[YAML::Any.new("tasks_from")] = YAML::Any.new("inner")
      body[YAML::Any.new("import_role")] = YAML::Any.new(args)
      YAML::Any.new(body)
    end

    # The v2 play's non-task wiring: the shaped notifier/retry/include
    # tasks and the handler section.
    private def apply_scenario_conditions(play : Hash(YAML::Any, YAML::Any),
                                          task_bodies : Array(YAML::Any),
                                          tasks : Array(GeneratedTask), index : Int32,
                                          basename : String) : Nil
      shape = @handler_shapes[index]? || HandlerShape::Off
      task_bodies << notifier_body unless shape.off?
      task_bodies.concat(retry_bodies(@retry_shapes[index]? || RetryShape::Off))
      task_bodies.concat(include_task_bodies(@include_shapes[index]? || IncludeShape::Off, basename))
      task_bodies.concat(plugin_task_bodies(plugin_axes(index)))
      play[YAML::Any.new("tasks")] = YAML::Any.new(task_bodies)
      apply_scenario_handlers(play, tasks, shape)
    end

    # The delegate play var when any scenario task uses the templated
    # delegate_to spelling, plus the plugin axis' probe variables.
    private def apply_delegate_vars(play : Hash(YAML::Any, YAML::Any),
                                    tasks : Array(GeneratedTask), axes : PluginAxes) : Nil
      vars = {} of YAML::Any => YAML::Any
      if tasks.any? { |task| task.delegate_to.try(&.includes?("{{")) }
        vars[YAML::Any.new(Generator::DELEGATE_VARIABLE)] = YAML::Any.new(Generator::DELEGATE_HOST)
      end
      plugin_play_vars(axes, vars)
      return if vars.empty?

      play[YAML::Any.new("vars")] = YAML::Any.new(vars)
    end

    # The play-level `import_playbook` directive needs a second top-level
    # item, which a task list cannot express.
    private def import_playbook_items(shape : IncludeShape) : Array(YAML::Any)
      return [] of YAML::Any unless shape.import_playbook?

      [YAML::Any.new({YAML::Any.new("ansible.builtin.import_playbook") => YAML::Any.new(Fixtures::CHILD_PLAYBOOK)})]
    end

    # The playbook-relative include needs its child files next to the
    # generated playbook; every backend copies the sibling directory along
    # with the playbook.
    private def write_include_layout(basename : String, shape : IncludeShape) : Nil
      return unless shape.relative?

      dir = PlaybookBuilder.include_dir(File.join(@out_dir, "#{basename}.yml"))
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "a.yml"), <<-YAML)
        ---
        - name: Kpg relative include a
          ansible.builtin.debug:
            msg: kpg-relative-a
        - name: Kpg relative include b
          ansible.builtin.include_tasks: b.yml
        YAML
      File.write(File.join(dir, "b.yml"), <<-YAML)
        ---
        - name: Kpg relative include b task
          ansible.builtin.debug:
            msg: kpg-relative-b
        YAML
    end

    # The retry shapes' play tasks. The command fixtures are deterministic:
    # one succeeds on its third run (counter in the writable work root),
    # one never succeeds. `until:` reads the registered result of the
    # current attempt, which is how ansible exposes it.
    private def retry_bodies(shape : RetryShape) : Array(YAML::Any)
      case shape
      when .retried?        then [retried_command_body(Fixtures::RETRY_SCRIPT, 4, false)]
      when .exhausted?      then [retried_command_body(Fixtures::RETRY_NEVER_SCRIPT, 2, false)]
      when .delegated?      then [retried_command_body(Fixtures::RETRY_SCRIPT, 4, true), retry_result_probe_body]
      when .delegated_fact? then [delegated_fact_body, delegated_fact_probe_body]
      else                       [] of YAML::Any
      end
    end

    private def retried_command_body(script : String, retries : Int32, delegated : Bool) : YAML::Any
      body = {} of YAML::Any => YAML::Any
      body[YAML::Any.new("name")] = YAML::Any.new("Kpg retried command")
      args = {} of YAML::Any => YAML::Any
      args[YAML::Any.new("cmd")] = YAML::Any.new(script)
      body[YAML::Any.new("ansible.builtin.command")] = YAML::Any.new(args)
      body[YAML::Any.new("register")] = YAML::Any.new("kpg_retry")
      body[YAML::Any.new("retries")] = YAML::Any.new(retries)
      body[YAML::Any.new("delay")] = YAML::Any.new(0)
      body[YAML::Any.new("until")] = YAML::Any.new("kpg_retry.rc == 0")
      body[YAML::Any.new("changed_when")] = YAML::Any.new(false)
      body[YAML::Any.new("ignore_errors")] = YAML::Any.new(true)
      if delegated
        body[YAML::Any.new("delegate_to")] = YAML::Any.new(Generator::DELEGATE_HOST)
        body[YAML::Any.new("delegate_facts")] = YAML::Any.new(true)
      end
      YAML::Any.new(body)
    end

    private def retry_result_probe_body : YAML::Any
      body = debug_body("Kpg retry probe", "{{ kpg_retry.attempts | default('none') }}")
      YAML::Any.new(body.as_h)
    end

    private def delegated_fact_body : YAML::Any
      body = {} of YAML::Any => YAML::Any
      body[YAML::Any.new("name")] = YAML::Any.new("Kpg retry fact")
      args = {} of YAML::Any => YAML::Any
      args[YAML::Any.new("kpg_retry_fact")] = YAML::Any.new("kpg-fact-{{ ansible_host }}")
      body[YAML::Any.new("ansible.builtin.set_fact")] = YAML::Any.new(args)
      body[YAML::Any.new("delegate_to")] = YAML::Any.new(Generator::DELEGATE_HOST)
      body[YAML::Any.new("delegate_facts")] = YAML::Any.new(true)
      body[YAML::Any.new("retries")] = YAML::Any.new(2)
      body[YAML::Any.new("delay")] = YAML::Any.new(0)
      body[YAML::Any.new("until")] = YAML::Any.new("kpg_retry is defined")
      body[YAML::Any.new("register")] = YAML::Any.new("kpg_retry")
      body[YAML::Any.new("ignore_errors")] = YAML::Any.new(true)
      YAML::Any.new(body)
    end

    private def delegated_fact_probe_body : YAML::Any
      body = debug_body("Kpg fact probe",
        "{{ hostvars['#{Generator::DELEGATE_HOST}']['kpg_retry_fact'] | default('absent') }}")
      YAML::Any.new(body.as_h)
    end

    # Always-changed, always-ignored task whose only job is to notify the
    # shaped handler: a module that happens to report no change would leave
    # the handler unexercised.
    private def notifier_body : YAML::Any
      body = {} of YAML::Any => YAML::Any
      body[YAML::Any.new("name")] = YAML::Any.new("Kpg notifier")
      args = {} of YAML::Any => YAML::Any
      args[YAML::Any.new("cmd")] = YAML::Any.new("/bin/true")
      body[YAML::Any.new("ansible.builtin.command")] = YAML::Any.new(args)
      body[YAML::Any.new("changed_when")] = YAML::Any.new(true)
      body[YAML::Any.new("ignore_errors")] = YAML::Any.new(true)
      body[YAML::Any.new("notify")] = YAML::Any.new(HANDLER_NAME)
      YAML::Any.new(body)
    end

    # The handler section of a multi-task playbook: the shaped handlers when
    # the axis is on, otherwise the single debug handler a task's `notify:`
    # needs (the pre-axis behavior).
    private def apply_scenario_handlers(play : Hash(YAML::Any, YAML::Any),
                                        tasks : Array(GeneratedTask), shape : HandlerShape) : Nil
      unless shape.off?
        apply_handlers(play, shape)
        return
      end
      return unless tasks.any? { |task| task.notify && task.notify_allowed? }

      handler = {} of YAML::Any => YAML::Any
      handler[YAML::Any.new("name")] = YAML::Any.new(HANDLER_NAME)
      handler_args = {} of YAML::Any => YAML::Any
      handler_args[YAML::Any.new("msg")] = YAML::Any.new(HANDLER_MESSAGE)
      handler[YAML::Any.new("ansible.builtin.debug")] = YAML::Any.new(handler_args)
      play[YAML::Any.new("handlers")] = YAML::Any.new([YAML::Any.new(handler)])
    end

    private def apply_handlers(play : Hash(YAML::Any, YAML::Any), shape : HandlerShape) : Nil
      handlers = handler_bodies(shape)
      return if handlers.empty?

      play[YAML::Any.new("handlers")] = YAML::Any.new(handlers)
    end

    private def handler_bodies(shape : HandlerShape) : Array(YAML::Any)
      case shape
      when .failing?   then [failing_handler_body(false)]
      when .ignoring?  then [failing_handler_body(true)]
      when .delegated? then [delegated_handler_body]
      when .chained?   then [chained_first_handler_body, second_handler_body]
      else                  [] of YAML::Any
      end
    end

    private def failing_handler_body(ignore_errors : Bool) : YAML::Any
      body = {} of YAML::Any => YAML::Any
      body[YAML::Any.new("name")] = YAML::Any.new(HANDLER_NAME)
      args = {} of YAML::Any => YAML::Any
      args[YAML::Any.new("cmd")] = YAML::Any.new(FAILURE_COMMAND)
      body[YAML::Any.new("ansible.builtin.command")] = YAML::Any.new(args)
      body[YAML::Any.new("changed_when")] = YAML::Any.new(false)
      body[YAML::Any.new("ignore_errors")] = YAML::Any.new(true) if ignore_errors
      YAML::Any.new(body)
    end

    private def delegated_handler_body : YAML::Any
      body = debug_body(HANDLER_NAME, "kpg-delegated-handler")
      raws = body.as_h
      raws[YAML::Any.new("delegate_to")] = YAML::Any.new(Generator::DELEGATE_HOST)
      YAML::Any.new(raws)
    end

    private def chained_first_handler_body : YAML::Any
      body = debug_body(HANDLER_NAME, "kpg-handler-a")
      raws = body.as_h
      raws[YAML::Any.new("notify")] = YAML::Any.new(SECOND_HANDLER_NAME)
      YAML::Any.new(raws)
    end

    private def second_handler_body : YAML::Any
      debug_body(SECOND_HANDLER_NAME, "kpg-handler-b")
    end

    private def delegate_fields(body : Hash(YAML::Any, YAML::Any), task : GeneratedTask) : Nil
      target = task.delegate_to
      return unless target

      body[YAML::Any.new("delegate_to")] = YAML::Any.new(target)
      body[YAML::Any.new("delegate_facts")] = YAML::Any.new(true) if task.delegate_facts?
    end

    # A delegated task's connection context is invisible in its own result
    # line, so two probes read what ansible resolved for the delegate:
    # `ansible_host` and `ansible_delegated_vars`. They repeat the task's
    # `delegate_to` because ansible_delegated_vars only exists inside a
    # delegated task.
    private def delegate_probe_bodies(task : GeneratedTask) : Array(YAML::Any)
      target = task.delegate_to
      return [] of YAML::Any unless target

      [{"Delegate host probe", "ansible_host"}, {"Delegate vars probe", "ansible_delegated_vars"}].map do |(name, variable)|
        body = {} of YAML::Any => YAML::Any
        body[YAML::Any.new("name")] = YAML::Any.new(name)
        args = {} of YAML::Any => YAML::Any
        args[YAML::Any.new("var")] = YAML::Any.new(variable)
        body[YAML::Any.new("ansible.builtin.debug")] = YAML::Any.new(args)
        body[YAML::Any.new("delegate_to")] = YAML::Any.new(target)
        body[YAML::Any.new("delegate_facts")] = YAML::Any.new(true) if task.delegate_facts?
        body[YAML::Any.new("ignore_errors")] = YAML::Any.new(true)
        YAML::Any.new(body)
      end
    end

    private def wiring_descriptions(task : GeneratedTask) : Array(String)
      wiring = [] of String
      wiring << "when:#{task.when_condition}" if task.when_condition
      wiring << "loop:#{task.loop_option}" if task.loop_option && task.loop_items
      wiring << "notify:#{task.notify}" if task.notify
      wiring << "delegate_to:#{task.delegate_to}" if task.delegate_to
      wiring
    end
  end
end
