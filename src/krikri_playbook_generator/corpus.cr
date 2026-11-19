require "file_utils"
require "./log"
require "./masks"

module KrikriPlaybookGenerator
  # A curated corpus of PAST divergence repros - krikri's own
  # `test/fixtures/divergence/` in the sibling checkout - replayed through
  # both engines as a release/nightly gate (`--replay-corpus DIR`).
  #
  # One directory per case:
  #
  #   <case>/playbook.yml   the repro (or a ROLE layout: tasks/main.yml,
  #                         defaults/main.yml, ... with no playbook.yml)
  #   <case>/expected.out   the exact normalized transcript real
  #                         ansible-core printed when the case was recorded
  #   <case>/NOTES.md       why the case exists (free text, carried into the
  #                         results row, never compared)
  #   <case>/flags.txt      optional: extra CLI flags, one per line (e.g.
  #                         `--check`, or `-e` followed by `name=value`)
  #   <case>/inventory.ini  optional: the case's own inventory, usually
  #                         pinning ansible_python_interpreter on a [local]
  #                         host
  #
  # A recording normalizes the directory the case ran in to `<WORK>` (see
  # `WORK`), so replay runs a COPY of the case in a fresh scratch directory
  # and substitutes that directory back before comparing - exactly what the
  # capture tool did when it wrote the recording.
  #
  # `live/cases.txt` lists the cases that need a REAL host (package,
  # service, crontab or pip mutation); replay must SKIP those loudly with a
  # "needs live host" row instead of mutating the host the gate runs on.
  #
  # This module owns discovery/parsing and the pure THREE-WAY comparison;
  # `CorpusRunner` executes the cases. The three comparisons per case are
  #
  #   (a) krikri vs real ansible          - do the engines agree, the
  #                                         question the fuzzer asks too;
  #   (b) krikri vs `expected.out`        - did a fix regress?
  #   (c) real ansible vs `expected.out`  - has the recording drifted from
  #                                         the pinned ansible-core?
  #
  # and they collapse to one status per case: the engines disagree ->
  # `regressed` (a corpus case exists because they disagreed once, so they
  # must agree now); they agree but the transcript no longer matches the
  # recording -> `drifted` (re-record it, krikri is not at fault); all three
  # agree -> `pass`. An engine that could not run at all (or a case with no
  # recording to compare against) is `failed-to-run`, never a silent pass.
  module Corpus
    class CorpusError < Exception
    end

    PLAYBOOK_FILE   = "playbook.yml"
    EXPECTED_FILE   = "expected.out"
    NOTES_FILE      = "NOTES.md"
    FLAGS_FILE      = "flags.txt"
    INVENTORY_FILE  = "inventory.ini"
    LIVE_DIR        = "live"
    LIVE_CASES_FILE = "cases.txt"
    ROLE_TASK_FILES = %w[tasks/main.yml tasks/main.yaml]
    LIVE_REASON     = "needs live host"

    # What a recording rewrites the case's scratch directory to. A replay
    # needs a fresh scratch directory (the case must never write into the
    # corpus) whose path cannot be known when the recording is made, so this
    # one path is substituted on both sides before comparing; everything
    # else has to match byte for byte.
    WORK = "<WORK>"

    # The case's RECORDED RESULT, not part of its input: never copied into
    # the scratch run and never fed back into a recording.
    RECORDED = {EXPECTED_FILE, NOTES_FILE}

    # The two backends replay supports; the disposable-VM backends
    # (Atlantic, microVM, mixed) are the named hook: each needs its own
    # per-case image/VM dispatch, and a corpus case does not carry a module
    # profile to dispatch on. Options refuses them with this text.
    BACKEND_HOOK = "corpus replay runs on the local and podman backends only " \
                   "(--run-on-atlantic/--run-on-microvm/--run-on-mixed are not wired yet)"

    # The inventory BOTH backends give the engines for a corpus case that
    # ships no `inventory.ini` of its own: a hand-written repro targets
    # `localhost` (the way the original repros did) or the generated
    # playbooks' `kpg_targets` group, and both must resolve to the one local
    # host a case runs on - including the podman backend, which otherwise
    # writes its own one-alias inventory and would make a `kpg_targets`
    # repro match no hosts.
    INVENTORY = <<-INI
      # Written by krikri-playbook-generator --replay-corpus.
      localhost ansible_connection=local

      [kpg_targets]
      localhost
      INI

    # One corpus case as it sits on disk. `problem` marks a case-shaped
    # directory that cannot be replayed (no playbook/role layout, or no
    # recorded transcript); the runner turns it into a loud
    # `failed-to-run` row instead of skipping it.
    record Case, name : String, dir : String, playbook_path : String?,
      role_layout : Bool, expected_path : String?, notes : String?,
      problem : String? = nil do
      def usable? : Bool
        problem.nil?
      end
    end

    # A case the corpus itself marks as needing a real host. `note` is any
    # trailing text on its line in live/cases.txt (why it needs one).
    record LiveCase, name : String, note : String?

    # One engine's raw run, in the shape the comparison needs. `rc -1` is
    # how Runner records an engine that never started.
    record Output, stdout : String, stderr : String, rc : Int32, timed_out : Bool = false do
      # The shell wrapper's "command not found" (an engine missing from where
      # --krikri-bin/--ansible-playbook-bin points) is a run failure, not a
      # divergence: neither engine uses 127 as a result code.
      SHELL_COMMAND_NOT_FOUND = 127

      def failed_to_run? : Bool
        timed_out || rc.negative? || rc == SHELL_COMMAND_NOT_FOUND
      end

      def failure_reason(engine : String) : String
        return "#{engine} timed out" if timed_out

        "#{engine} could not run the case (rc #{rc})"
      end
    end

    enum Status
      Pass
      Regressed
      Drifted
      FailedToRun
      Skipped

      # The `corpus_status` value in results.jsonl; Triage groups and counts
      # on exactly these strings.
      def label : String
        case self
        in Pass        then "pass"
        in Regressed   then "regressed"
        in Drifted     then "drifted"
        in FailedToRun then "failed-to-run"
        in Skipped     then "skipped"
        end
      end
    end

    # The three-way comparison for one case. The raw outputs are not kept
    # here (the runner records them in the row); what matters for triage is
    # the status plus the diff that decided it.
    record Verdict, status : Status,
      engines_identical : Bool,
      krikri_matches_expected : Bool?,
      ansible_matches_expected : Bool?,
      engine_diff : String = "",
      expected_diff : String = "",
      drift_diff : String = "",
      reason : String? = nil

    # Every case dir under `dir`, in name order. A corpus dir that is itself
    # a case (`playbook.yml` or a role layout at the root) is accepted, so a
    # single hand-picked repro can be replayed on its own. Directories that
    # are not case-shaped at all (no playbook, no role layout, no recording)
    # are ignored; `live/` is never a case.
    def self.discover(dir : String) : Array(Case)
      raise CorpusError.new("corpus directory #{dir.inspect} does not exist") unless Dir.exists?(dir)

      root = case_at(dir, File.basename(dir))
      return [root] if root

      Dir.children(dir).sort.compact_map do |entry|
        next if entry.starts_with?(".") || entry == LIVE_DIR

        path = File.join(dir, entry)
        next unless Dir.exists?(path)

        case_at(path, entry)
      end
    end

    # The cases live/cases.txt lists, in file order. Blank lines and `#`
    # comments are ignored; the first token is the case name and the rest of
    # the line (if any, `#`-prefixed or bare) is kept as the note explaining
    # why it needs a real host.
    def self.live_cases(dir : String) : Array(LiveCase)
      path = File.join(dir, LIVE_DIR, LIVE_CASES_FILE)
      return [] of LiveCase unless File.exists?(path)

      collected = [] of LiveCase
      File.each_line(path) do |line|
        body = line.strip
        next if body.empty? || body.starts_with?('#')

        name = body.split(/\s+/, 2)[0]
        note = body[name.size..].strip.sub(/\A#+\s*/, "")
        collected << LiveCase.new(name, note.empty? ? nil : note)
      end
      collected
    end

    # The case's optional `flags.txt`: extra CLI flags, one per line, so
    # `--check` or `-e` followed by `name=value` stays readable. Blank lines
    # and surrounding whitespace are ignored, and the flags are handed to
    # BOTH engines exactly as ansible's own corpus does.
    def self.flags(case_dir : String) : Array(String)
      path = File.join(case_dir, FLAGS_FILE)
      return [] of String unless File.exists?(path)

      File.read_lines(path).map(&.strip).reject(&.empty?)
    end

    # The inventory the case runs under: its own `inventory.ini` when it has
    # one (the cases that execute modules pin ansible_python_interpreter on a
    # [local] host), else the corpus fallback every backend can run.
    def self.inventory(case_dir : String) : String
      path = File.join(case_dir, INVENTORY_FILE)
      File.exists?(path) ? File.read(path) : INVENTORY
    end

    # The text one side is compared on: the case's scratch directory
    # rewritten to `<WORK>` (so a replay in a fresh directory can match the
    # recording), the explicit MASKS applied (a recording is normalized when
    # it is made, so masking again is idempotent), CRLF folded to LF and
    # trailing newlines dropped - how many final newlines a transcript ends
    # with is not behavior.
    def self.normalize(text : String, work_dir : String = "") : String
      ByteDiff.mask(substitute_work(text, work_dir).gsub(/\n+\z/, ""))
    end

    # Rewrite `work_dir` (and everything under it) to `<WORK>`, folding CRLF
    # to LF. Separate from `normalize` so an engine's two streams can be
    # substituted and THEN concatenated: `normalize` drops trailing newlines,
    # which is right for a whole transcript but would glue stdout's last line
    # to stderr's first. Only a WHOLE path is rewritten: a lookalike sibling
    # like `<work_dir>-2` is a different directory and keeps its own spelling,
    # or an over-broad replacement could force two transcripts equal. A real
    # use is followed by `/` (a child path) or by a non-name character (space,
    # quote, end of string).
    def self.substitute_work(text : String, work_dir : String) : String
      folded = text.gsub("\r\n", "\n")
      return folded if work_dir.empty?

      folded.gsub(Regex.new("#{Regex.escape(work_dir)}(?![A-Za-z0-9._-])"), WORK)
    end

    # Whether the two engines agree byte for byte after normalization: the
    # same comparison the fuzz runner's `masked_identical` makes, exit status
    # included.
    def self.same_transcript?(a : Output, b : Output, work_dir : String = "") : Bool
      a.rc == b.rc && a.timed_out == b.timed_out &&
        normalize(a.stdout, work_dir) == normalize(b.stdout, work_dir) &&
        normalize(a.stderr, work_dir) == normalize(b.stderr, work_dir)
    end

    # Whether an engine's run reproduces the recorded transcript. A
    # recording is either `ansible-playbook ... > expected.out 2>&1` or, when
    # the engine printed nothing on stderr, stdout alone; both layouts are
    # accepted and anything else must match the combined stream. (True
    # interleaving of the two streams is not recoverable from a plain file,
    # so a recording that mixes task output and warnings is compared on
    # stdout-then-stderr.) The engine side is normalized against `work_dir`
    # (the directory it ran in) so its real paths match the `<WORK>` the
    # recording carries.
    def self.matches_expected?(output : Output, expected : String, work_dir : String = "") : Bool
      record = normalize(expected)
      return true if normalize(output.stdout, work_dir) == record

      normalize(output.stdout + output.stderr, work_dir) == record
    end

    # The three-way comparison. Pure: no I/O, no engine, so the whole
    # classification matrix is spec-able from strings. `work_dir` is where
    # the engines ran (rewritten to `<WORK>`; empty when the caller already
    # normalized its transcripts).
    def self.classify(ansible : Output, krikri : Output, expected : String?,
                      work_dir : String = "") : Verdict
      engine_diff = diff_outputs(ansible, krikri, work_dir)
      # An engine that never started produced no transcript at all: calling
      # that a divergence would report the harness as a krikri bug.
      return failed(ansible.failure_reason("ansible"), engine_diff) if ansible.failed_to_run?
      return failed(krikri.failure_reason("krikri"), engine_diff) if krikri.failed_to_run?
      return failed("no #{EXPECTED_FILE} recorded transcript", engine_diff) unless expected

      engines_identical = same_transcript?(ansible, krikri, work_dir)
      krikri_matches = matches_expected?(krikri, expected, work_dir)
      ansible_matches = matches_expected?(ansible, expected, work_dir)
      status = if !engines_identical
                 Status::Regressed
               elsif !krikri_matches
                 Status::Drifted
               else
                 Status::Pass
               end
      Verdict.new(status, engines_identical, krikri_matches, ansible_matches, engine_diff,
        diff_recording(expected, krikri, work_dir), diff_recording(expected, ansible, work_dir))
    end

    # The path both engines run for this case, at one absolute path they
    # share. The case's INPUT is copied into `stage_dir` first (never run in
    # place: a replay must not write into the corpus, and the recording was
    # made from a scratch copy whose path is what `<WORK>` stands for). A
    # flat case then runs `<stage_dir>/playbook.yml`, with its sibling
    # files/, templates/ and roles/ beside it. A role layout is not a
    # playbook at all, so replay builds the entry playbook around a copy of
    # the role (`roles/<case>`) inside `stage_dir`: the same shape every run,
    # never a hand-written wrapper.
    def self.build_playbook(kase : Case, stage_dir : String) : String
      unless kase.role_layout
        copy_input(kase, stage_dir)
        return File.join(stage_dir, PLAYBOOK_FILE)
      end

      role_name = role_name_for(kase.name)
      FileUtils.mkdir_p(File.join(stage_dir, "roles"))
      copy_input(kase, File.join(stage_dir, "roles", role_name))
      playbook = File.join(stage_dir, "#{role_name}.yml")
      File.write(playbook, entry_playbook(kase.name, role_name))
      playbook
    end

    # Copy the case's INPUT (everything except its recorded result) into
    # `dest`, the way the capture tool built the directory the recording was
    # taken in.
    private def self.copy_input(kase : Case, dest : String) : Nil
      FileUtils.mkdir_p(dest)
      Dir.children(kase.dir).each do |entry|
        next if RECORDED.includes?(entry)

        FileUtils.cp_r(File.join(kase.dir, entry), File.join(dest, entry))
      end
    end

    # Every top-level entry of the staged case the podman backend has to put
    # beside the playbook. A case tree travels WHOLE - role layout, `files/`,
    # `templates/`, plugin dirs, and a plain file a repro reads (the
    # `stable.txt` a slurp case ships beside its playbook) - so a replay
    # resolves exactly what it did when it was recorded. The playbook itself
    # is copied separately.
    def self.case_entries(playbook : String) : Array(String)
      base = File.dirname(playbook)
      Dir.children(base).sort.compact_map do |entry|
        path = File.join(base, entry)
        path == playbook ? nil : path
      end
    end

    # A role name the synthesized play can reference: ansible role names are
    # [A-Za-z0-9_], so every other character of the case name becomes `_`.
    def self.role_name_for(case_name : String) : String
      case_name.gsub(/[^A-Za-z0-9_]/, "_")
    end

    # The synthesized play for a role-layout case: one play on the corpus
    # inventory's host group, no fact gathering (the recording's transcript
    # is task output; implicit gathering prints nothing but would make the
    # role's fact use a corpus accident rather than a replay decision).
    def self.entry_playbook(case_name : String, role_name : String) : String
      <<-YAML
        ---
        # Built by krikri-playbook-generator --replay-corpus for the role-layout
        # case #{case_name.inspect}: the case directory is a role, not a playbook.
        - name: Replay #{case_name}
          hosts: kpg_targets
          gather_facts: false
          roles:
            - #{role_name}
        YAML
    end

    private def self.failed(reason : String, engine_diff : String) : Verdict
      Verdict.new(Status::FailedToRun, engine_diff.empty?, nil, nil, engine_diff, "", "", reason)
    end

    # One stream's section of Runner's masked-diff shape (`stdout:` /
    # `stderr:` headers, LCS line diff), so a corpus finding's signature is
    # computed and read exactly like a fuzz finding's.
    private def self.stream_diff(label : String, a : String, b : String,
                                 work_dir : String = "") : String
      "#{label}:\n" + ByteDiff.unified(normalize(a, work_dir), normalize(b, work_dir))
    end

    # The engine-vs-engine diff. The rc lines are added only when the exit
    # codes disagree: an engine pair that prints the same transcript but
    # exits differently is still a divergence, and a diff with no changed
    # lines would leave the finding without a signature to group on.
    private def self.diff_outputs(a : Output, b : Output, work_dir : String = "") : String
      return "" if same_transcript?(a, b, work_dir)

      String.build do |str|
        str << stream_diff("stdout", a.stdout, b.stdout, work_dir)
        str << stream_diff("stderr", a.stderr, b.stderr, work_dir)
        unless a.rc == b.rc && a.timed_out == b.timed_out
          str << "rc:\n" << "-#{rc_label(a)}\n" << "+#{rc_label(b)}\n"
        end
      end
    end

    # A recorded transcript against one engine's run: the recording is a
    # single stream, so the engine side is its stdout-then-stderr.
    private def self.diff_recording(expected : String, output : Output,
                                    work_dir : String = "") : String
      stream_diff("stdout", expected, output.stdout + output.stderr, work_dir) + "stderr:\n"
    end

    private def self.rc_label(output : Output) : String
      output.timed_out ? "timeout" : output.rc.to_s
    end

    private def self.role_layout?(path : String) : Bool
      ROLE_TASK_FILES.any? { |entry| File.exists?(File.join(path, entry)) }
    end

    # nil for a directory that is not case-shaped (`docs/`, a shared helper
    # tree): those are not cases, and the gate must not invent one for them.
    private def self.case_at(path : String, name : String) : Case?
      playbook_path = File.join(path, PLAYBOOK_FILE)
      has_playbook = File.exists?(playbook_path)
      role = role_layout?(path)
      expected_path = File.join(path, EXPECTED_FILE)
      has_expected = File.exists?(expected_path)
      return unless has_playbook || role || has_expected

      problem = if !has_playbook && !role
                  "no #{PLAYBOOK_FILE} and no role layout (#{ROLE_TASK_FILES.first})"
                elsif !has_expected
                  "no #{EXPECTED_FILE} recorded transcript"
                end
      Case.new(name, path, has_playbook ? playbook_path : nil, role,
        has_expected ? expected_path : nil, read_notes(path), problem)
    end

    private def self.read_notes(path : String) : String?
      notes = File.join(path, NOTES_FILE)
      return unless File.exists?(notes)

      text = File.read(notes).strip
      text.empty? ? nil : text
    rescue File::Error
      nil
    end
  end
end
