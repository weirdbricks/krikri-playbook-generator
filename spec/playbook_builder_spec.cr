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
