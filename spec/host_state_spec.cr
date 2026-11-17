require "./spec_helper"
require "../src/krikri_playbook_generator/host_state"

module KrikriPlaybookGenerator
  describe HostState do
    def baseline : String
      <<-SNAP
        #boot
        boot-1
        #files
        d\t0\t0\t755\t4096\t/tmp/kpg-work
        f\t0\t0\t644\t100\t/etc/passwd
        f\t0\t0\t644\t100\t/etc/group
        #hashes
        h1  /etc/passwd
        h2  /etc/group
        #packages
        bash\t5.2
        #units
        cron.service
        #ports
        /proc/net/tcp\t0100007F:1F90
        SNAP
    end

    it "parses sections and canonicalizes their order" do
      first = HostState::Snapshot.parse(baseline)
      refute_nil(first)
      snapshot = first.as(HostState::Snapshot)
      shuffled = HostState::Snapshot.parse("#ports\n/proc/net/tcp\t0100007F:1F90\n#boot\nboot-1\n" \
                                           "#files\nf\t0\t0\t644\t100\t/etc/group\nf\t0\t0\t644\t100\t/etc/passwd\n" \
                                           "d\t0\t0\t755\t4096\t/tmp/kpg-work\n#hashes\nh2  /etc/group\nh1  /etc/passwd\n" \
                                           "#packages\nbash\t5.2\n#units\ncron.service\n")
      refute_nil(shuffled)
      assert_equal(snapshot.canonical, shuffled.as(HostState::Snapshot).canonical)
      assert_equal(snapshot.digest, shuffled.as(HostState::Snapshot).digest)
      assert_equal(["f\t0\t0\t644\t100\t/etc/passwd", "f\t0\t0\t644\t100\t/etc/group"],
        snapshot["files"][1..])
    end

    it "keeps every section a truncated snapshot did arrive with" do
      snapshot = HostState::Snapshot.parse("#boot\nboot-1\n#files\nf\t0\t0\t644\t1\t/etc/x\n")
      refute_nil(snapshot)
      assert_equal(["boot-1"], snapshot.as(HostState::Snapshot)["boot"])
      assert_equal([] of String, snapshot.as(HostState::Snapshot)["packages"])
      assert_nil(HostState::Snapshot.parse("not a snapshot"))
    end

    it "reports the deltas a module leaves behind, not the whole host" do
      before_snapshot = HostState::Snapshot.parse(baseline).as(HostState::Snapshot)
      after = HostState::Snapshot.parse(baseline
        .sub("f\t0\t0\t644\t100\t/etc/passwd", "f\t0\t0\t600\t100\t/etc/passwd")
        .sub("h1  /etc/passwd", "h9  /etc/passwd")
        .sub("f\t0\t0\t644\t100\t/etc/group", "f\t1000\t0\t644\t100\t/etc/group\nf\t0\t0\t644\t7\t/tmp/kpg-work/leftover")
        .sub("/proc/net/tcp\t0100007F:1F90", "/proc/net/tcp\t0100007F:1F90\n/proc/net/tcp\t0100007F:0050")
        .sub("cron.service", "cron.service\nsshd.service")
        .sub("bash\t5.2", "bash\t5.2\ncurl\t8.0")).as(HostState::Snapshot)

      changes = HostState.changes(before_snapshot, after)
      assert_includes(changes, "file\tchanged\tf\t0\t0\t644\t100\t/etc/passwd\tf\t0\t0\t600\t100\t/etc/passwd")
      assert_includes(changes, "file\tchanged\tf\t0\t0\t644\t100\t/etc/group\tf\t1000\t0\t644\t100\t/etc/group")
      assert_includes(changes, "hash\tchanged\th1  /etc/passwd\th9  /etc/passwd")
      assert_includes(changes, "package\tadded\tcurl\t8.0")
      assert_includes(changes, "unit\tadded\tsshd.service")
      assert_includes(changes, "port\tadded\t/proc/net/tcp\t0100007F:0050")
      assert_includes(changes, "file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover")
      assert_equal(changes, changes.sort)
    end

    it "reports a reboot as one stable line" do
      before_snapshot = HostState::Snapshot.parse(baseline).as(HostState::Snapshot)
      rebooted = HostState::Snapshot.parse(baseline.sub("boot-1", "boot-2")).as(HostState::Snapshot)
      assert_equal(["boot\trebooted"], HostState.changes(before_snapshot, rebooted))
    end

    it "sees no change when both snapshots are the same" do
      snapshot = HostState::Snapshot.parse(baseline).as(HostState::Snapshot)
      assert_equal([] of String, HostState.changes(snapshot, snapshot))
      assert_equal("", HostState.diff([] of String, [] of String))
      assert_nil(HostState.signature(""))
    end

    it "diffs one engine's changes against the other's" do
      ansible = ["file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover"]
      krikri = [] of String
      diff = HostState.diff(ansible, krikri)
      assert_includes(diff, "-file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover")
      signature = HostState.signature(diff)
      refute_nil(signature)
      assert(signature.as(String).starts_with?("state:"))
      other = HostState.signature(HostState.diff(
        ["file\tadded\tf\t0\t0\t600\t9\t/tmp/kpg-work/other"], krikri))
      assert_equal(signature, other)
    end

    it "snapshots the documented roots and excludes per-host files" do
      script = HostState::SNAPSHOT_SCRIPT
      HostState::ROOTS.each { |root| assert_includes(script, root) }
      HostState::EXCLUDED_PATHS.each { |path| assert_includes(script, path) }
      refute_includes(script, "ROOTS;")
      refute_includes(script, "EXCLUDE_PREDICATE")
      assert_includes(script, "${Package}\\t${Version}\\n")
      assert_includes(script, "%{NAME}\\t%{VERSION}-%{RELEASE}\\n")
      assert_includes(script, "\\( -path /etc/hostname")
    end

    it "finds nothing to report when a check-mode run left the host alone" do
      snapshot = HostState::Snapshot.parse(baseline).as(HostState::Snapshot)
      assert_equal([] of String, HostState.check_mode_changes(snapshot, snapshot))
      assert_nil(HostState.check_mode_changes(nil, snapshot))
      assert_nil(HostState.check_mode_changes(snapshot, nil))
    end

    it "reports what a check-mode run changed, including two engines agreeing" do
      before_snapshot = HostState::Snapshot.parse(baseline).as(HostState::Snapshot)
      after = HostState::Snapshot.parse(baseline
        .sub("f\t0\t0\t644\t100\t/etc/passwd", "f\t0\t0\t600\t100\t/etc/passwd")
        .sub("bash\t5.2", "bash\t5.2\ncurl\t8.0")
        .sub("cron.service", "cron.service\nsshd.service")).as(HostState::Snapshot)

      changes = HostState.check_mode_changes(before_snapshot, after)
      refute_nil(changes)
      assert_includes(changes.as(Array(String)), "package\tadded\tcurl\t8.0")
      assert_includes(changes.as(Array(String)), "unit\tadded\tsshd.service")
      assert_includes(changes.as(Array(String)),
        "file\tchanged\tf\t0\t0\t644\t100\t/etc/passwd\tf\t0\t0\t600\t100\t/etc/passwd")
    end

    it "ignores the engines' documented control-side keepers in check mode" do
      before_snapshot = HostState::Snapshot.parse(baseline).as(HostState::Snapshot)
      after = HostState::Snapshot.parse(baseline
        .sub("cron.service", "cron.service\nsshd.service")
        .sub("#hashes\n", "#hashes\nh3  /root/.ansible/tmp/staged\n")).as(HostState::Snapshot)

      changes = HostState.check_mode_changes(before_snapshot, after)
      refute_nil(changes)
      assert_equal(["unit\tadded\tsshd.service"], changes)
      assert(HostState.check_mode_ignored?("hash\tadded\th3  /root/.ansible/tmp/staged"))
      refute(HostState.check_mode_ignored?("file\tadded\tf\t0\t0\t644\t7\t/root/.ansiblex"))
    end

    it "signs a check-mode mutation by the engine that made it" do
      krikri = "krikri:\n+ krikri: file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover\n"
      signature = HostState.check_mode_signature(krikri)
      refute_nil(signature)
      assert(signature.as(String).starts_with?("check-mode:"))
      other = HostState.check_mode_signature(
        "krikri:\n+ krikri: file\tadded\tf\t0\t0\t600\t9\t/tmp/kpg-work/other\n")
      assert_equal(signature, other)
      ansible = HostState.check_mode_signature(
        "ansible:\n+ ansible: file\tadded\tf\t0\t0\t644\t7\t/tmp/kpg-work/leftover\n")
      refute_equal(signature, ansible)
      assert_nil(HostState.check_mode_signature(""))
    end

    it "only calls a run successful when it neither failed nor timed out" do
      ok = HostState::Observation.new(Cmd::Result.new(0, "ok", ""))
      assert(HostState.succeeded?(ok))
      refute(HostState.succeeded?(HostState::Observation.new(Cmd::Result.new(2, "ok", ""))))
      refute(HostState.succeeded?(HostState::Observation.new(Cmd::Result.new(0, "ok", "", true))))
      refute(HostState.succeeded?(HostState::Observation.new(
        Cmd::Result.new(0, "fatal: [target]: FAILED! => boom", ""))))
    end
  end
end
