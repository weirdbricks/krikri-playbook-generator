require "./spec_helper"
require "../src/krikri_playbook_generator/corpus_runner"
# Options (reached through Runner) names DelegationMode, which generator.cr
# defines; a spec that requires Runner directly has to load it too, the way
# runner_spec.cr does.
require "../src/krikri_playbook_generator/generator"
require "../src/krikri_playbook_generator/playbook_builder"
require "../src/krikri_playbook_generator/triage"
require "file_utils"
require "json"

module KrikriPlaybookGenerator
  describe CorpusRunner do
    def krikri_bin : String
      Process.find_executable("krikri-playbook") || "/home/labros/git_work/krikri/bin/krikri-playbook"
    end

    def engines_missing? : Bool
      !Process.find_executable("ansible-playbook") || !File.exists?(krikri_bin)
    end

    def write_playbook(dir : String, message : String) : Nil
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "playbook.yml"), <<-YAML)
        ---
        - name: Replay corpus case
          hosts: localhost
          gather_facts: false
          tasks:
            - name: Debug message
              ansible.builtin.debug:
                msg: #{message.inspect}
        YAML
    end

    def rows_by_case(results_dir : String) : Hash(String, JSON::Any)
      parsed = {} of String => JSON::Any
      File.each_line(File.join(results_dir, "results.jsonl")) do |line|
        row = JSON.parse(line)
        parsed[row["corpus_case"].as_s] = row
      end
      parsed
    end

    it "replays a synthetic corpus, classifying pass/drift/failure/live-skip and writing triage rows" do
      skip("needs ansible-playbook and krikri-playbook on this machine") if engines_missing?
      corpus = File.tempname("kpg-corpus")
      results = File.tempname("kpg-corpus-results")
      begin
        # a case whose recording is written from the first replay's ansible
        # stdout+stderr, the way a corpus is recorded in the first place
        write_playbook(File.join(corpus, "debug-msg"), "corpus replay spec")
        File.write(File.join(corpus, "debug-msg", "NOTES.md"), "krikri once dropped the msg\n")
        File.write(File.join(corpus, "debug-msg", "expected.out"), "")
        # a case with no recording at all: loud, never a silent pass
        write_playbook(File.join(corpus, "unrecorded"), "no recording")
        # a case the corpus lists as needing a real host: skipped even
        # though its directory exists and would run here
        write_playbook(File.join(corpus, "pip-virtualenv"), "needs a live host")
        File.write(File.join(corpus, "pip-virtualenv", "expected.out"), "should never be compared\n")
        FileUtils.mkdir_p(File.join(corpus, "live"))
        File.write(File.join(corpus, "live", "cases.txt"), <<-TXT)
          # live-mutation cases
          pip-virtualenv   pip install mutates the venv
          crontab-install  writes the spool
          TXT

        first = CorpusRunner.new(corpus, results, krikri_bin: krikri_bin, engine_timeout: 60).run
        assert_equal(%w[crontab-install debug-msg pip-virtualenv unrecorded], first.map(&.name))

        rows = rows_by_case(results)
        # the empty recording makes the case drift, not regress: the engines
        # agree, the RECORDING is what does not match
        assert_equal("drifted", rows["debug-msg"]["corpus_status"].as_s)
        assert_equal("failed-to-run", rows["unrecorded"]["corpus_status"].as_s)
        assert((rows["unrecorded"]["corpus_reason"].as_s).includes?("expected.out"))
        assert_equal("skipped", rows["pip-virtualenv"]["corpus_status"].as_s)
        assert((rows["pip-virtualenv"]["corpus_reason"].as_s).includes?("needs live host"))
        assert_equal("skipped", rows["crontab-install"]["corpus_status"].as_s)

        # the skipped case never ran an engine
        assert(rows["pip-virtualenv"]["ansible"].raw.nil?)
        refute(rows["debug-msg"]["ansible"].raw.nil?)

        # record the transcript from the real engine, then replay again: the
        # case must now pass all three comparisons
        recorded = rows["debug-msg"]["ansible"]["stdout"].as_s + rows["debug-msg"]["ansible"]["stderr"].as_s
        File.write(File.join(corpus, "debug-msg", "expected.out"), recorded)

        second = CorpusRunner.new(corpus, results, krikri_bin: krikri_bin, engine_timeout: 60).run
        assert_equal(Corpus::Status::Pass, second.find { |row| row.name == "debug-msg" }.as(CorpusRunner::Row).status)

        rows = rows_by_case(results)
        row = rows["debug-msg"]
        assert_equal("pass", row["corpus_status"].as_s)
        assert_equal("debug-msg", row["module"].as_s)
        assert_equal("replay", row["mode"].as_s)
        assert_equal(true, row["masked_identical"].as_bool)
        refute(row["divergent"].as_bool)
        assert(row["diff"].as_h.has_key?("expected"))
        assert(row["diff"].as_h.has_key?("drift"))
        assert_equal("krikri once dropped the msg", row["corpus_notes"].as_s.strip)

        versions = File.read_lines(File.join(results, "versions.txt"))
        assert(versions.any?(&.starts_with?("corpus: ")))
        assert(versions.includes?("corpus cases: 3"))
        assert(versions.includes?("corpus live cases: 2"))

        triage = Triage.new(results)
        report = triage.corpus_report
        refute_nil(report)
        report = report.as(Triage::CorpusReport)
        assert_equal(4, report.total)
        assert_equal(1, report.passed)
        assert_equal(2, report.skipped)
        assert_equal(1, report.failed)
        # replay rows are not fuzz rows: no happy-path coverage, no rates
        assert_equal(0, triage.happy_coverage.attempted)
        assert_empty(triage.rates)
        assert_empty(triage.quality)
        parsed = JSON.parse(triage.report_json)
        assert_equal(4, parsed["corpus"]["total"].as_i)
        assert_equal(1, parsed["corpus"]["failed_to_run"].as_i)
      ensure
        FileUtils.rm_rf(corpus) if corpus
        FileUtils.rm_rf(results) if results
      end
    end

    it "records an engine that cannot run the case as failed-to-run instead of a divergence" do
      skip("needs ansible-playbook on this machine") unless Process.find_executable("ansible-playbook")
      corpus = File.tempname("kpg-corpus")
      results = File.tempname("kpg-corpus-results")
      begin
        write_playbook(File.join(corpus, "debug-msg"), "krikri is missing")
        File.write(File.join(corpus, "debug-msg", "expected.out"), "whatever\n")

        rows = CorpusRunner.new(corpus, results, krikri_bin: "/nonexistent/krikri-playbook",
          engine_timeout: 60).run
        assert_equal(Corpus::Status::FailedToRun, rows.first.status)
        assert((rows.first.reason || "").includes?("krikri could not run"))

        row = rows_by_case(results)["debug-msg"]
        assert_equal("failed-to-run", row["corpus_status"].as_s)
        refute(row["divergent"].as_bool)
        assert((row["error"].as_s).includes?("krikri could not run"))
      ensure
        FileUtils.rm_rf(corpus) if corpus
        FileUtils.rm_rf(results) if results
      end
    end

    # The corpus's own input conventions: a recording normalizes its scratch
    # directory to <WORK>, a case can select --check/extra args via flags.txt,
    # and a case can pin its inventory. A replay that ignored any of them
    # classifies a faithful case as drifted (or refuses the check-mode case).
    it "replays a case's <WORK>/flags.txt/inventory.ini conventions" do
      skip("needs ansible-playbook and krikri-playbook on this machine") if engines_missing?
      corpus = File.tempname("kpg-corpus")
      results = File.tempname("kpg-corpus-results")
      begin
        dir = File.join(corpus, "conventions")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "playbook.yml"), <<-'YAML')
          ---
          - name: Replay corpus case
            hosts: pinned
            gather_facts: false
            tasks:
              - name: Show the scratch dir, the mode and a var from flags.txt
                ansible.builtin.debug:
                  msg: "dir={{ playbook_dir }}/roles check={{ ansible_check_mode }} extra={{ case_extra }}"
              - name: Write a file
                ansible.builtin.copy:
                  content: "hello\n"
                  dest: "{{ playbook_dir }}/created.txt"
                  mode: "0644"
          YAML
        # only this inventory defines `pinned`, so the play resolves a host
        # only when the case's own inventory.ini is what the engines get
        File.write(File.join(dir, "inventory.ini"), <<-INI)
          [pinned]
          localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3
          INI
        File.write(File.join(dir, "flags.txt"), <<-TXT)
          --check
          -e
          case_extra=from-flags
          TXT
        File.write(File.join(dir, "expected.out"), "")

        first = CorpusRunner.new(corpus, results, krikri_bin: krikri_bin, engine_timeout: 60).run
        # the engines agree; it is the empty recording that does not match yet
        assert_equal(Corpus::Status::Drifted, first.first.status)

        row = rows_by_case(results)["conventions"]
        recorded = row["ansible"]["stdout"].as_s + row["ansible"]["stderr"].as_s
        # flags.txt decided the invocation: check mode and its extra var
        assert(recorded.includes?("check=True"))
        assert(recorded.includes?("extra=from-flags"))
        # the case's inventory made `pinned` resolve to a host
        assert(recorded.includes?("ok: [localhost]"))
        refute(recorded.includes?("skipping: no hosts matched"))
        # no --diff was added: the recording is a plain real-mode transcript
        refute(recorded.includes?("--- before"))
        # and the scratch path the engines printed is rewritten to <WORK>
        work_dir = File.dirname(row["playbook"].as_s)
        assert(work_dir.includes?("kpg-corpus"))
        File.write(File.join(dir, "expected.out"), Corpus.normalize(recorded, work_dir))

        second = CorpusRunner.new(corpus, results, krikri_bin: krikri_bin, engine_timeout: 60).run
        replayed = second.first
        assert_equal(Corpus::Status::Pass, replayed.status)
        assert_equal(true, replayed.verdict.as(Corpus::Verdict).krikri_matches_expected)
      ensure
        FileUtils.rm_rf(corpus) if corpus
        FileUtils.rm_rf(results) if results
      end
    end

    it "replays a case in a fresh podman container pair, the only isolated backend", tags: :slow do
      skip("podman not available on this machine") unless PodmanBackend.available?
      skip("no krikri-playbook binary to stage into the container") unless File.exists?(krikri_bin)
      corpus = File.tempname("kpg-corpus")
      results = File.tempname("kpg-corpus-results")
      begin
        write_playbook(File.join(corpus, "debug-msg"), "podman corpus replay")
        File.write(File.join(corpus, "debug-msg", "expected.out"), "a stale recording\n")

        rows = CorpusRunner.new(corpus, results, krikri_bin: krikri_bin, engine_timeout: 120,
          run_on_podman: true).run
        assert_equal(1, rows.size)
        # both engines ran inside their own container and agreed; only the
        # stale recording differs, which is drift, not a regression
        assert_equal(Corpus::Status::Drifted, rows.first.status)
        row = rows_by_case(results)["debug-msg"]
        assert(row["ansible"]["stdout"].as_s.includes?("PLAY RECAP"))
        assert_equal(row["ansible"]["stdout"].as_s, row["krikri"]["stdout"].as_s)
      ensure
        FileUtils.rm_rf(corpus) if corpus
        FileUtils.rm_rf(results) if results
      end
    end
  end
end
