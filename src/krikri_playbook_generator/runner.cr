require "json"
require "yaml"
require "./cmd"
require "./log"
require "./podman_backend"
require "./atlantic_backend"
require "./microvm_backend"
require "./masks"
require "./host_state"
require "./run_mode"
require "./fixtures"
require "./versions"
require "./options"

module KrikriPlaybookGenerator
  # Executes each generated playbook against both engines and records the
  # outcome.
  #
  # The comparison is BYTE-FOR-BYTE on the podman path (the reliable
  # differential mode): both engines run the identical invocation - same
  # absolute playbook path and cwd inside the container, ANSIBLE_NOCOLOR=1,
  # caching/gathering env vars stripped, stdin </dev/null, per-engine
  # `timeout` (a hang is its own result, rc 124) - inside a FRESH container
  # pair per playbook, so no state leaks between playbooks. Raw stdout,
  # stderr and rc are captured from both engines; divergence is judged
  # after applying ByteDiff::MASKS (the single, explicitly justified mask
  # list) to both sides. The old PLAY RECAP counter comparison is kept as
  # an extra `recap_divergent` field.
  #
  # Podman and microVM runs also compare HOST STATE (HostState): each
  # engine's host is snapshotted before and after its run, and the two
  # before/after deltas are diffed, so a task that prints the same result
  # but leaves a different file mode, owner, leftover file, package or
  # service is still a divergence (`state_divergent`). Only deltas are
  # compared because the two engine hosts start from different images
  # (README/AGENTS.md). The local and Atlantic backends do not capture
  # state: locally the engines share one live host, so a delta cannot be
  # attributed per engine.
  #
  # Two backends:
  #
  # - **Local** (`run_on_podman: false`, the default) - runs directly on
  #   this machine (`-i localhost, -c local`), `--check --diff` unless
  #   `--allow-mutation` is passed, since happy-path tasks are real modules
  #   that would otherwise install packages, create users, etc. on *this*
  #   machine. Byte parity here is best-effort: the two engines run
  #   sequentially on the same (non-fresh) host, so state can legitimately
  #   differ between them.
  # - **Podman** (opt-in via `--run-on-podman`, requires `podman` on PATH)
  #   - `PodmanBackend`, which is where byte-parity claims actually hold.
  # - **Atlantic.net** (opt-in via `--run-on-atlantic`) - `AtlanticBackend`,
  #   one disposable VM per module profile, for the modules that need a real
  #   service or kernel (packages, databases, containers, zfs, ...).
  #
  # With `keep_going: true` a per-playbook failure (e.g. a podman error
  # mid-batch) is recorded as an errored result and the batch continues;
  # with it false (the default) the error aborts the run.
  #
  class Runner
    record Recap, ok : Int32, changed : Int32, unreachable : Int32, failed : Int32,
      skipped : Int32, ignored : Int32 do
      def self.parse(text : String) : Recap?
        # Only the PLAY RECAP section carries the real counters; task
        # output above it can contain incidental ok=N-shaped text that
        # would otherwise corrupt the parse (last match wins per key).
        lines = text.lines
        recap_index = lines.index(&.starts_with?("PLAY RECAP"))
        return unless recap_index

        counts = {} of String => Int32
        lines[(recap_index + 1)..].join('\n').scan(/(ok|changed|unreachable|failed|skipped|ignored)=(\d+)/) { |match| counts[match[1]] = match[2].to_i }
        return unless %w[ok changed unreachable failed skipped ignored].all? { |key| counts.has_key?(key) }

        Recap.new(counts["ok"], counts["changed"], counts["unreachable"], counts["failed"], counts["skipped"], counts["ignored"])
      end
    end

    # The host-state snapshots around each engine's run (nil on backends
    # without the state oracle: local and Atlantic).
    record EngineRun, engine : String, rc : Int32, recap : Recap?, stdout : String, stderr : String,
      timed_out : Bool = false, state_before : HostState::Snapshot? = nil,
      state_after : HostState::Snapshot? = nil

    # `module_name` is the playbook's primary module (the first task's;
    # for a v2 multi-task playbook, `module_names` carries every task's
    # module so profile selection and the supported-community check cover
    # the whole playbook, not just its first task).
    # `env` is the playbook's play-level keyword when it arrived through
    # an environment variable (ANSIBLE_STRATEGY / ANSIBLE_FORKS): the
    # sidecar carries it because the playbook file cannot, and every
    # backend must export it identically for both engines.
    record MetaInfo, module_name : String, chaos : Bool, mutations : Array({String, String}),
      module_names : Array(String), env : Hash(String, String) = {} of String => String,
      structural_failure : Bool = false do
      def self.primary(module_name : String, chaos : Bool, mutations : Array({String, String})) : MetaInfo
        MetaInfo.new(module_name, chaos, mutations, [module_name])
      end
    end

    class PlaybookResult
      getter playbook : String
      getter ansible : EngineRun
      getter krikri : EngineRun
      getter meta : MetaInfo?
      getter error : String?
      # Which half of the mode matrix this row compares, and whether it is
      # the first run or the second-run idempotency pass.
      getter mode : RunMode
      getter run : Int32
      # Which identity, umask and host count this row ran under (the
      # context matrix).
      getter user : UserProfile
      getter umask : String
      getter hosts : Int32
      # The `--limit` symbol this row ran under ("off" when the axis was
      # not requested at all); the actual ansible pattern comes from
      # Options.limit_pattern.
      getter limit : String

      # "(check, run 1, nonroot, umask 022)" - one row's matrix point; the
      # host count and limit are appended only when they are not the
      # default, so a plain batch's log lines stay as they were.
      def context_label : String
        label = "(#{mode.label}, run #{run}, #{user.label}, umask #{umask}"
        label += ", hosts #{hosts}" unless hosts == 1
        label += ", limit #{limit}" unless limit == "off"
        "#{label})"
      end

      @state_diff : String?
      @state_divergent : Bool
      # Per-engine check-mode deltas (only populated for a check-mode row).
      getter check_mode_ansible : Array(String)?
      getter check_mode_krikri : Array(String)?
      # Staging files each engine left behind (nil when no snapshots were
      # captured), each line annotated with the task the log blames when it
      # names one.
      getter leftover_temps_ansible : Array(String)?
      getter leftover_temps_krikri : Array(String)?

      def initialize(@playbook, @ansible, @krikri, @meta, @error = nil,
                     @mode = RunMode::Real, @run = 1,
                     @user = UserProfile::Root, @umask = DEFAULT_UMASK, @hosts = 1,
                     @limit = "off")
        @error ||= PlaybookResult.reference_harness_gap(@ansible)
        @leftover_temps_ansible = PlaybookResult.annotate_leftovers(@ansible)
        @leftover_temps_krikri = PlaybookResult.annotate_leftovers(@krikri)
        diff = compute_state_diff
        @state_diff = diff
        @state_divergent = !diff.nil?
        if @mode.check?
          @check_mode_ansible = HostState.check_mode_changes(@ansible.state_before, @ansible.state_after)
          @check_mode_krikri = HostState.check_mode_changes(@krikri.state_before, @krikri.state_after)
        else
          @check_mode_ansible = nil
          @check_mode_krikri = nil
        end
      end

      def self.annotate_leftovers(run : EngineRun) : Array(String)?
        leftovers = HostState.leftover_temps(run.state_before, run.state_after)
        return unless leftovers

        owner = Runner.last_failed_task(run.stdout)
        leftovers.map { |line| owner ? "#{line} (task: #{owner})" : line }
      end

      UNRESOLVED      = /couldn't resolve module\/action '[^']+'/
      MISSING_LIBRARY = /Failed to import the required Python library \(([^)]+)\)/

      # Real ansible could not even run the task (its module or a python
      # library it needs is missing on the reference host): a harness gap,
      # never a krikri finding, so it is recorded as an error rather than a
      # divergence.
      def self.reference_harness_gap(run : EngineRun) : String?
        line = (run.stdout + '\n' + run.stderr).lines.find(&.=~(UNRESOLVED))
        return "reference ansible cannot load the module (harness gap, not krikri): #{line.strip}" if line
        lib_line = (run.stdout + '\n' + run.stderr).lines.find(&.=~(MISSING_LIBRARY))
        "reference ansible is missing a python library (harness gap, not krikri; add it to the rpm/deb real package lists in data/module_dependencies.yml): #{lib_line.try(&.strip)}" if lib_line
      end

      def self.errored(playbook : String, meta : MetaInfo?, message : String,
                       mode : RunMode = RunMode::Real, run : Int32 = 1,
                       user : UserProfile = UserProfile::Root, umask : String = DEFAULT_UMASK,
                       hosts : Int32 = 1, limit : String = "off") : PlaybookResult
        failed = EngineRun.new("ansible", -1, nil, "", "", false)
        PlaybookResult.new(playbook, failed, failed, meta, message, mode, run, user, umask, hosts, limit)
      end

      # The environment variables the playbook's sidecar asks the engines
      # to run under (empty when the keyword is a play key).
      def env : Hash(String, String)
        meta.try(&.env) || {} of String => String
      end

      def raw_identical? : Bool
        return false if @error
        same_exit? && ansible.stdout == krikri.stdout && ansible.stderr == krikri.stderr
      end

      # The primary byte-parity verdict: identical only when rc, timeout
      # state and masked stdout/stderr all match.
      def masked_identical? : Bool
        return false if @error
        same_exit? &&
          ByteDiff.mask(ansible.stdout) == ByteDiff.mask(krikri.stdout) &&
          ByteDiff.mask(ansible.stderr) == ByteDiff.mask(krikri.stderr)
      end

      def divergent? : Bool
        return false if @error

        !masked_identical? || @state_divergent || check_mode_mutation? || leftover_temp?
      end

      # A staging file survived an engine's run: `copy`/`template`/
      # `blockinfile` with a failing `validate`, or a killed engine.
      def leftover_temp? : Bool
        return false if @error

        @leftover_temps_ansible.try { |list| !list.empty? } ||
          @leftover_temps_krikri.try { |list| !list.empty? } || false
      end

      # Each engine's leftovers with the task the log blames, so a state
      # finding can name the file instead of only showing a raw delta.
      def leftover_temps_diff : String?
        return unless leftover_temp?

        String.build do |str|
          append_leftovers(str, "ansible", @leftover_temps_ansible)
          append_leftovers(str, "krikri", @leftover_temps_krikri)
        end
      end

      # What each engine changed on its own host, from the snapshots taken
      # before and after its run (nil when they were not captured).
      def ansible_state_changes : Array(String)?
        state_changes(ansible)
      end

      def krikri_state_changes : Array(String)?
        state_changes(krikri)
      end

      # Unified diff of the two engines' change lists; nil when both changed
      # the same thing (or no snapshots were taken).
      def state_diff : String?
        @state_diff
      end

      # A state difference the stdout/stderr comparison cannot see: same
      # printed result, different files/modes/owners/packages/services.
      def state_divergent? : Bool
        return false if @error

        @state_divergent
      end

      def state_signature : String?
        state_diff.try { |diff| HostState.signature(diff) }
      end

      # A `--check` run that changed its host. Judged per engine: two
      # engines that agree on a mutation are still both wrong in check
      # mode, and the delta-vs-delta comparison above cannot see that.
      def check_mode_mutation? : Bool
        return false if @error

        @check_mode_ansible.try { |changes| !changes.empty? } ||
          @check_mode_krikri.try { |changes| !changes.empty? } || false
      end

      # The engines' unexpected check-mode deltas as a `-`/`+` diff, so the
      # triage signature can tell "ansible broke check mode" from "krikri
      # did" and generalize the paths like every other finding.
      def check_mode_diff : String?
        return unless check_mode_mutation?

        String.build do |str|
          append_check_mode_changes(str, "ansible", @check_mode_ansible)
          append_check_mode_changes(str, "krikri", @check_mode_krikri)
        end
      end

      def check_mode_signature : String?
        check_mode_diff.try { |diff| HostState.check_mode_signature(diff) }
      end

      private def append_check_mode_changes(str : String::Builder, engine : String,
                                            changes : Array(String)?) : Nil
        return unless list = changes
        return if list.empty?

        str << engine << ":\n"
        list.each { |line| str << "+ #{engine}: " << line << '\n' }
      end

      private def append_leftovers(str : String::Builder, engine : String,
                                   leftovers : Array(String)?) : Nil
        return unless list = leftovers
        return if list.empty?

        str << engine << ":\n"
        list.each { |line| str << "+ #{line}\n" }
      end

      private def state_changes(run : EngineRun) : Array(String)?
        before = run.state_before
        after = run.state_after
        return unless before && after

        HostState.changes(before, after)
      end

      private def compute_state_diff : String?
        a = state_changes(ansible)
        k = state_changes(krikri)
        return unless a && k

        diff = HostState.diff(a, k)
        return diff unless diff.empty?

        # Both engines' deltas matched, but a staging file survived on one
        # of them: still a finding, shown by the same state section.
        leftover_temp? ? leftover_temps_diff : nil
      end

      # The old counter-only comparison, kept as an extra results field.
      def recap_divergent? : Bool
        return false if @error

        a = ansible.recap
        k = krikri.recap
        return true if a.nil? != k.nil?
        return false if a.nil?

        a != k
      end

      def signature : String?
        return if @error

        ByteDiff.signature(masked_diff)
      end

      def masked_diff : String
        stream_diffs(true)
      end

      def raw_diff : String
        stream_diffs(false)
      end

      # True when the REAL ansible engine failed (a happy-path playbook
      # that failed on the reference engine is wasted coverage, not a
      # divergence candidate). ignore_errors keeps rc at 0 and moves the
      # count to `ignored`, so all three signals matter.
      def ansible_failed? : Bool
        return false if @error
        # A shape that fails deliberately is the comparison under test, not
        # wasted happy-path coverage; its byte/state findings still report.
        return false if meta.try(&.structural_failure)

        ansible.rc != 0 || ansible.timed_out ||
          (ansible.recap.try(&.ignored) || 0) > 0 ||
          ansible.stdout.includes?("fatal:") || ansible.stderr.includes?("fatal:")
      end

      def ansible_error_line : String?
        return unless ansible_failed?

        text = ansible.stdout + '\n' + ansible.stderr
        line = text.lines.find { |candidate| candidate =~ /fatal:|FAILED|ERROR!|error:/i }
        candidate = line || text.lines.find { |candidate| !candidate.blank? }
        return unless candidate

        candidate.size > 200 ? candidate[0, 200] : candidate
      end

      private def same_exit? : Bool
        ansible.rc == krikri.rc && ansible.timed_out == krikri.timed_out
      end

      private def stream_diffs(masked : Bool) : String
        a_stdout = masked ? ByteDiff.mask(ansible.stdout) : ansible.stdout
        k_stdout = masked ? ByteDiff.mask(krikri.stdout) : krikri.stdout
        a_stderr = masked ? ByteDiff.mask(ansible.stderr) : ansible.stderr
        k_stderr = masked ? ByteDiff.mask(krikri.stderr) : krikri.stderr

        String.build do |str|
          str << "stdout:\n"
          str << ByteDiff.unified(a_stdout, k_stdout)
          str << "stderr:\n"
          str << ByteDiff.unified(a_stderr, k_stderr)
        end
      end
    end

    # The task the run log blames for a leftover staging file: the last
    # `TASK [name]` that printed a `fatal:` line. Generated playbooks carry
    # `ignore_errors: true`, so "the last task in the log" is not good
    # enough - the batch keeps going after a failure.
    def self.last_failed_task(output : String) : String?
      current = nil
      failed = nil
      output.each_line do |line|
        if match = line.match(/^TASK \[(.+?)\]/)
          current = match[1]
        elsif current && (line.includes?("fatal:") || line.includes?("FAILED!"))
          failed = current
        end
      end
      failed
    end

    @completed : Atomic(Int32) = Atomic.new(0)
    @planned : Int32 = 0

    def initialize(@playbook_paths : Array(String), @results_dir : String, @atlantic_hosts : Int32 = 22,
                   @ansible_playbook_bin : String = "ansible-playbook",
                   @krikri_bin : String = "/home/labros/git_work/krikri/bin/krikri-playbook",
                   @modes : Array(RunMode) = [RunMode::Check], @run_on_podman : Bool = false,
                   @run_on_atlantic : Bool = false, @run_on_microvm : Bool = false,
                   @run_on_mixed : Bool = false, @second_run : Bool = true,
                   @keep_going : Bool = false, @engine_timeout : Int32 = 120,
                   @control : Bool = false, @refresh_podman_templates : Bool = false,
                   @podman_parallel : Int32 = 1, @microvm_dir : String = MicrovmBackend::DEFAULT_DIR,
                   @microvm_parallel : Int32 = 1, @diff : Bool = true,
                   @user_profiles : Array(UserProfile) = [UserProfile::Root],
                   @umasks : Array(String) = [DEFAULT_UMASK],
                   @hosts : Array(Int32) = [1], @limits : Array(String) = ["off"])
    end

    # Every (identity, umask, host-count, limit) point the batch runs.
    # Each gets its own fresh host/pair, so a non-root row can never share
    # state with a root one, and each row gets the inventory and
    # invocation it asks for.
    private def contexts : Array({UserProfile, String, Int32, String})
      @user_profiles.flat_map do |user|
        @umasks.flat_map do |umask|
          @hosts.flat_map do |hosts|
            @limits.map { |limit| {user, umask, hosts, limit} }
          end
        end
      end
    end

    # "runner" is blue so the per-playbook verdict colors stay the
    # brightest thing on the line.
    private def log(message : String) : Nil
      Log.info("runner", message, color: Log::BLUE)
    end

    # One line per finished comparison, so a long batch shows where it is:
    #   12:34:56 [runner] comparison 5/12 complete: 000004-file-chaos.yml (check, run 1) (DIVERGENT)
    private def progress(result : PlaybookResult) : PlaybookResult
      done = @completed.add(1) + 1
      verdict = if result.error
                  Log.paint(Log::RED, "errored")
                elsif result.divergent?
                  Log.paint(Log::YELLOW, "DIVERGENT")
                else
                  Log.paint(Log::GREEN, "ok")
                end
      log("comparison #{done}/#{@planned} complete: " \
          "#{File.basename(result.playbook)} #{result.context_label} (#{verdict})")
      result
    end

    # The second-run row is logged without the planned counter: whether it
    # runs depends on the first run succeeding on both engines.
    private def log_second_run(result : PlaybookResult) : PlaybookResult
      verdict = result.divergent? ? Log.paint(Log::YELLOW, "DIVERGENT") : Log.paint(Log::GREEN, "ok")
      log("second run complete: #{File.basename(result.playbook)} #{result.context_label} (#{verdict})")
      result
    end

    def run : Array(PlaybookResult)
      started = Time.utc
      if @run_on_podman && !PodmanBackend.available?
        raise PodmanProvisionError.new("--run-on-podman was requested but `podman` isn't on PATH")
      end
      if @run_on_atlantic && !AtlanticBackend.available?
        raise AtlanticProvisionError.new("--run-on-atlantic was requested but the KeePass credential source isn't available")
      end
      if @run_on_microvm && !MicrovmBackend.available?
        raise MicrovmProvisionError.new("--run-on-microvm was requested but qemu-system-x86_64 or /dev/kvm isn't available")
      end
      if @run_on_mixed && !PodmanBackend.available?
        raise PodmanProvisionError.new("--run-on-mixed was requested but `podman` isn't on PATH")
      end

      # The backend owns the identity question: the shared local host runs
      # as the invoking account, and Atlantic's VMs are only root.
      @user_profiles = [UserProfile::Local] if local_backend?
      @user_profiles = [UserProfile::Root] if @run_on_atlantic
      @planned = @playbook_paths.size * @modes.size * contexts.size
      log("starting #{@playbook_paths.size} playbook(s) x #{@modes.map(&.label).join("+")} " \
          "mode(s) x #{@user_profiles.map(&.label).join("+")} x umask #{@umasks.join("+")} " \
          "x hosts #{@hosts.join("+")} x limit #{@limits.join("+")} " \
          "(backend=#{backend_label}, results=#{@results_dir})")
      Dir.mkdir_p(@results_dir)
      results = Log.phase("runner", "executing #{@playbook_paths.size} playbook(s) (#{backend_label})") do
        if @run_on_atlantic
          run_via_atlantic
        elsif @run_on_mixed
          run_via_mixed
        elsif @run_on_microvm
          run_via_microvm
        elsif @run_on_podman
          run_via_podman
        else
          run_locally
        end
      end
      log("writing results.jsonl + versions.txt")
      write_results(results)
      write_versions(started)
      divergent = results.count(&.divergent?)
      log("batch complete in #{(Time.utc - started).total_seconds.round(1)}s: " \
          "#{results.size} comparison(s), " \
          "#{Log.paint(Log::YELLOW, divergent.to_s)} divergent, " \
          "#{Log.paint(Log::RED, results.count(&.error).to_s)} errored")
      results
    end

    private def local_backend? : Bool
      !@run_on_podman && !@run_on_atlantic && !@run_on_microvm && !@run_on_mixed
    end

    private def backend_label : String
      return "atlantic" if @run_on_atlantic
      return "microvm" if @run_on_microvm
      return "mixed" if @run_on_mixed
      @run_on_podman ? "podman" : "local"
    end

    # The cheap backend for each playbook: podman unless a task's module
    # needs a real service or kernel (db, containers, misc, firewalld,
    # SELinux), which only a microVM (or Atlantic) can host. Modules that
    # are microvm-capable but do not need it (rpm family) stay on podman's
    # Rocky template, which is much cheaper than a VM boot.
    private def run_via_mixed : Array(PlaybookResult)
      podman_paths = [] of String
      microvm_paths = [] of String
      microvm_ready = MicrovmBackend.available?
      if !microvm_ready && @playbook_paths.any? { |path| MicrovmBackend.microvm_only?(load_meta(path).try(&.module_names) || [] of String) }
        log("warning: qemu-system-x86_64 or /dev/kvm is not available; service modules run on podman and will likely match-fail")
      end
      @playbook_paths.each do |path|
        names = load_meta(path).try(&.module_names) || [] of String
        if microvm_ready && MicrovmBackend.microvm_only?(names)
          microvm_paths << path
        else
          podman_paths << path
        end
      end
      log("mixed: #{podman_paths.size} playbook(s) on podman, #{microvm_paths.size} on microvm")
      results = [] of PlaybookResult
      results.concat(run_via_podman(podman_paths)) unless podman_paths.empty?
      results.concat(run_via_microvm(microvm_paths)) unless microvm_paths.empty?
      @playbook_paths.map { |path| results.find { |result| result.playbook == path } || raise "playbook #{path} never ran" }
    end

    # Groups the batch by the golden image the playbooks need (Ubuntu or
    # Rocky), bakes/reuses one golden per OS, then runs each playbook in its
    # own fresh VM pair. The OS choice mirrors the podman path: rpm and
    # SELinux modules need the Rocky image, everything else runs on Ubuntu.
    private def run_via_microvm(paths : Array(String) = @playbook_paths) : Array(PlaybookResult)
      return [] of PlaybookResult if paths.empty?
      MicrovmBackend.cleanup_stale(@microvm_dir)
      backend = MicrovmBackend.new(@krikri_bin, @engine_timeout, @microvm_dir,
        control: @control, diff: @diff)
      profiles = Hash(String, Array(String)).new do |hash, os|
        hash[os] = [] of String
      end
      paths.each do |path|
        names = load_meta(path).try(&.module_names) || [] of String
        profiles[MicrovmBackend.profile_for(names)] << path
      end
      begin
        profiles.each_key { |os| backend.provision(os) }
        log("microvm: running #{paths.size} playbook(s) " \
            "across #{profiles.size} profile(s) (#{profiles.map { |os, batch| "#{os}: #{batch.size}" }.join(", ")})")
        profiles.flat_map do |os, batch|
          Runner.in_parallel(batch, @microvm_parallel) do |path|
            contexts.flat_map do |(user, umask, hosts, limit)|
              @modes.flat_map do |mode|
                guarded_results(path, mode, user, umask, hosts, limit) do
                  runs = backend.run_playbook(path, os, check: mode.check?, second_run: @second_run,
                    user: user, umask: umask, hosts: hosts, env: play_env(path),
                    limit: Options.limit_pattern(limit), include_unreachable: limit != "off")
                  comparison_results(path, mode, runs, user, umask, hosts, limit)
                end
              end
            end
          end
        end.flatten
      ensure
        backend.teardown
      end
    end

    # Groups the batch by Atlantic profile (via each playbook's meta sidecar
    # module name) and lets the backend run one VM per profile. Unlisted
    # modules are a caller bug - refuse rather than silently running them
    # somewhere that can't satisfy their happy path.
    private def run_via_atlantic : Array(PlaybookResult)
      if @second_run
        log("atlantic: skipping the second-run idempotency pass (playbooks share one VM per profile)")
      end
      groups = Hash(String, Array(String)).new
      @playbook_paths.each do |path|
        # doc's own `module` field (and therefore the meta sidecar) is the
        # short name even when the schema was requested by FQCN; a v2
        # multi-task playbook needs a profile for EVERY task's module
        names = load_meta(path).try(&.module_names).try(&.map(&.split(".").last)) || [] of String
        raise AtlanticProvisionError.new("playbook #{File.basename(path)} has no meta module list") if names.empty?
        missing = names.find { |name| !AtlanticBackend::PROFILE_FOR_MODULE[name]? }
        raise AtlanticProvisionError.new("playbook #{File.basename(path)} (module #{missing.inspect}) has no Atlantic profile") if missing
        (groups[AtlanticBackend::PROFILE_FOR_MODULE[names.first]] ||= [] of String) << path
      end

      umask = @umasks.first? || DEFAULT_UMASK
      hosts = @hosts.first? || 1
      limit = @limits.first? || "off"
      backend = AtlanticBackend.new(@krikri_bin, @engine_timeout, @atlantic_hosts,
        diff: @diff, umask: umask, hosts: hosts,
        limit: Options.limit_pattern(limit), include_unreachable: limit != "off",
        env_for: ->(path : String) { play_env(path) },
        on_playbook_done: ->(path : String) {
          done = @completed.add(1) + 1
          log("comparison #{done}/#{@planned} complete: #{File.basename(path)} " \
              "(real, run 1, root, umask #{umask})")
        })
      backend.run_groups(groups).map do |entry|
        meta = load_meta(entry[:playbook])
        # a profile that never provisioned must not look like a matched pair
        # of engine failures - record it as an errored result instead
        if entry[:ansible].rc == -1 && entry[:krikri].rc == -1 &&
           entry[:ansible].stderr.includes?("profile provisioning failed")
          PlaybookResult.errored(entry[:playbook], meta, entry[:ansible].stderr, RunMode::Real, 1,
            UserProfile::Root, umask, hosts, limit)
        else
          PlaybookResult.new(entry[:playbook],
            to_engine_run("ansible", entry[:ansible]),
            to_engine_run("krikri", entry[:krikri]), meta, mode: RunMode::Real, run: 1,
            user: UserProfile::Root, umask: umask, hosts: hosts, limit: limit)
        end
      end
    end

    private def run_via_podman(paths : Array(String) = @playbook_paths) : Array(PlaybookResult)
      return [] of PlaybookResult if paths.empty?
      fqcns = paths.compact_map do |path|
        meta = load_meta(path)
        next unless meta

        meta.module_names.compact_map do |name|
          name.includes?(".") ? name : "ansible.builtin.#{name}"
        end
      end.flatten
      backend = PodmanBackend.new(@krikri_bin, @engine_timeout, @control, fqcns.uniq,
        refresh_templates: @refresh_podman_templates, diff: @diff)
      begin
        # rpm-family modules need the Rocky template pair; everything else
        # stays on Debian. A mixed batch provisions both templates and runs
        # each playbook against its own.
        profiles = Hash(PodmanBackend::Profile, Array(String)).new do |hash, profile|
          hash[profile] = [] of String
        end
        paths.each do |path|
          profiles[podman_profile_for(path)] << path
        end
        profiles.each_key { |profile| backend.provision(profile) }
        profile_counts = profiles.map { |profile, batch| [profile, batch.size] }
        log("podman: running #{profiles.values.sum(&.size)} playbook(s) " \
            "across #{profiles.size} profile(s) (#{profile_counts.map(&.join(": ")).join(", ")})")
        profiles.flat_map do |profile, batch|
          Runner.in_parallel(batch, @podman_parallel) do |path|
            contexts.flat_map do |(user, umask, hosts, limit)|
              @modes.flat_map do |mode|
                guarded_results(path, mode, user, umask, hosts, limit) do
                  runs = backend.run_playbook(path, profile, check: mode.check?, second_run: @second_run,
                    user: user, umask: umask, hosts: hosts, env: play_env(path),
                    limit: Options.limit_pattern(limit), include_unreachable: limit != "off")
                  comparison_results(path, mode, runs, user, umask, hosts, limit)
                end
              end
            end
          end
        end.flatten
      ensure
        backend.teardown
        report_leaks
      end
    end

    # A multi-task playbook runs on the Rpm image when ANY of its tasks
    # needs the rpm-family profile - the Debian image cannot satisfy an
    # rpm task, while the Rocky image runs Debian tasks via its union
    # dependency set.
    private def podman_profile_for(path : String) : PodmanBackend::Profile
      names = load_meta(path).try(&.module_names) || [] of String
      if names.any? { |name| AtlanticBackend::PROFILE_FOR_MODULE[name.split(".").last]? == "rpm" }
        PodmanBackend::Profile::Rpm
      else
        PodmanBackend::Profile::Debian
      end
    end

    private def run_locally : Array(PlaybookResult)
      supported = Dependencies.load.supported
      @playbook_paths.each do |path|
        meta = load_meta(path)
        fqcns = (meta.try(&.module_names) || [] of String).map do |name|
          name.includes?(".") ? name : "ansible.builtin.#{name.split(".").last}"
        end
        unsupported = fqcns.find do |fqcn|
          !fqcn.starts_with?("ansible.builtin.") && !supported.includes?(fqcn)
        end
        if unsupported
          raise PodmanProvisionError.new("playbook #{File.basename(path)} (module #{unsupported.inspect}) is a community module outside the supported set; use --run-on-podman or promote it in data/module_dependencies.yml")
        end
      end
      Fixtures.seed_local
      @playbook_paths.flat_map do |path|
        contexts.flat_map do |(user, umask, hosts, limit)|
          @modes.flat_map do |mode|
            guarded_results(path, mode, user, umask, hosts, limit) do
              comparison_results(path, mode,
                run_playbook_locally(path, mode, umask, hosts, play_env(path),
                  Options.limit_pattern(limit), limit != "off"),
                user, umask, hosts, limit)
            end
          end
        end
      end
    end

    private def run_playbook_locally(path : String, mode : RunMode, umask : String,
                                     hosts : Int32 = 1,
                                     env : Hash(String, String) = {} of String => String,
                                     limit : String? = nil,
                                     include_unreachable : Bool = false) : Array(HostState::Comparison)
      inventory = local_inventory(hosts, include_unreachable)
      runs = [local_comparison(path, mode, umask, inventory, env, limit)]
      if @second_run && HostState.succeeded?(runs.first[:ansible]) && HostState.succeeded?(runs.first[:krikri])
        runs << local_comparison(path, mode, umask, inventory, env, limit)
      end
      runs
    ensure
      if path = inventory
        File.delete(path) if File.exists?(path)
      end
    end

    # Local rows need a real inventory file as well: every play targets the
    # `kpg_targets` group, which the implicit `localhost,` inventory does
    # not define (the play would silently match no hosts).
    private def local_inventory(hosts : Int32, include_unreachable : Bool = false) : String
      path = File.tempname("kpg-inventory")
      File.write(path, HostInventory.render(hosts, include_unreachable))
      path
    end

    private def local_comparison(path : String, mode : RunMode, umask : String,
                                 inventory : String,
                                 env : Hash(String, String) = {} of String => String,
                                 limit : String? = nil) : HostState::Comparison
      {ansible: HostState::Observation.new(run_engine_locally(path, "ansible", @ansible_playbook_bin, mode, umask, inventory, env, limit)),
       krikri:  HostState::Observation.new(run_engine_locally(path, "krikri", @krikri_bin, mode, umask, inventory, env, limit))}
    end

    private def run_engine_locally(path : String, engine : String, bin : String, mode : RunMode,
                                   umask : String, inventory : String,
                                   env : Hash(String, String) = {} of String => String,
                                   limit : String? = nil) : Cmd::Result
      args = [@engine_timeout.to_s, bin, "-i", inventory]
      args << "--limit" << limit if limit
      args << "--check" if mode.check?
      args << "--diff" if @diff
      args << "-e" << "kpg_owner=root" << "-e" << "kpg_group=root"
      args << path

      Cmd.run("bash", ["-c", "umask #{umask}; #{ENGINE_ENV_STRIP} #{KrikriPlaybookGenerator.env_prefix(env)}timeout \"$@\"", "kpg"] + args,
        timeout: @engine_timeout + 30.0)
    end

    private def to_engine_run(engine : String, result : Cmd::Result) : EngineRun
      timed_out = result.timed_out || result.rc == Cmd::TIMEOUT_RC
      EngineRun.new(engine, result.rc, Recap.parse(result.stdout), result.stdout, result.stderr, timed_out)
    end

    private def to_engine_run(engine : String, observation : HostState::Observation) : EngineRun
      run = to_engine_run(engine, observation.result)
      EngineRun.new(run.engine, run.rc, run.recap, run.stdout, run.stderr, run.timed_out,
        observation.before, observation.after)
    end

    # Turns one mode's comparison passes into result rows: the first pass is
    # the planned comparison, a second pass (idempotency) is its own row so
    # a first-run finding stays attributable to the first run.
    private def comparison_results(path : String, mode : RunMode,
                                   runs : Array(HostState::Comparison),
                                   user : UserProfile, umask : String,
                                   hosts : Int32 = 1, limit : String = "off") : Array(PlaybookResult)
      results = [] of PlaybookResult
      runs.each_with_index do |comparison, index|
        run_number = index + 1
        result = PlaybookResult.new(path,
          to_engine_run("ansible", comparison[:ansible]),
          to_engine_run("krikri", comparison[:krikri]), load_meta(path),
          mode: mode, run: run_number, user: user, umask: umask, hosts: hosts, limit: limit)
        results << (run_number == 1 ? progress(result) : log_second_run(result))
      end
      results
    end

    # Runs up to `parallel` playbooks at once (--podman-parallel), each still
    # in its own fresh container pair. Cmd.run yields while podman works, so
    # the pairs overlap without threads. Results come back in batch order,
    # and a failure without --keep-going stops the workers from picking up
    # more playbooks and is re-raised only once they have all stopped, so the
    # backend's teardown still runs. Public for the specs.
    def self.in_parallel(paths : Array(String), parallel : Int32, &block : String -> T) : Array(T) forall T
      limit = Math.min(Math.max(parallel, 1), paths.size)
      return paths.map { |path| block.call(path) } if limit <= 1

      queue = Channel(Int32).new(paths.size)
      paths.each_index { |index| queue.send(index) }
      queue.close
      results = Array(T?).new(paths.size, nil)
      failure : Exception? = nil
      done = Channel(Nil).new(limit)
      limit.times do
        spawn do
          while failure.nil? && (index = queue.receive?)
            results[index] = block.call(paths[index])
          end
        rescue e : Exception
          failure = failure || e
        ensure
          done.send(nil)
        end
      end
      limit.times { done.receive }
      failed = failure
      raise failed if failed

      results.map { |result| result || raise "a playbook was scheduled but never ran" }
    end

    private def guarded_results(path : String, mode : RunMode, user : UserProfile, umask : String,
                                hosts : Int32 = 1, limit : String = "off",
                                &block : -> Array(PlaybookResult)) : Array(PlaybookResult)
      block.call
    rescue e : Exception
      raise e unless @keep_going

      STDERR.puts "warning: #{File.basename(path)}: #{e.message} - continuing (--keep-going)"
      [PlaybookResult.errored(path, load_meta(path), e.message || e.class.to_s, mode, 1, user, umask, hosts, limit)]
    end

    private def report_leaks : Nil
      leaks = PodmanBackend.leak_check
      STDERR.puts "ERROR: leaked containers after teardown: #{leaks.join(", ")}" unless leaks.empty?
    end

    # The play-level keyword a playbook carries through the environment
    # instead of a play key; the playbook file cannot express it, so every
    # backend exports the sidecar's mapping.
    private def play_env(path : String) : Hash(String, String)
      load_meta(path).try(&.env) || {} of String => String
    end

    private def load_meta(path : String) : MetaInfo?
      meta_path = path.sub(/\.yml$/, ".meta.json")
      return parse_meta(File.read(meta_path)) if File.exists?(meta_path)

      # fall back to the batch naming convention when no sidecar exists
      match = File.basename(path).match(/\A\d{6}-(.+)-(happy|chaos)\.yml\z/)
      if match
        return MetaInfo.primary(match[1], match[2] == "chaos", [] of {String, String})
      end

      # A hand-saved repro (a kpg issue's playbook block, `repro.yml`) has
      # neither a sidecar nor the batch name. Without its modules the template
      # installs none of their packages, and every module with a system or
      # Python dependency dies on the reference side as a "harness gap"
      # (issue #1298: seboolean's libselinux binding was never installed, so
      # its repro could never be verified).
      modules = Runner.modules_from_playbook(read_playbook(path))
      return if modules.empty?
      MetaInfo.new(modules.first, false, [] of {String, String}, modules)
    end

    private def read_playbook(path : String) : String
      File.read(path)
    rescue File::Error
      ""
    end

    PLAY_TASK_LISTS = %w[tasks pre_tasks post_tasks handlers]

    # Words a task or play uses for wiring, never for a module.
    TASK_KEYWORDS = %w[
      name action args any_errors_fatal async become become_exe become_flags
      become_method become_user changed_when check_mode collections connection
      debugger delay delegate_facts delegate_to diff environment failed_when
      gather_facts ignore_errors ignore_unreachable listen local_action loop
      loop_control module_defaults no_log notify order poll port register
      remote_user retries run_once tags throttle timeout until vars when
    ]

    # The modules a playbook names, in order of first appearance: every task's
    # module, including the ones nested in block/rescue/always, across all of
    # the play's task lists. Public for the specs.
    def self.modules_from_playbook(text : String) : Array(String)
      modules = [] of String
      YAML.parse_all(text).each do |document|
        plays = document.as_a? || [document]
        plays.each { |play| collect_play_modules(play, modules) }
      end
      modules.uniq!
    end

    private def self.collect_play_modules(play : YAML::Any, modules : Array(String)) : Nil
      fields = play.as_h?
      return unless fields
      PLAY_TASK_LISTS.each do |list|
        next unless tasks = fields[list]?.try(&.as_a?)
        tasks.each { |task| collect_task_modules(task, modules) }
      end
    end

    private def self.collect_task_modules(task : YAML::Any, modules : Array(String)) : Nil
      fields = task.as_h?
      return unless fields
      fields.each do |key, value|
        name = key.as_s
        case name
        when "block", "rescue", "always"
          value.as_a?.try(&.each { |entry| collect_task_modules(entry, modules) })
        when "action", "local_action"
          if action = value.as_s?
            action.split(/\s+/, 2).first?.try { |module_name| modules << module_name }
          end
        else
          # `with_items` and its siblings are loop wiring, like `loop`
          next if TASK_KEYWORDS.includes?(name) || name.starts_with?("with_")
          modules << name
        end
      end
    end

    private def parse_meta(text : String) : MetaInfo?
      parsed = JSON.parse(text).as_h?
      return unless parsed

      module_name = parsed["module"]?.try(&.as_s?)
      return unless module_name

      chaos = parsed["chaos"]?.try(&.as_bool?) || false
      mutations = parsed["mutations"]?.try(&.as_a?).try do |entries|
        entries.compact_map do |entry|
          entry_hash = entry.as_h?
          next unless entry_hash

          option = entry_hash["option"]?.try(&.as_s?)
          kind = entry_hash["kind"]?.try(&.as_s?)
          {option, kind} if option && kind
        end
      end || [] of {String, String}

      # A v2 multi-task sidecar carries one entry per task; fall back to
      # the primary module alone when it is absent (v1 sidecars).
      module_names = parsed["modules"]?.try(&.as_a?).try do |entries|
        entries.compact_map(&.as_h?.try { |task| task["module"]?.try(&.as_s?) })
      end
      module_names = [module_name] if !module_names || module_names.empty?
      module_names.unshift(module_name) unless module_names.includes?(module_name)

      MetaInfo.new(module_name, chaos, mutations, module_names, parse_play_env(parsed),
        parse_structural_failure(parsed))
    rescue JSON::ParseException
      nil
    end

    private def parse_structural_failure(parsed : Hash(String, JSON::Any)) : Bool
      parsed["structural_failure"]?.try(&.as_bool?) || false
    end

    # The sidecar's `play.env` mapping (ANSIBLE_STRATEGY/ANSIBLE_FORKS);
    # empty for a play-key variant or a legacy sidecar without a `play`.
    private def parse_play_env(parsed : Hash(String, JSON::Any)) : Hash(String, String)
      env = {} of String => String
      parsed["play"]?.try(&.as_h?).try(&.["env"]?).try(&.as_h?).try do |entries|
        entries.each do |name, value|
          env[name] = value.as_s if value.as_s?
        end
      end
      env
    end

    private def write_results(results : Array(PlaybookResult)) : Nil
      File.open(File.join(@results_dir, "results.jsonl"), "w") do |file|
        results.each { |result| file.puts(result_json(result)) }
      end
    end

    # Provenance for krikri-role-triager; a versions.txt failure is a lost
    # metadata file, never a reason to lose the results.jsonl already on
    # disk.
    private def write_versions(started : Time) : Nil
      Versions.write(@results_dir, VERSION, @krikri_bin, @ansible_playbook_bin,
        @control, @modes, @second_run, @diff, Time.utc - started, started,
        user_profiles: @user_profiles.map(&.label), umasks: @umasks, hosts: @hosts,
        limits: @limits)
    rescue e
      STDERR.puts "warning: could not write versions.txt: #{e.message}"
    end

    private def result_json(result : PlaybookResult) : String
      JSON.build do |json|
        json.object do
          json.field "playbook", result.playbook
          json.field "mode", result.mode.label
          json.field "run", result.run
          json.field "user", result.user.label
          json.field "umask", result.umask
          json.field "hosts", result.hosts
          json.field "limit", result.limit
          json.field "env", result.env.empty? ? nil : result.env
          write_meta_fields(json, result)
          json.field "error", result.error
          json.field "divergent", result.divergent?
          json.field "masked_identical", result.masked_identical?
          json.field "raw_identical", result.raw_identical?
          json.field "recap_divergent", result.recap_divergent?
          json.field "signature", result.signature
          json.field "ansible_failed", result.ansible_failed?
          json.field "ansible_error", result.ansible_error_line
          json.field "state_divergent", result.state_divergent?
          json.field "state_signature", result.state_signature
          json.field "state_diff", result.state_diff
          json.field "check_mode_mutated", result.check_mode_mutation?
          json.field "check_mode_diff", result.check_mode_diff
          json.field "leftover_temps", result.leftover_temps_diff
          json.field "diff" do
            json.object do
              json.field "masked", result.masked_diff
              json.field "raw", result.raw_diff
            end
          end
          json.field "ansible" { engine_json(json, result.ansible) }
          json.field "krikri" { engine_json(json, result.krikri) }
        end
      end
    end

    private def write_meta_fields(json : JSON::Builder, result : PlaybookResult) : Nil
      meta = result.meta
      if meta
        json.field "module", meta.module_name
        if meta.module_names.size > 1
          json.field "modules", meta.module_names
        end
        json.field "chaos", meta.chaos
        json.field "mutations" do
          json.array do
            meta.mutations.each do |(option, kind)|
              json.object do
                json.field "option", option
                json.field "kind", kind
              end
            end
          end
        end
      else
        json.field "module", nil
        json.field "chaos", nil
        json.field "mutations", nil
      end
    end

    private def engine_json(json : JSON::Builder, engine_run : EngineRun) : Nil
      json.object do
        json.field "rc", engine_run.rc
        json.field "timed_out", engine_run.timed_out
        if recap = engine_run.recap
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
        json.field "stdout", engine_run.stdout
        json.field "stderr", engine_run.stderr
        if after = engine_run.state_after
          json.field "state_after", after.canonical
          json.field "state_digest", after.digest
        else
          json.field "state_after", nil
          json.field "state_digest", nil
        end
        changes = if before = engine_run.state_before
                    engine_run.state_after.try { |after_state| HostState.changes(before, after_state) }
                  end
        json.field "state_changes", changes
      end
    end
  end
end
