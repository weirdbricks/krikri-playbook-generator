require "json"
require "file_utils"
require "./atlantic_backend"
require "./cmd"
require "./connection_profile"
require "./corpus"
require "./log"
require "./masks"
require "./podman_backend"
require "./reference_version"
require "./run_context"
require "./run_mode"
require "./runner"
require "./versions"

module KrikriPlaybookGenerator
  # Executes a curated divergence corpus (`--replay-corpus DIR`) through both
  # engines and records one results.jsonl row per case, in the shape
  # `Runner` writes, so `report`/Triage reads a replay batch unchanged.
  #
  # The invocation is the same shape the fuzz runner uses locally - one
  # absolute playbook path and cwd per case, `ANSIBLE_NOCOLOR=1` and the
  # gathering/cache env vars stripped (ENGINE_ENV_STRIP), stdin closed, a
  # per-engine `timeout` so a hang is rc 124, raw stdout/stderr/rc captured -
  # but deliberately REAL mode: the corpus records what real
  # ansible-playbook prints, and a `--check` transcript is not comparable to
  # it. Replay therefore mutates the host it runs on exactly like the
  # original repro did; that is why the corpus's live-mutation cases are
  # skipped (`live/cases.txt`) and why the gate belongs on a disposable or
  # already-isolated host.
  #
  # Corpus rows are not fuzz rows: `module` carries the CASE NAME (so Triage
  # groups by case), `mode` is `replay`, and each row adds the three-way
  # verdict under `corpus_*`/`diff.expected`/`diff.drift` (see `Corpus`).
  class CorpusRunner
    # The mode `report` shows for a replay row; Triage treats it like any
    # other opaque mode label, and the corpus section is what the gate reads.
    REPLAY_MODE = "replay"

    # One replayed (or skipped) case: everything results.jsonl needs, plus
    # the verdict Triage counts. `playbook` is the path both engines ran
    # (nil when the case never got that far) and `profile` is the host image
    # a podman row used ("debian" for local rows, which have none).
    record Row, name : String, dir : String, playbook : String?, status : Corpus::Status,
      verdict : Corpus::Verdict?, ansible : Runner::EngineRun?, krikri : Runner::EngineRun?,
      notes : String?, expected_path : String?, reason : String? = nil,
      profile : String = "debian" do
      def status_label : String
        status.label
      end
    end

    def initialize(@corpus_dir : String, @results_dir : String,
                   @ansible_playbook_bin : String = "ansible-playbook",
                   @krikri_bin : String = "krikri-playbook", @engine_timeout : Int32 = 120,
                   @keep_going : Bool = false, @diff : Bool = true, @control : Bool = false,
                   @run_on_podman : Bool = false)
    end

    # Replays every case and returns one row per case (plus one skipped row
    # per live case), sorted by case name so the gate's output is stable.
    def run : Array(Row)
      started = Time.utc
      cases = Corpus.discover(@corpus_dir)
      live = Corpus.live_cases(@corpus_dir)
      log_start(cases.size, live.size)
      stage = File.tempname("kpg-corpus")
      live_names = live.map(&.name)
      replayable = cases.reject { |kase| live_names.includes?(kase.name) }
      backend = @run_on_podman && !replayable.empty? ? provision_podman(replayable) : nil
      rows = [] of Row
      begin
        rows.concat(replay_cases(cases, live, stage, backend))
        rows.concat(skipped_rows(live, cases))
      ensure
        backend.try(&.teardown)
        report_leaks if backend
        FileUtils.rm_rf(stage)
      end
      rows.sort_by!(&.name)
      Dir.mkdir_p(@results_dir)
      log("writing results.jsonl + versions.txt")
      write_results(rows)
      write_versions(started, cases.size, live.size)
      log_summary(rows, started)
      rows
    end

    # The backends replay supports are local and podman: podman gives each
    # case a FRESH container pair, so the engines never see each other's
    # files/packages - which is what makes a recording reproducible at all
    # (a local replay shares one host, so a case whose transcript includes
    # pre-existing state can legitimately differ between the two engines).
    # Provisioning is the fuzz runner's: one union-dependency template pair
    # per profile the cases need, reused from the content-addressed cache.
    private def provision_podman(cases : Array(Corpus::Case)) : PodmanBackend
      unless PodmanBackend.available?
        raise PodmanProvisionError.new("--run-on-podman was requested but `podman` isn't on PATH")
      end

      backend = PodmanBackend.new(@krikri_bin, @engine_timeout, @control, module_fqcns(cases),
        diff: @diff)
      podman_profiles(cases).each { |profile| backend.provision(profile) }
      backend
    end

    # Every module FQCN the cases name, so the template's union dependency
    # set covers them (a missing package would fail the reference engine
    # identically on both sides and hide the comparison).
    private def module_fqcns(cases : Array(Corpus::Case)) : Array(String)
      cases.flat_map do |kase|
        case_module_names(kase).map do |name|
          name.includes?(".") ? name : "ansible.builtin.#{name}"
        end
      end.uniq!
    end

    # The modules a case names: its playbook for a flat case, its role task
    # files for a role layout (there is no playbook to read).
    private def case_module_names(kase : Corpus::Case) : Array(String)
      text = if playbook = kase.playbook_path
               File.read(playbook)
             else
               Corpus::ROLE_TASK_FILES.compact_map do |entry|
                 path = File.join(kase.dir, entry)
                 File.exists?(path) ? File.read(path) : nil
               end.join("\n")
             end
      Runner.modules_from_playbook(text)
    rescue File::Error
      [] of String
    end

    # The template pair each case needs: the rpm family (dnf/yum/filesystem
    # users) only exists on the Rocky template, everything else stays on
    # Debian, exactly like Runner#podman_profile_for.
    private def podman_profiles(cases : Array(Corpus::Case)) : Array(PodmanBackend::Profile)
      profiles = cases.map do |kase|
        rpm = case_module_names(kase).any? do |name|
          AtlanticBackend::PROFILE_FOR_MODULE[name.split(".").last]? == "rpm"
        end
        rpm ? PodmanBackend::Profile::Rpm : PodmanBackend::Profile::Debian
      end
      profiles.uniq!
      profiles.empty? ? [PodmanBackend::Profile::Debian] : profiles
    end

    private def replay_cases(cases : Array(Corpus::Case), live : Array(Corpus::LiveCase),
                             stage : String, backend : PodmanBackend?) : Array(Row)
      live_names = live.map(&.name)
      rows = [] of Row
      cases.each_with_index do |kase, index|
        # The corpus's live list is authoritative even when the case dir
        # exists: running it here would mutate the gate's host.
        row = if live_names.includes?(kase.name)
                skipped_row(kase.name, kase.dir, live_note(live, kase.name), kase.notes, kase.expected_path)
              else
                guarded(kase) { replay(kase, File.join(stage, Corpus.role_name_for(kase.name)), backend) }
              end
        log_progress(index, cases.size, kase.name, row.status)
        rows << row
      end
      rows
    end

    # One live-listed case that has no directory of its own still gets a
    # skipped row: the corpus says it needs a live host, and the gate must
    # show that it existed rather than dropping it.
    private def skipped_rows(live : Array(Corpus::LiveCase), cases : Array(Corpus::Case)) : Array(Row)
      dirs = cases.map(&.name)
      cases_file = File.join(@corpus_dir, Corpus::LIVE_DIR, Corpus::LIVE_CASES_FILE)
      live.reject { |entry| dirs.includes?(entry.name) }.map do |entry|
        skipped_row(entry.name, cases_file, entry.note, nil, nil)
      end
    end

    private def skipped_row(name : String, dir : String, note : String?, notes : String?,
                            expected_path : String?) : Row
      reason = note ? "#{Corpus::LIVE_REASON} (#{note})" : Corpus::LIVE_REASON
      Row.new(name, dir, nil, Corpus::Status::Skipped, nil, nil, nil, notes, expected_path, reason)
    end

    private def live_note(live : Array(Corpus::LiveCase), name : String) : String?
      live.find { |entry| entry.name == name }.try(&.note)
    end

    private def replay(kase : Corpus::Case, stage_dir : String, backend : PodmanBackend?) : Row
      if problem = kase.problem
        return Row.new(kase.name, kase.dir, nil, Corpus::Status::FailedToRun, nil, nil, nil,
          kase.notes, kase.expected_path, problem)
      end

      FileUtils.mkdir_p(stage_dir)
      playbook = Corpus.build_playbook(kase, stage_dir)
      profile = podman_profiles([kase]).first
      ansible, krikri = backend ? run_in_pair(backend, profile, playbook) : run_both(playbook)
      expected = kase.expected_path.try { |path| File.read(path) }
      verdict = Corpus.classify(to_output(ansible), to_output(krikri), expected)
      Row.new(kase.name, kase.dir, playbook, verdict.status, verdict, ansible, krikri,
        kase.notes, kase.expected_path, verdict.reason, profile.debian? ? "debian" : "rocky")
    end

    # Both engines get the identical invocation: one inventory file, the same
    # absolute playbook path and cwd, and (with --control) real ansible on
    # BOTH sides, so any non-pass row is a harness gap or a missing mask
    # rather than krikri.
    private def run_both(playbook : String) : {Runner::EngineRun, Runner::EngineRun}
      inventory = write_inventory
      cwd = File.dirname(playbook)
      begin
        ansible = run_engine("ansible", @ansible_playbook_bin, playbook, inventory, cwd)
        krikri = run_engine("krikri", @control ? @ansible_playbook_bin : @krikri_bin,
          playbook, inventory, cwd)
        {ansible, krikri}
      ensure
        File.delete(inventory) if File.exists?(inventory)
      end
    end

    private def write_inventory : String
      path = File.tempname("kpg-corpus-inventory")
      File.write(path, Corpus::INVENTORY)
      path
    end

    # Podman: one fresh container pair for the case (never a pair reused
    # across cases, so a case cannot see the previous one's state), the
    # case's whole tree copied beside the playbook, and the corpus
    # inventory, so a `localhost` or `kpg_targets` repro matches its one
    # host on this backend too.
    private def run_in_pair(backend : PodmanBackend, profile : PodmanBackend::Profile,
                            playbook : String) : {Runner::EngineRun, Runner::EngineRun}
      comparison = backend.run_playbook(playbook, profile, check: false, second_run: false,
        diff: @diff, umask: DEFAULT_UMASK, extra_dirs: Corpus.support_dirs(playbook),
        inventory: Corpus::INVENTORY).first
      {to_engine_run("ansible", comparison[:ansible]),
       to_engine_run("krikri", comparison[:krikri])}
    end

    private def to_engine_run(engine : String, observation : HostState::Observation) : Runner::EngineRun
      result = observation.result
      timed_out = result.timed_out || result.rc == Cmd::TIMEOUT_RC
      Runner::EngineRun.new(engine, result.rc, Runner::Recap.parse(result.stdout),
        result.stdout, result.stderr, timed_out, observation.before, observation.after)
    end

    private def report_leaks : Nil
      leaks = PodmanBackend.leak_check
      STDERR.puts "ERROR: leaked containers after teardown: #{leaks.join(", ")}" unless leaks.empty?
    end

    # The fuzz runner's local invocation shape, minus the mode matrix: no
    # `--check` (a corpus recording is a real-mode transcript), `--diff`
    # unless --no-diff, the same `-e kpg_owner/kpg_group` defaults so a repro
    # that templates them renders the same value on both sides, and the
    # engine killed at --engine-timeout (rc 124) rather than wedging the
    # gate.
    private def run_engine(engine : String, bin : String, playbook : String,
                           inventory : String, cwd : String) : Runner::EngineRun
      args = [@engine_timeout.to_s, bin, "-i", inventory]
      args << "--diff" if @diff
      args << "-e" << "kpg_owner=root" << "-e" << "kpg_group=root"
      args << playbook
      script = "umask #{DEFAULT_UMASK}; #{ENGINE_ENV_STRIP} timeout \"$@\""
      result = Cmd.run("bash", ["-c", script, "kpg"] + args,
        timeout: @engine_timeout + 30.0, chdir: cwd)
      Runner::EngineRun.new(engine, result.rc, Runner::Recap.parse(result.stdout),
        result.stdout, result.stderr, result.timed_out || result.rc == Cmd::TIMEOUT_RC)
    end

    private def to_output(run : Runner::EngineRun) : Corpus::Output
      Corpus::Output.new(run.stdout, run.stderr, run.rc, run.timed_out)
    end

    private def guarded(kase : Corpus::Case, &) : Row
      yield
    rescue e : Exception
      raise e unless @keep_going

      message = "replay failed: #{e.message || e.class.to_s}"
      Log.warn("corpus", "#{kase.name}: #{message} - continuing (--keep-going)")
      Row.new(kase.name, kase.dir, nil, Corpus::Status::FailedToRun, nil, nil, nil,
        kase.notes, kase.expected_path, message)
    end

    private def log_start(cases : Int32, live : Int32) : Nil
      log("replaying #{cases} case(s) from #{@corpus_dir} " \
          "(#{live} live case(s) skipped, backend=#{@run_on_podman ? "podman" : "local"}, " \
          "results=#{@results_dir})")
    end

    private def log(message : String) : Nil
      Log.info("corpus", message, color: Log::BLUE)
    end

    private def log_progress(index : Int32, total : Int32, name : String,
                             status : Corpus::Status) : Nil
      verdict = case status
                in Corpus::Status::Pass        then Log.paint(Log::GREEN, "pass")
                in Corpus::Status::Regressed   then Log.paint(Log::YELLOW, "REGRESSED")
                in Corpus::Status::Drifted     then Log.paint(Log::YELLOW, "drifted")
                in Corpus::Status::FailedToRun then Log.paint(Log::RED, "failed-to-run")
                in Corpus::Status::Skipped     then Log.paint(Log::DIM, "skipped (needs live host)")
                end
      log("case #{index + 1}/#{total} #{name} (#{verdict})")
    end

    private def log_summary(rows : Array(Row), started : Time) : Nil
      counts = Corpus::Status.values.map { |status| [status.label, rows.count { |row| row.status == status }] }
      log("replay complete in #{(Time.utc - started).total_seconds.round(1)}s: " \
          "#{rows.size} case(s), #{counts.map { |(label, count)| "#{count} #{label}" }.join(", ")}")
    end

    private def write_results(rows : Array(Row)) : Nil
      File.open(File.join(@results_dir, "results.jsonl"), "w") do |file|
        rows.each { |row| file.puts(result_json(row)) }
      end
    end

    # One row in `Runner#result_json`'s shape (Triage reads both the same
    # way) plus the replay's own fields: `corpus_case`/`corpus_status`/
    # `corpus_reason`/`corpus_notes`, and `diff.expected` (krikri vs the
    # recording) and `diff.drift` (ansible vs the recording) next to the
    # engine-vs-engine `diff.masked`/`diff.raw`.
    private def result_json(row : Row) : String
      verdict = row.verdict
      JSON.build do |json|
        json.object do
          json.field "playbook", row.playbook
          json.field "corpus_case", row.name
          json.field "corpus_dir", row.dir
          json.field "corpus_expected", row.expected_path
          json.field "corpus_status", row.status_label
          json.field "corpus_reason", row.reason
          json.field "corpus_notes", row.notes
          json.field "module", row.name
          json.field "mode", REPLAY_MODE
          json.field "run", 1
          json.field "user", UserProfile::Local.label
          json.field "umask", DEFAULT_UMASK
          json.field "hosts", 1
          json.field "limit", "off"
          json.field "connection", ConnectionProfile.local.label
          json.field "profile", row.profile
          json.field "core_version", Runner::DEFAULT_CORE_VERSION
          json.field "env", nil
          json.field "chaos", false
          json.field "mutations", nil
          # A replay row is not a generated happy path, so it never counts as
          # wasted coverage; `report` keeps it out of the quality metric by
          # `corpus_status`, not by lying about ansible's exit code.
          json.field "ansible_failed", false
          json.field "ansible_error", nil
          json.field "state_divergent", false
          json.field "state_signature", nil
          json.field "state_diff", nil
          json.field "check_mode_mutated", false
          json.field "check_mode_diff", nil
          json.field "leftover_temps", nil
          json.field "error", error_for(row)
          json.field "divergent", row.status.regressed?
          json.field "masked_identical", verdict.try(&.engines_identical)
          json.field "raw_identical", raw_identical?(row)
          json.field "recap_divergent", false
          json.field "signature", verdict.try { |value| ByteDiff.signature(value.engine_diff) }
          json.field "diff" do
            json.object do
              json.field "masked", verdict.try(&.engine_diff) || ""
              json.field "raw", raw_diff(row)
              json.field "expected", verdict.try(&.expected_diff) || ""
              json.field "drift", verdict.try(&.drift_diff) || ""
            end
          end
          engine_field(json, "ansible", row.ansible)
          engine_field(json, "krikri", row.krikri)
        end
      end
    end

    # A case that never ran is an ERROR in the report's own errors section
    # (it is the corpus or the harness at fault, not krikri); a regression is
    # a divergence, and drift is reported by the corpus section without
    # pretending an engine failed.
    private def error_for(row : Row) : String?
      row.status.failed_to_run? ? row.reason : nil
    end

    private def raw_identical?(row : Row) : Bool?
      ansible = row.ansible
      krikri = row.krikri
      return unless ansible && krikri
      return false unless ansible.rc == krikri.rc && ansible.timed_out == krikri.timed_out

      ansible.stdout == krikri.stdout && ansible.stderr == krikri.stderr
    end

    private def raw_diff(row : Row) : String
      ansible = row.ansible
      krikri = row.krikri
      return "" unless ansible && krikri

      String.build do |str|
        str << "stdout:\n" << ByteDiff.unified(ansible.stdout, krikri.stdout)
        str << "stderr:\n" << ByteDiff.unified(ansible.stderr, krikri.stderr)
      end
    end

    private def engine_field(json : JSON::Builder, name : String,
                             run : Runner::EngineRun?) : Nil
      if run
        json.field(name) { engine_json(json, run) }
      else
        json.field name, nil
      end
    end

    private def engine_json(json : JSON::Builder, run : Runner::EngineRun) : Nil
      json.object do
        json.field "rc", run.rc
        json.field "timed_out", run.timed_out
        if recap = run.recap
          json.field "recap" do
            json.object do
              json.field "ok", recap.ok
              json.field "changed", recap.changed
              json.field "unreachable", recap.unreachable
              json.field "failed", recap.failed
              json.field "skipped", recap.skipped
              json.field "ignored", recap.ignored
            end
          end
        else
          json.field "recap", nil
        end
        json.field "stdout", run.stdout
        json.field "stderr", run.stderr
      end
    end

    # Provenance in the same file `run` writes, plus the corpus it replayed:
    # a gate results dir has to say which corpus and how many cases it
    # covered. A versions.txt failure is a lost metadata file, never a reason
    # to lose the results already on disk.
    private def write_versions(started : Time, cases : Int32, live : Int32) : Nil
      Versions.write(@results_dir, VERSION, @krikri_bin, @ansible_playbook_bin, @control,
        [RunMode::Real], false, @diff, Time.utc - started, started,
        user_profiles: [UserProfile::Local.label], umasks: [DEFAULT_UMASK], hosts: [1],
        limits: ["off"], connections: [ConnectionProfile.local.label],
        reference_versions: [Runner::DEFAULT_CORE_VERSION])
      File.open(File.join(@results_dir, "versions.txt"), "a") do |file|
        file.puts "corpus: #{Path[@corpus_dir].expand(home: true)}"
        file.puts "corpus cases: #{cases}"
        file.puts "corpus live cases: #{live}"
      end
    rescue e
      STDERR.puts "warning: could not write versions.txt: #{e.message}"
    end
  end
end
