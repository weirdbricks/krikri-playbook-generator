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
      assert_equal("all", play["hosts"].as_s)
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
        first = GeneratedTask.new("stat", "ansible.builtin", {"path" => YAML::Any.new(Fixtures::SOURCE_FILES.first)})
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
        assert_equal("all", play["hosts"].as_s)
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
