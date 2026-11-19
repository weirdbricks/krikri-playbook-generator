require "./spec_helper"
require "../src/krikri_playbook_generator/corpus"
require "file_utils"
require "yaml"

module KrikriPlaybookGenerator
  describe Corpus do
    # A small but realistic ansible transcript, so the comparisons run on
    # text shaped like the real thing rather than on one-word stubs.
    def recap_output : String
      "PLAY [Replay] ***\n\nTASK [debug] ***\nok: [localhost]\n\n" \
      "PLAY RECAP ***\nlocalhost : ok=1 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0\n"
    end

    def with_corpus(&)
      root = File.tempname("kpg-corpus-spec")
      Dir.mkdir_p(root)
      begin
        yield root
      ensure
        FileUtils.rm_rf(root)
      end
    end

    def write_case(root : String, name : String, playbook : String? = "---\n- hosts: localhost\n",
                   expected : String? = "ok\n", notes : String? = nil) : String
      dir = File.join(root, name)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, Corpus::PLAYBOOK_FILE), playbook) if playbook
      File.write(File.join(dir, Corpus::EXPECTED_FILE), expected) if expected
      File.write(File.join(dir, Corpus::NOTES_FILE), notes) if notes
      dir
    end

    def output(stdout : String, stderr : String = "", rc : Int32 = 0,
               timed_out : Bool = false) : Corpus::Output
      Corpus::Output.new(stdout, stderr, rc, timed_out)
    end

    it "finds one case per subdirectory, parsing its playbook, recording and notes" do
      with_corpus do |root|
        write_case(root, "file-mode", playbook: "---\n- hosts: localhost\n  tasks: []\n",
          expected: "ok\n", notes: "real ansible chmods 0644, krikri 0600\n")
        write_case(root, "copy-content", expected: "changed\n")

        cases = Corpus.discover(root)
        assert_equal(%w[copy-content file-mode], cases.map(&.name))
        first = cases.first
        assert(first.usable?)
        assert_equal(File.join(root, "copy-content", "playbook.yml"), first.playbook_path)
        assert_equal(File.join(root, "copy-content", "expected.out"), first.expected_path)
        refute(first.role_layout)
        refute_nil(cases.last.notes)
        assert((cases.last.notes || "").includes?("chmods 0644"))
      end
    end

    it "treats a role layout (tasks/main.yml with defaults) as a case and builds an entry playbook" do
      with_corpus do |root|
        role = File.join(root, "role-drift")
        FileUtils.mkdir_p(File.join(role, "tasks"))
        FileUtils.mkdir_p(File.join(role, "defaults"))
        File.write(File.join(role, "tasks", "main.yml"), "---\n- debug: msg=hi\n")
        File.write(File.join(role, "defaults", "main.yml"), "---\n")
        File.write(File.join(role, Corpus::EXPECTED_FILE), recap_output)

        kase = Corpus.discover(root).first
        assert(kase.role_layout)
        assert_nil(kase.playbook_path)
        assert(kase.usable?)

        stage = File.tempname("kpg-corpus-stage")
        begin
          playbook = Corpus.build_playbook(kase, stage)
          # the entry playbook lives in the staging dir and runs a copy of
          # the role, so both engines resolve it from one absolute path
          assert_equal(File.join(stage, "role_drift.yml"), playbook)
          assert(File.exists?(File.join(stage, "roles", "role_drift", "tasks", "main.yml")))
          play = YAML.parse(File.read(playbook)).as_a.first
          assert_equal("kpg_targets", play["hosts"].as_s)
          assert_equal(["role_drift"], play["roles"].as_a.map(&.as_s))
          refute(play["gather_facts"].as_bool)
        ensure
          FileUtils.rm_rf(stage)
        end
      end
    end

    it "runs a flat case in place, so its sibling files and templates still resolve" do
      with_corpus do |root|
        write_case(root, "flat")
        kase = Corpus.discover(root).first
        stage = File.tempname("kpg-corpus-stage")
        begin
          assert_equal(File.join(root, "flat", "playbook.yml"), Corpus.build_playbook(kase, stage))
          # nothing was staged for a flat case
          refute(Dir.exists?(stage))
        ensure
          FileUtils.rm_rf(stage)
        end
      end
    end

    it "marks a case with a playbook but no recording as unusable instead of skipping it" do
      with_corpus do |root|
        write_case(root, "unrecorded", expected: nil)

        kase = Corpus.discover(root).first
        refute(kase.usable?)
        assert((kase.problem || "").includes?("expected.out"))
      end
    end

    it "marks a recording with no playbook and no role layout as unusable" do
      with_corpus do |root|
        write_case(root, "orphan", playbook: nil)

        kase = Corpus.discover(root).first
        refute(kase.usable?)
        assert((kase.problem || "").includes?("tasks/main.yml"))
      end
    end

    it "ignores directories that are not case-shaped and never treats live/ as a case" do
      with_corpus do |root|
        write_case(root, "real-case")
        FileUtils.mkdir_p(File.join(root, "shared-notes"))
        File.write(File.join(root, "shared-notes", "README.md"), "not a case\n")
        FileUtils.mkdir_p(File.join(root, Corpus::LIVE_DIR))
        File.write(File.join(root, Corpus::LIVE_DIR, Corpus::LIVE_CASES_FILE), "needs-a-host\n")

        assert_equal(%w[real-case], Corpus.discover(root).map(&.name))
      end
    end

    it "accepts a corpus directory that is itself a single case" do
      with_corpus do |root|
        write_case(root, "solo")
        solo = File.join(root, "solo")

        cases = Corpus.discover(solo)
        assert_equal(%w[solo], cases.map(&.name))
        assert_equal(File.join(solo, "playbook.yml"), cases.first.playbook_path)
      end
    end

    it "raises a CorpusError for a directory that does not exist" do
      err = assert_raises(Corpus::CorpusError) { Corpus.discover("/nonexistent/kpg-corpus") }
      assert((err.message || "").includes?("does not exist"))
    end

    it "parses live/cases.txt, ignoring comments and blanks and keeping the note" do
      with_corpus do |root|
        live = File.join(root, Corpus::LIVE_DIR)
        FileUtils.mkdir_p(live)
        File.write(File.join(live, Corpus::LIVE_CASES_FILE), <<-TXT)
          # cases that need a real package/service/crontab/pip mutation
          pip-virtualenv   pip install mutates the venv

          crontab-install # writes the spool

          service-restart
          TXT

        cases = Corpus.live_cases(root)
        assert_equal(%w[pip-virtualenv crontab-install service-restart], cases.map(&.name))
        assert_equal("pip install mutates the venv", cases.first.note)
        assert_equal("writes the spool", cases[1].note)
        assert_nil(cases.last.note)
      end
    end

    it "has no live cases when live/cases.txt is absent" do
      with_corpus do |root|
        assert_empty(Corpus.live_cases(root))
      end
    end

    describe "the three-way comparison" do
      it "passes when both engines match the recorded transcript" do
        verdict = Corpus.classify(output(recap_output), output(recap_output), recap_output)
        assert_equal(Corpus::Status::Pass, verdict.status)
        assert(verdict.engines_identical)
        assert_equal(true, verdict.krikri_matches_expected)
        assert_equal(true, verdict.ansible_matches_expected)
        assert_equal("", verdict.engine_diff)
        assert_nil(verdict.reason)
      end

      it "regresses when the engines disagree, naming the engine diff" do
        krikri = recap_output.sub("ok=1 changed=0", "ok=1 changed=1")
        verdict = Corpus.classify(output(recap_output), output(krikri), recap_output)
        assert_equal(Corpus::Status::Regressed, verdict.status)
        refute(verdict.engines_identical)
        assert_equal(true, verdict.ansible_matches_expected)
        assert_equal(false, verdict.krikri_matches_expected)
        assert(verdict.engine_diff.includes?("stdout:"))
        assert(verdict.engine_diff.includes?("+localhost : ok=1 changed=1"))
        assert(verdict.expected_diff.includes?("+localhost : ok=1 changed=1"))
        refute_nil(ByteDiff.signature(verdict.engine_diff))
      end

      it "drifts when the engines agree but the recording no longer matches" do
        newer = recap_output.sub("ok=1", "ok=2")
        verdict = Corpus.classify(output(newer), output(newer), recap_output)
        assert_equal(Corpus::Status::Drifted, verdict.status)
        assert(verdict.engines_identical)
        assert_equal(false, verdict.krikri_matches_expected)
        assert_equal(false, verdict.ansible_matches_expected)
        assert_equal("", verdict.engine_diff)
        assert(verdict.drift_diff.includes?("-localhost : ok=1 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0"))
        assert(verdict.drift_diff.includes?("+localhost : ok=2 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0"))
        refute_nil(ByteDiff.signature(verdict.drift_diff))
      end

      it "fails to run when ansible could not start instead of calling it a divergence" do
        verdict = Corpus.classify(output("", rc: -1), output(recap_output), recap_output)
        assert_equal(Corpus::Status::FailedToRun, verdict.status)
        assert((verdict.reason || "").includes?("ansible could not run"))
        assert_nil(verdict.krikri_matches_expected)
      end

      it "fails to run when krikri hung past the per-engine timeout" do
        verdict = Corpus.classify(output(recap_output), output("", rc: 124, timed_out: true), recap_output)
        assert_equal(Corpus::Status::FailedToRun, verdict.status)
        assert((verdict.reason || "").includes?("krikri timed out"))
      end

      it "fails to run when the case has no recording to compare against" do
        verdict = Corpus.classify(output(recap_output), output(recap_output), nil)
        assert_equal(Corpus::Status::FailedToRun, verdict.status)
        assert((verdict.reason || "").includes?("no expected.out"))
        # the engines still agreed; the case is not a krikri bug
        assert(verdict.engines_identical)
      end

      it "treats an exit-code-only difference as a regression with a signature" do
        verdict = Corpus.classify(output(recap_output, rc: 0), output(recap_output, rc: 2), recap_output)
        assert_equal(Corpus::Status::Regressed, verdict.status)
        refute(verdict.engines_identical)
        assert(verdict.engine_diff.includes?("rc:"))
        assert(verdict.engine_diff.includes?("-0"))
        assert(verdict.engine_diff.includes?("+2"))
        refute_nil(ByteDiff.signature(verdict.engine_diff))
      end

      it "applies the explicit masks and ignores trailing-newline differences" do
        warning = "[WARNING]: Host 'localhost' is using the discovered Python interpreter " \
                  "at /usr/bin/python3, but future installation of another Python interpreter " \
                  "could change this.\n"
        recorded = recap_output.chomp
        ansi = output(warning + recap_output, rc: 0)
        plain = output(recap_output + "\n\n")

        verdict = Corpus.classify(ansi, plain, recorded)
        assert_equal(Corpus::Status::Pass, verdict.status)
        assert_equal("", verdict.engine_diff)
        # a real difference is still a difference
        refute(Corpus.matches_expected?(output(recap_output.sub("ok=1", "ok=9")), recorded))
      end

      it "accepts a recording taken with 2>&1 (stdout then stderr)" do
        stderr = "noise on stderr\n"
        verdict = Corpus.classify(output(recap_output, stderr), output(recap_output, stderr), recap_output + stderr)
        assert_equal(Corpus::Status::Pass, verdict.status)
      end

      it "normalizes CRLF and trailing newlines identically on both sides" do
        assert_equal("a\nb", Corpus.normalize("a\r\nb\r\n\r\n"))
        assert_equal("", Corpus.normalize("\n\n"))
      end
    end

    it "sanitizes a case name into a legal ansible role name" do
      assert_equal("file_mode_drift", Corpus.role_name_for("file-mode.drift"))
      assert_equal("copy_content_2", Corpus.role_name_for("copy_content-2"))
    end
  end
end
