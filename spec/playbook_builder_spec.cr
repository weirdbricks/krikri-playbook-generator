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

    it "writes a task-level environment, in both playbook shapes" do
      dir = File.tempname("kpg-spec")
      env = {"no_proxy" => "127.0.0.1,localhost", "http_proxy" => "http://127.0.0.1:9/"}
      single = GeneratedTask.new("get_url", "ansible.builtin",
        {"url" => YAML::Any.new("http://127.0.0.1:18888/src.txt")}, environment: env)
      single_path = PlaybookBuilder.new(dir).build([single]).first
      task = YAML.parse(File.read(single_path)).as_a.first["tasks"].as_a.first
      assert_equal("127.0.0.1,localhost", task["environment"]["no_proxy"].as_s)
      assert_equal("http://127.0.0.1:9/", task["environment"]["http_proxy"].as_s)

      scenario_path = PlaybookBuilder.new(dir).build_scenarios([[single]]).first
      scenario_task = YAML.parse(File.read(scenario_path)).as_a.first["tasks"].as_a.first
      assert_equal("127.0.0.1,localhost", scenario_task["environment"]["no_proxy"].as_s)
      assert_equal("http://127.0.0.1:9/", scenario_task["environment"]["http_proxy"].as_s)
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
      assert_equal(true, meta["structural_failure"].as_bool)
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
      skipped_meta = JSON.parse(File.read(skipped.sub(/\.yml$/, ".meta.json")))
      assert_equal(false, skipped_meta["structural_failure"].as_bool)

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

    it "forces gather_facts true when the flag is set, even over a play keyword" do
      dir = File.tempname("kpg-spec")
      settings = [PlaySetting.new("gather_facts", "false")] of PlaySetting?
      path = PlaybookBuilder.new(dir, nil, settings, [] of BlockShape, [] of HandlerShape,
        [] of RetryShape, gather_facts: true).build([sample_task]).first

      play = YAML.parse(File.read(path)).as_a.first
      assert_equal(true, play["gather_facts"].as_bool)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "writes a playbook-relative include layout beside the playbook" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape,
        [] of HandlerShape, [] of RetryShape, false, [IncludeShape::Relative])
        .build([sample_task]).first

      basename = File.basename(path, ".yml")
      layout = PlaybookBuilder.include_dir(path)
      assert File.file?(File.join(layout, "a.yml"))
      assert File.file?(File.join(layout, "b.yml"))
      assert(File.read(File.join(layout, "a.yml")).includes?("include_tasks: b.yml"))

      body = YAML.parse(File.read(path)).as_a.first["tasks"].as_a.last
      assert_equal("#{basename}-inc/a.yml", body["ansible.builtin.include_tasks"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "includes a role with task-level vars and its inner task file" do
      dir = File.tempname("kpg-spec")
      vars = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape,
        [] of HandlerShape, [] of RetryShape, false, [IncludeShape::RoleVars])
        .build([sample_task]).first
      body = YAML.parse(File.read(vars)).as_a.first["tasks"].as_a.last
      assert_equal(Fixtures::ROLE_PATH, body["ansible.builtin.include_role"]["name"].as_s)
      assert_equal("two", body["vars"][Fixtures::ROLE_DEFAULT_VAR].as_s)
      assert_equal("three", body["vars"][Fixtures::ROLE_VARS_VAR].as_s)

      inner = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape,
        [] of HandlerShape, [] of RetryShape, false, [IncludeShape::RoleInner])
        .build([sample_task]).first
      inner_body = YAML.parse(File.read(inner)).as_a.first["tasks"].as_a.last
      assert_equal("inner", inner_body["ansible.builtin.include_role"]["tasks_from"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "loops include_tasks over the fixture task files and include_role over the role" do
      dir = File.tempname("kpg-spec")
      tasks = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape,
        [] of HandlerShape, [] of RetryShape, false, [IncludeShape::LoopTasks])
        .build([sample_task]).first
      tasks_body = YAML.parse(File.read(tasks)).as_a.first["tasks"].as_a.last
      assert_equal("{{ item }}", tasks_body["ansible.builtin.include_tasks"].as_s)
      assert_equal([Fixtures::TASKS_FILE, Fixtures::TASKS_FILE_2],
        tasks_body["loop"].as_a.map(&.as_s))

      role = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape,
        [] of HandlerShape, [] of RetryShape, false, [IncludeShape::LoopRole])
        .build([sample_task]).first
      role_body = YAML.parse(File.read(role)).as_a.first["tasks"].as_a.last
      assert_equal("{{ item }}", role_body["ansible.builtin.include_role"]["name"].as_s)
      assert_equal([Fixtures::ROLE_PATH], role_body["loop"].as_a.map(&.as_s))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "adds a top-level import_playbook item for that shape and records it" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape,
        [] of HandlerShape, [] of RetryShape, false, [IncludeShape::ImportPlaybook])
        .build([sample_task]).first

      document = YAML.parse(File.read(path)).as_a
      assert_equal(2, document.size)
      assert_equal(Fixtures::CHILD_PLAYBOOK, document[1]["ansible.builtin.import_playbook"].as_s)
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal("import-playbook", meta["includes"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "uses the short import_role spelling for that shape" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape,
        [] of HandlerShape, [] of RetryShape, false, [IncludeShape::ImportRole])
        .build([sample_task]).first

      body = YAML.parse(File.read(path)).as_a.first["tasks"].as_a.last
      assert_equal(Fixtures::ROLE_PATH, body["import_role"]["name"].as_s)
      assert_equal("inner", body["import_role"]["tasks_from"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "records the host images a playbook covers in its sidecar" do
      dir = File.tempname("kpg-spec")
      defaults = PlaybookBuilder.new(dir).build([sample_task]).first
      assert_equal(["debian"],
        JSON.parse(File.read(defaults.sub(/\.yml$/, ".meta.json")))["profiles"].as_a.map(&.as_s))

      both = PlaybookBuilder.new(dir, nil, [] of PlaySetting?, [] of BlockShape,
        [] of HandlerShape, [] of RetryShape, false, [] of IncludeShape,
        [["debian", "rocky"]]).build([sample_task]).first
      assert_equal(["debian", "rocky"],
        JSON.parse(File.read(both.sub(/\.yml$/, ".meta.json")))["profiles"].as_a.map(&.as_s))
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

    it "writes a lookup shape's probes, play variable and adjacent plugin" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, lookup_shapes: [LookupShape::List]).build([sample_task]).first
      play = YAML.parse(File.read(path)).as_a.first

      value = play["vars"].as_h[YAML::Any.new(PlaybookBuilder::LOOKUP_VALUE_VARIABLE)].as_s
      assert_equal("{{ lookup('kpg_list') }}", value)
      names = play["tasks"].as_a.map(&.["name"].as_s)
      assert(names.includes?("Kpg lookup var"))
      assert(names.includes?("Kpg lookup msg"))

      plugin = File.join(PlaybookBuilder.plugins_dir(path), "lookup_plugins", "kpg_list.py")
      assert File.file?(plugin), "playbook-adjacent lookup plugin missing"
      assert_equal(Fixtures::LOOKUP_LIST_SOURCE, File.read(plugin).chomp)

      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal("list", meta["plugins"]["lookup"].as_s)
      assert_equal("relative", meta["plugins"]["discovery"].as_s)
      assert_equal(0, meta["plugins"]["env"].as_h.size)
      refute(meta["structural_failure"].as_bool)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "exports the lookup plugin directory through the environment when asked" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, lookup_shapes: [LookupShape::Undefined],
        plugin_discovery: [PluginDiscovery::Env] of PluginDiscovery?).build([sample_task]).first

      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal(Fixtures::LOOKUP_PLUGIN_DIR, meta["plugins"]["env"]["ANSIBLE_LOOKUP_PLUGINS"].as_s)
      assert_equal("env", meta["plugins"]["discovery"].as_s)
      refute(Dir.exists?(PlaybookBuilder.plugins_dir(path)))
      assert(meta["structural_failure"].as_bool, "a shape whose reference run fails is a structural failure")
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "installs the custom strategy plugin for a strategy row" do
      dir = File.tempname("kpg-spec")
      settings = [PlaySetting.new("strategy", Fixtures::CUSTOM_STRATEGY, "ANSIBLE_STRATEGY")] of PlaySetting?
      path = PlaybookBuilder.new(dir, nil, settings).build([sample_task]).first

      plugin = File.join(PlaybookBuilder.plugins_dir(path), "strategy_plugins", "kpg_custom.py")
      assert File.file?(plugin), "playbook-adjacent strategy plugin missing"
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal(Fixtures::CUSTOM_STRATEGY, meta["plugins"]["strategy"].as_s)
      assert_equal(Fixtures::CUSTOM_STRATEGY, meta["play"]["env"]["ANSIBLE_STRATEGY"].as_s)
      assert_nil(YAML.parse(File.read(path)).as_a.first["strategy"]?)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "probes each expression shape through both debug var and msg" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, expression_shapes: [ExpressionShape::RegexSearch]).build([sample_task]).first
      play = YAML.parse(File.read(path)).as_a.first

      names = play["tasks"].as_a.map(&.["name"].as_s)
      assert(names.includes?("Kpg regex-search var"))
      assert(names.includes?("Kpg regex-search msg"))
      value = play["vars"].as_h[YAML::Any.new(PlaybookBuilder::EXPRESSION_VALUE_VARIABLE)].as_s
      assert(value.includes?("regex_search"))
      assert(value.includes?("'\\2'"))
      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      refute(meta["structural_failure"].as_bool)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "renders a statement block and a star-args splice, with the filter plugin installed" do
      dir = File.tempname("kpg-spec")
      statement = PlaybookBuilder.new(dir, expression_shapes: [ExpressionShape::Statement]).build([sample_task]).first
      vars = YAML.parse(File.read(statement)).as_a.first["vars"].as_h
      assert(vars[YAML::Any.new(PlaybookBuilder::STATEMENT_IF_VARIABLE)].as_s.includes?("{% if true %}"))
      assert(vars[YAML::Any.new(PlaybookBuilder::STATEMENT_FOR_VARIABLE)].as_s.includes?("{% for item"))

      star = PlaybookBuilder.new(dir, expression_shapes: [ExpressionShape::StarArgs]).build([sample_task]).first
      plugin = File.join(PlaybookBuilder.plugins_dir(star), "filter_plugins", "kpg_filters.py")
      assert File.file?(plugin), "playbook-adjacent filter plugin missing"
      copy_task = YAML.parse(File.read(star)).as_a.first["tasks"].as_a.find do |task|
        task["name"].as_s == "Kpg star args module arg"
      end
      refute_nil(copy_task)
      content = copy_task.as(YAML::Any)["ansible.builtin.copy"]["content"].as_s
      assert(content.includes?("*['a', 'b']"))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "renders an empty render as an empty msg" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir, expression_shapes: [ExpressionShape::EmptyRender]).build([sample_task]).first
      empty_msg = YAML.parse(File.read(path)).as_a.first["tasks"].as_a.find do |task|
        task["name"].as_s == "Kpg empty msg"
      end
      refute_nil(empty_msg)
      assert_equal("", empty_msg.as(YAML::Any)["ansible.builtin.debug"]["msg"].as_s)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "adds the plugin probes to a multi-task playbook too" do
      dir = File.tempname("kpg-spec")
      path = PlaybookBuilder.new(dir,
        lookup_shapes: [LookupShape::Query],
        expression_shapes: [ExpressionShape::Chain]).build_scenarios([[sample_task]]).first
      play = YAML.parse(File.read(path)).as_a.first

      assert(play["vars"].as_h.has_key?(YAML::Any.new(PlaybookBuilder::LOOKUP_VALUE_VARIABLE)))
      names = play["tasks"].as_a.map(&.["name"].as_s)
      assert(names.includes?("Kpg lookup msg"))
      assert(names.includes?("Kpg chain var"))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    def library_task(probe : LibraryProbe) : GeneratedTask
      GeneratedTask.new(probe.module_name, "ansible.legacy", probe.args, library: probe)
    end

    it "writes a generated library module beside the playbook and records it" do
      dir = File.tempname("kpg-spec")
      probe = ModuleUtilsSurface.probes(["ansible.module_utils.basic"]).first
      path = PlaybookBuilder.new(dir).build([library_task(probe)]).first

      source = File.join(dir, "library", "kpg_mu_basic.py")
      assert File.exists?(source)
      assert_includes(File.read(source), "import ansible.module_utils.basic")
      assert_equal(source, File.join(PlaybookBuilder.library_dir(path), "kpg_mu_basic.py"))

      task = YAML.parse(File.read(path)).as_a.first["tasks"].as_a.first
      assert(task.as_h.has_key?(YAML::Any.new("ansible.legacy.kpg_mu_basic")))
      assert_equal(0, task["ansible.legacy.kpg_mu_basic"].as_h.size)

      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal("module-utils", meta["library"]["shape"].as_s)
      assert_equal("ansible.module_utils.basic", meta["library"]["target"].as_s)
      assert_equal("kpg_mu_basic", meta["library"]["module"].as_s)
      assert_equal(false, meta["library"]["deliberate_failure"].as_bool)
      assert_equal(false, meta["structural_failure"].as_bool)
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "clears stale generated library modules but leaves a hand-written one alone" do
      dir = File.tempname("kpg-spec")
      library = File.join(dir, "library")
      Dir.mkdir_p(library)
      File.write(File.join(library, "kpg_mu_stale.py"), "# stale probe")
      File.write(File.join(library, "handwritten.py"), "# not ours")

      probe = ModuleUtilsSurface.probes(["ansible.module_utils.basic"]).first
      PlaybookBuilder.new(dir).build([library_task(probe)])

      refute File.exists?(File.join(library, "kpg_mu_stale.py"))
      assert File.exists?(File.join(library, "handwritten.py"))
      assert File.exists?(File.join(library, "kpg_mu_basic.py"))
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "marks a deliberately failing library probe as a structural failure" do
      dir = File.tempname("kpg-spec")
      probe = LibraryProbe.new("kpg_lib_required", "library", "required",
        "# probe\ndef main():\n    pass\n", deliberate_failure: true)
      path = PlaybookBuilder.new(dir).build([library_task(probe)]).first

      meta = JSON.parse(File.read(path.sub(/\.yml$/, ".meta.json")))
      assert_equal(true, meta["structural_failure"].as_bool)
      assert_equal(true, meta["library"]["deliberate_failure"].as_bool)
    ensure
      FileUtils.rm_rf(dir) if dir
    end
  end
end
