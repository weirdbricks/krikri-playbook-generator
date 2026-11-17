require "./spec_helper"
require "../src/krikri_playbook_generator/playbook_builder"
require "json"
require "file_utils"

module KrikriPlaybookGenerator
  describe PlaybookBuilder do
    def sample_task(chaos : Bool = false) : GeneratedTask
      args = {"name" => YAML::Any.new([YAML::Any.new("nginx")]), "state" => YAML::Any.new("present")}
      mutations = chaos ? [{"state", ChaosKind::BadChoice}] : [] of {String, ChaosKind}
      GeneratedTask.new("apt", "ansible.builtin", args, mutations)
    end

    it "writes one playbook and one meta.json per task" do
      dir = File.tempname("kpg-spec")
      paths = PlaybookBuilder.new(dir).build([sample_task, sample_task(chaos: true)])

      assert_equal(2, paths.size)
      paths.each do |path|
        assert File.exists?(path)
        assert File.exists?(path.sub(/\.yml$/, ".meta.json"))
      end
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "writes the seed as a first-line comment when one is given" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, 1234).build([sample_task]).first

      assert(File.read(path).starts_with?("# krikri-playbook-generator seed=1234\n"))
      doc = YAML.parse(File.read(path)).as_a
      assert_equal(1, doc.size)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "omits the seed comment when no seed is given" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir).build([sample_task]).first

      refute(File.read(path).starts_with?("#"))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "emits a playbook YAML real ansible/krikri can parse: one play, one task, fully-qualified module name" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir).build([sample_task]).first
      doc = YAML.parse(File.read(path)).as_a

      assert_equal(1, doc.size)
      play = doc.first
      assert_equal(HostInventory::GROUP, play["hosts"].as_s)
      assert_equal(false, play["gather_facts"].as_bool)

      tasks = play["tasks"].as_a
      assert_equal(1, tasks.size)
      task = tasks.first
      assert task.as_h.has_key?(YAML::Any.new("ansible.builtin.apt"))
      assert_equal(["nginx"], task["ansible.builtin.apt"]["name"].as_a.map(&.as_s))
      assert_equal(true, task["ignore_errors"].as_bool)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "starts every play and task name with an uppercase letter (ansible-lint name[casing])" do
      dir = File.tempname("kpg-spec")
      text = File.read(PlaybookBuilder.new(dir).build_scenarios([[sample_task]]).first)
      play = YAML.parse(text).as_a.first

      assert_equal("Krikri-playbook-generator: multi-task #0", play["name"].as_s)
      play["tasks"].as_a.each do |task|
        name = task["name"].as_s
        assert(name[0].uppercase?, "task name #{name.inspect} should start uppercase")
      end
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "indents a sequence under its key (ansible-lint yaml[indentation])" do
      dir = File.tempname("kpg-spec")
      tasks = [
        GeneratedTask.new("stat", "ansible.builtin", {"path" => YAML::Any.new(Fixtures::SOURCE_FILES.first)}),
        GeneratedTask.new("debug", "ansible.builtin", {"msg" => YAML::Any.new("hi")},
          notify: KrikriPlaybookGenerator::HANDLER_NAME),
      ]
      text = File.read(PlaybookBuilder.new(dir).build_scenarios([tasks]).first)

      assert(text.matches?(/\n  tasks:\n    - name: /), text)
      assert(text.matches?(/\n  handlers:\n    - name: /), text)
      assert(text.matches?(/\n      ansible\.builtin\.stat:\n        path: /), text)
      assert(text.matches?(/\n        msg: hi\n/), text)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "records mutation metadata in the meta.json sidecar for a chaos task" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir).build([sample_task(chaos: true)]).first
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))

      assert_equal("apt", meta["module"].as_s)
      assert_equal(true, meta["chaos"].as_bool)
      assert_equal(1, meta["mutations"].as_a.size)
      assert_equal("BadChoice", meta["mutations"][0]["kind"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "marks a happy-path task's meta.json as non-chaos with no mutations" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir).build([sample_task]).first
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))

      assert_equal(false, meta["chaos"].as_bool)
      assert_empty(meta["mutations"].as_a)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "records where each happy-path argument's value came from" do
      dir = File.tempname("kpg-spec")
      task = GeneratedTask.new("apt", "ansible.builtin",
        {"name" => YAML::Any.new([YAML::Any.new("nginx")]), "state" => YAML::Any.new("present")},
        choice_sources: {"state" => ChoiceSource::Constructive, "name" => ChoiceSource::Random})
      path = PlaybookBuilder.new(dir).build([task]).first
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))

      assert_equal("constructive", meta["choice_sources"]["state"].as_s)
      assert_equal("random", meta["choice_sources"]["name"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "writes a play-level keyword into the play and records it in the sidecar" do
      dir = File.tempname("kpg-spec")
      settings = [PlaySetting.new("strategy", "free")] of PlaySetting?
      path = PlaybookBuilder.new(dir, nil, settings).build([sample_task]).first

      play = YAML.parse(File.read(path)).as_a.first
      assert_equal("free", play["strategy"].as_s)
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal("strategy", meta["play"]["keyword"].as_s)
      assert_equal("free", meta["play"]["value"].as_s)
      assert_equal("play", meta["play"]["source"].as_s)
      assert_equal({} of String => JSON::Any, meta["play"]["env"].as_h)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "types a play key the way ansible expects it" do
      dir = File.tempname("kpg-spec")
      settings = [PlaySetting.new("gather_facts", "true"), PlaySetting.new("serial", "2")] of PlaySetting?
      first, second = PlaybookBuilder.new(dir, nil, settings).build([sample_task, sample_task])

      facts_play = YAML.parse(File.read(first)).as_a.first
      assert_equal(true, facts_play["gather_facts"].as_bool)
      serial_play = YAML.parse(File.read(second)).as_a.first
      assert_equal(2, serial_play["serial"].as_i)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "keeps an env-var keyword out of the play and in the sidecar" do
      dir = File.tempname("kpg-spec")
      settings = [PlaySetting.new("strategy", "free", "ANSIBLE_STRATEGY")] of PlaySetting?
      path = PlaybookBuilder.new(dir, nil, settings).build([sample_task]).first

      play = YAML.parse(File.read(path)).as_a.first
      assert_nil(play["strategy"]?)
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal("env", meta["play"]["source"].as_s)
      assert_equal("free", meta["play"]["env"]["ANSIBLE_STRATEGY"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "omits the play object and writes no keyword when the axis is off" do
      dir = File.tempname("kpg-spec")
      settings = [nil] of PlaySetting?
      path = PlaybookBuilder.new(dir, nil, settings).build([sample_task]).first

      play = YAML.parse(File.read(path)).as_a.first
      refute(play.as_h.keys.any? { |key| key.as_s == "strategy" })
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert(meta["play"].raw.nil?)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "records an env-var keyword on a v2 multi-task playbook's sidecar" do
      dir = File.tempname("kpg-spec")
      settings = [PlaySetting.new("forks", "1", "ANSIBLE_FORKS")] of PlaySetting?
      tasks = [GeneratedTask.new("debug", "ansible.builtin", {"msg" => YAML::Any.new("hi")}),
               GeneratedTask.new("stat", "ansible.builtin", {"path" => YAML::Any.new("/tmp/kpg-work/out1.txt")})]
      path = PlaybookBuilder.new(dir, nil, settings).build_scenarios([tasks]).first

      play = YAML.parse(File.read(path)).as_a.first
      assert_nil(play["forks"]?)
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal("1", meta["play"]["env"]["ANSIBLE_FORKS"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "writes delegate_to, delegate_facts and the two probes for a delegated task" do
      dir = File.tempname("kpg-spec")
      task = GeneratedTask.new("debug", "ansible.builtin",
        {"msg" => YAML::Any.new("hi")}, delegate_to: "target2", delegate_facts: true)
      path = PlaybookBuilder.new(dir).build([task]).first

      play = YAML.parse(File.read(path)).as_a.first
      tasks = play["tasks"].as_a
      assert_equal(3, tasks.size)
      assert_equal("target2", tasks[0]["delegate_to"].as_s)
      assert_equal(true, tasks[0]["delegate_facts"].as_bool)
      assert_equal("ansible_host", tasks[1]["ansible.builtin.debug"]["var"].as_s)
      assert_equal("ansible_delegated_vars", tasks[2]["ansible.builtin.debug"]["var"].as_s)
      tasks[1..].each do |probe|
        assert_equal("target2", probe["delegate_to"].as_s)
        assert_equal(true, probe["ignore_errors"].as_bool)
      end
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal("target2", meta["delegate_to"].as_s)
      assert_equal(true, meta["delegate_facts"].as_bool)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "defines the delegate play var for the templated spelling" do
      dir = File.tempname("kpg-spec")
      task = GeneratedTask.new("debug", "ansible.builtin",
        {"msg" => YAML::Any.new("hi")}, delegate_to: "{{ kpg_delegate }}")
      path = PlaybookBuilder.new(dir).build([task]).first

      play = YAML.parse(File.read(path)).as_a.first
      assert_equal("target2", play["vars"]["kpg_delegate"].as_s)
      assert_equal("{{ kpg_delegate }}", play["tasks"].as_a.first["delegate_to"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "keeps v2 delegation on the task itself (no extra probe tasks to shift the chain)" do
      dir = File.tempname("kpg-spec")
      tasks = [GeneratedTask.new("debug", "ansible.builtin", {"msg" => YAML::Any.new("hi")},
        delegate_to: "target2", delegate_facts: true),
               GeneratedTask.new("stat", "ansible.builtin", {"path" => YAML::Any.new("/tmp/kpg-work/out1.txt")},
                 when_condition: "kpg_task_0 is succeeded")]
      path = PlaybookBuilder.new(dir).build_scenarios([tasks]).first

      play = YAML.parse(File.read(path)).as_a.first
      bodies = play["tasks"].as_a
      assert_equal(2, bodies.size)
      assert_equal("target2", bodies[0]["delegate_to"].as_s)
      assert_equal(true, bodies[0]["delegate_facts"].as_bool)
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert(meta["modules"][0]["wiring"].as_a.map(&.as_s).includes?("delegate_to:target2"))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "wraps a task in a block with a forced failure, rescue and always" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [BlockShape::Rescue])
        .build([sample_task]).first

      block = YAML.parse(File.read(path)).as_a.first["tasks"].as_a.first
      assert_equal("Kpg block", block["name"].as_s)
      block["block"].as_a.each do |task|
        next unless task["ansible.builtin.command"]?
        assert_equal("/bin/false", task["ansible.builtin.command"]["cmd"].as_s)
        assert_equal(false, task["changed_when"].as_bool)
      end
      assert(block["block"].as_a.any? { |task| task["ansible.builtin.command"]? }, "no forced failure")
      assert_equal("kpg-rescue", block["rescue"].as_a.first["ansible.builtin.debug"]["msg"].as_s)
      assert_equal("kpg-always", block["always"].as_a.first["ansible.builtin.debug"]["msg"].as_s)
      assert_nil(block["when"]?)
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal("rescue", meta["block"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "keeps the always shape on the success path (no forced failure)" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [BlockShape::Always])
        .build([sample_task]).first

      block = YAML.parse(File.read(path)).as_a.first["tasks"].as_a.first
      refute(block["block"].as_a.any? { |task| task["ansible.builtin.command"]? })
      assert_equal("kpg-always", block["always"].as_a.first["ansible.builtin.debug"]["msg"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "gates a skipped block on a play variable and an undefined one on nothing" do
      dir = File.tempname("kpg-spec")
      skipped = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [BlockShape::Skipped])
        .build([sample_task]).first
      skipped_play = YAML.parse(File.read(skipped)).as_a.first
      assert_equal("kpg_block_gate | bool", skipped_play["tasks"].as_a.first["when"].as_s)
      assert_equal(false, skipped_play["vars"]["kpg_block_gate"].as_bool)

      undefined = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [BlockShape::Undefined])
        .build([sample_task]).first
      undefined_play = YAML.parse(File.read(undefined)).as_a.first
      assert_equal("kpg_block_gate", undefined_play["tasks"].as_a.first["when"].as_s)
      assert_nil(undefined_play["vars"]?)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "keeps the flat task list when the block axis is off" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [BlockShape::None])
        .build([sample_task]).first

      body = YAML.parse(File.read(path)).as_a.first["tasks"].as_a.first
      assert(body["ansible.builtin.apt"]?)
      assert_nil(body["block"]?)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "adds an always-changing notifier and a failing handler for the failing shape" do
      dir = File.tempname("kpg-spec")
      settings = [] of PlaySetting?
      path = PlaybookBuilder.new(dir, nil, settings, [] of BlockShape, [HandlerShape::Failing])
        .build([sample_task]).first

      play = YAML.parse(File.read(path)).as_a.first
      notifier = play["tasks"].as_a.last
      assert_equal("Kpg notifier", notifier["name"].as_s)
      assert_equal(true, notifier["changed_when"].as_bool)
      assert_equal(KrikriPlaybookGenerator::HANDLER_NAME, notifier["notify"].as_s)

      handler = play["handlers"].as_a.first
      assert_equal("/bin/false", handler["ansible.builtin.command"]["cmd"].as_s)
      assert_nil(handler["ignore_errors"]?)
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal("failing", meta["handlers"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "ignores the same failure in the ignoring shape" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape, [HandlerShape::Ignoring])
        .build([sample_task]).first

      handler = YAML.parse(File.read(path)).as_a.first["handlers"].as_a.first
      assert_equal("/bin/false", handler["ansible.builtin.command"]["cmd"].as_s)
      assert_equal(true, handler["ignore_errors"].as_bool)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "delegates the handler in the delegated shape" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape, [HandlerShape::Delegated])
        .build([sample_task]).first

      handler = YAML.parse(File.read(path)).as_a.first["handlers"].as_a.first
      assert_equal("target2", handler["delegate_to"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "chains the first handler to a second one in the chained shape" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape, [HandlerShape::Chained])
        .build([sample_task]).first

      handlers = YAML.parse(File.read(path)).as_a.first["handlers"].as_a
      assert_equal(2, handlers.size)
      assert_equal(KrikriPlaybookGenerator::HANDLER_NAME, handlers[0]["name"].as_s)
      assert_equal(KrikriPlaybookGenerator::SECOND_HANDLER_NAME, handlers[0]["notify"].as_s)
      assert_equal(KrikriPlaybookGenerator::SECOND_HANDLER_NAME, handlers[1]["name"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "leaves handlers and the notifier out when the handler axis is off" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape, [HandlerShape::Off])
        .build([sample_task]).first

      play = YAML.parse(File.read(path)).as_a.first
      assert_equal(1, play["tasks"].as_a.size)
      assert_nil(play["handlers"]?)
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal("off", meta["handlers"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "applies a handler shape to a v2 multi-task playbook too" do
      dir = File.tempname("kpg-spec")
      tasks = [GeneratedTask.new("debug", "ansible.builtin", {"msg" => YAML::Any.new("hi")}),
               GeneratedTask.new("stat", "ansible.builtin", {"path" => YAML::Any.new("/tmp/kpg-work/out1.txt")})]
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape, [HandlerShape::Chained])
        .build_scenarios([tasks]).first

      play = YAML.parse(File.read(path)).as_a.first
      assert_equal(3, play["tasks"].as_a.size)
      assert_equal("Kpg notifier", play["tasks"].as_a.last["name"].as_s)
      assert_equal(2, play["handlers"].as_a.size)
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal("chained", meta["handlers"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "adds a retried command with register and until for the retried shape" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape,
        [] of HandlerShape, [RetryShape::Retried]).build([sample_task]).first

      body = YAML.parse(File.read(path)).as_a.first["tasks"].as_a.last
      assert_equal("Kpg retried command", body["name"].as_s)
      assert_equal(Fixtures::RETRY_SCRIPT, body["ansible.builtin.command"]["cmd"].as_s)
      assert_equal("kpg_retry", body["register"].as_s)
      assert_equal(4, body["retries"].as_i)
      assert_equal(0, body["delay"].as_i)
      assert_equal("kpg_retry.rc == 0", body["until"].as_s)
      assert_nil(body["delegate_to"]?)
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal("retried", meta["retries"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "uses the never-succeeding fixture for the exhausted shape" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape,
        [] of HandlerShape, [RetryShape::Exhausted]).build([sample_task]).first

      body = YAML.parse(File.read(path)).as_a.first["tasks"].as_a.last
      assert_equal(Fixtures::RETRY_NEVER_SCRIPT, body["ansible.builtin.command"]["cmd"].as_s)
      assert_equal(2, body["retries"].as_i)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "delegates the retried command and probes its attempts for the delegated shapes" do
      dir = File.tempname("kpg-spec")
      delegated = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape,
        [] of HandlerShape, [RetryShape::Delegated]).build([sample_task]).first
      bodies = YAML.parse(File.read(delegated)).as_a.first["tasks"].as_a
      assert_equal("target2", bodies[-2]["delegate_to"].as_s)
      assert_equal(true, bodies[-2]["delegate_facts"].as_bool)
      assert_equal("Kpg retry probe", bodies[-1]["name"].as_s)

      fact = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape,
        [] of HandlerShape, [RetryShape::DelegatedFact]).build([sample_task]).first
      fact_bodies = YAML.parse(File.read(fact)).as_a.first["tasks"].as_a
      retried = fact_bodies[-2]
      assert_equal(true, retried["delegate_facts"].as_bool)
      assert_equal("kpg_retry is defined", retried["until"].as_s)
      assert(fact_bodies[-1]["ansible.builtin.debug"]["msg"].as_s.includes?("hostvars['target2']"))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "adds no retry task when the retry axis is off" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape,
        [] of HandlerShape, [RetryShape::Off]).build([sample_task]).first

      assert_equal(1, YAML.parse(File.read(path)).as_a.first["tasks"].as_a.size)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "emits a free-form module as a bare string, not an argument map" do
      dir = File.tempname("kpg-spec")
      task = GeneratedTask.new("meta", "ansible.builtin", {} of String => YAML::Any, [] of {String, ChaosKind}, "noop")
      path = PlaybookBuilder.new(dir).build([task]).first
      doc = YAML.parse(File.read(path)).as_a

      task_hash = doc.first["tasks"].as_a.first.as_h
      assert_equal("noop", task_hash[YAML::Any.new("ansible.builtin.meta")].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    describe "multi-task scenarios (v2)" do
      def scenario : Array(GeneratedTask)
        first = GeneratedTask.new("stat", "ansible.builtin", {"path" => YAML::Any.new(Fixtures::SOURCE_FILES.first)},
          choice_sources: {"path" => ChoiceSource::Random})
        second = GeneratedTask.new("copy", "ansible.builtin",
          {"src" => YAML::Any.new("{{ item }}"), "dest" => YAML::Any.new(Fixtures::DEST_PATHS.first)},
          [{"mode", ChaosKind::BadChoice}], loop_option: "src", loop_items: Fixtures::SOURCE_FILES,
          notify: KrikriPlaybookGenerator::HANDLER_NAME)
        third = GeneratedTask.new("debug", "ansible.builtin", {"msg" => YAML::Any.new("hi")},
          when_condition: "kpg_task_1 is succeeded")
        [first, second, third]
      end

      it "writes one playbook with every task wired into the scenario" do
        dir = File.tempname("kpg-spec")
        path = PlaybookBuilder.new(dir).build_scenarios([scenario]).first

        assert(File.basename(path).starts_with?("000000-multi-stat-"))
        doc = YAML.parse(File.read(path)).as_a
        assert_equal(1, doc.size)
        play = doc.first
        assert_equal(HostInventory::GROUP, play["hosts"].as_s)
        assert_equal(false, play["gather_facts"].as_bool)

        tasks = play["tasks"].as_a
        assert_equal(3, tasks.size)
        tasks.each_with_index do |task, index|
          assert_equal("kpg_task_#{index}", task["register"].as_s)
          assert_equal(true, task["ignore_errors"].as_bool)
        end
        assert_equal("kpg_task_1 is succeeded", tasks[2]["when"].as_s)
        assert_equal(Fixtures::SOURCE_FILES, tasks[1]["loop"].as_a.map(&.as_s))
        assert_equal(KrikriPlaybookGenerator::HANDLER_NAME, tasks[1]["notify"].as_s)
        assert_equal("{{ item }}", tasks[1]["ansible.builtin.copy"]["src"].as_s)

        handlers = play["handlers"].as_a
        assert_equal(1, handlers.size)
        assert_equal(KrikriPlaybookGenerator::HANDLER_NAME, handlers.first["name"].as_s)
        assert_equal("kpg multi-task handler ran", handlers.first["ansible.builtin.debug"]["msg"].as_s)
      ensure
        FileUtils.rm_rf(dir) if dir
      end

      it "omits the handlers section when no task notifies" do
        dir = File.tempname("kpg-spec")
        plain = [GeneratedTask.new("debug", "ansible.builtin", {"msg" => YAML::Any.new("hi")}),
                 GeneratedTask.new("stat", "ansible.builtin", {"path" => YAML::Any.new("/tmp/kpg-work/out1.txt")})]
        doc = YAML.parse(File.read(PlaybookBuilder.new(dir).build_scenarios([plain]).first)).as_a

        assert_nil(doc.first["handlers"]?)
      ensure
        FileUtils.rm_rf(dir) if dir
      end

      it "omits register from a static import and keeps later registers addressable" do
        dir = File.tempname("kpg-spec")
        imported = GeneratedTask.new("import_tasks", "ansible.builtin",
          {"file" => YAML::Any.new(Fixtures::TASKS_FILE)})
        second = GeneratedTask.new("debug", "ansible.builtin", {"msg" => YAML::Any.new("hi")})
        third = GeneratedTask.new("stat", "ansible.builtin",
          {"path" => YAML::Any.new("/tmp/kpg-work/out1.txt")}, when_condition: "kpg_task_1 is succeeded")
        doc = YAML.parse(File.read(PlaybookBuilder.new(dir).build_scenarios([[imported, second, third]]).first)).as_a
        tasks = doc.first["tasks"].as_a

        assert_nil(tasks[0]["register"]?)
        assert_equal("kpg_task_1", tasks[1]["register"].as_s)
        assert_equal("kpg_task_2", tasks[2]["register"].as_s)
        assert_equal("kpg_task_1 is succeeded", tasks[2]["when"].as_s)
      ensure
        FileUtils.rm_rf(dir) if dir
      end

      it "drops notify from include_* actions and their unused handler" do
        dir = File.tempname("kpg-spec")
        invalid = GeneratedTask.new("include_role", "ansible.builtin",
          {"name" => YAML::Any.new(Fixtures::ROLE_PATH)},
          notify: KrikriPlaybookGenerator::HANDLER_NAME)
        plain = GeneratedTask.new("debug", "ansible.builtin", {"msg" => YAML::Any.new("hi")})
        doc = YAML.parse(File.read(PlaybookBuilder.new(dir).build_scenarios([[invalid, plain]]).first)).as_a
        tasks = doc.first["tasks"].as_a

        assert_nil(tasks[0]["notify"]?)
        assert_nil(doc.first["handlers"]?)
      ensure
        FileUtils.rm_rf(dir) if dir
      end

      it "records the primary module, per-task metadata and wiring in the sidecar" do
        dir = File.tempname("kpg-spec")
        path = PlaybookBuilder.new(dir).build_scenarios([scenario]).first
        meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))

        assert_equal("stat", meta["module"].as_s)
        assert_equal(true, meta["chaos"].as_bool)
        aggregated = meta["mutations"].as_a
        assert_equal(1, aggregated.size)
        assert_equal("t1:mode", aggregated[0]["option"].as_s)
        assert_equal("BadChoice", aggregated[0]["kind"].as_s)

        modules = meta["modules"].as_a
        assert_equal(3, modules.size)
        assert_equal("stat", modules[0]["module"].as_s)
        assert_equal("copy", modules[1]["module"].as_s)
        assert_equal(true, modules[1]["chaos"].as_bool)
        assert_equal("mode", modules[1]["mutations"][0]["option"].as_s)
        assert_equal("random", modules[0]["choice_sources"]["path"].as_s)
        assert_empty(modules[0]["wiring"].as_a)
        assert_equal("loop:src", modules[1]["wiring"][0].as_s)
        assert_equal("notify:#{KrikriPlaybookGenerator::HANDLER_NAME}", modules[1]["wiring"][1].as_s)
        assert_equal("when:kpg_task_1 is succeeded", modules[2]["wiring"][0].as_s)
      ensure
        FileUtils.rm_rf(dir) if dir
      end
    end

    it "still marks a free-form chaos task as chaos in its meta.json" do
      dir = File.tempname("kpg-spec")
      task = GeneratedTask.new("meta", "ansible.builtin", {} of String => YAML::Any,
        [{"free_form", ChaosKind::BadChoice}], "noop_bogus")
      path = PlaybookBuilder.new(dir).build([task]).first
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))

      assert_equal("meta", meta["module"].as_s)
      assert_equal(true, meta["chaos"].as_bool)
      assert_equal("free_form", meta["mutations"][0]["option"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "clears a previous batch's playbooks when rebuilding into the same directory" do
      dir = File.tempname("kpg-spec")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "keepme.txt"), "user data")

      PlaybookBuilder.new(dir).build([sample_task, sample_task(chaos: true)])
      first_files = Dir.children(dir).sort
      assert_equal(5, first_files.size) # 2 yml + 2 meta.json + keepme.txt

      other = GeneratedTask.new("debug", "ansible.builtin", {"msg" => YAML::Any.new("hi")})
      PlaybookBuilder.new(dir).build([other])

      remaining = Dir.children(dir).sort
      assert_equal(3, remaining.size) # 1 yml + 1 meta.json + keepme.txt
      assert(remaining.includes?("keepme.txt"))
      assert(remaining.includes?("000000-debug-happy.yml"))
      assert(remaining.includes?("000000-debug-happy.meta.json"))
      first_files.each do |old_name|
        next if old_name == "keepme.txt"

        refute(remaining.includes?(old_name), "#{old_name} from the first batch should have been cleared")
      end
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end
