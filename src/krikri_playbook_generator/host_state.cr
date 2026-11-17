require "digest"
require "./cmd"
require "./masks"

module KrikriPlaybookGenerator
  # The host-state half of the oracle: what each engine actually left on its
  # host, not just what it printed. A task can report success and still
  # write a different file mode, leave a temp file behind, install a
  # package or start a service; stdout alone cannot see that.
  #
  # Only the DELTA between two snapshots of the same host is compared.
  # The two engine hosts start from different images (the real container
  # carries ansible and its pip cache, the krikri one does not), so their
  # absolute state can never be equal - comparing it would report the
  # images' own difference as a finding.
  module HostState
    SECTIONS = %w[boot files hashes packages units ports]
    ROOTS    = %w[/etc /tmp/kpg-work /var/spool/cron /root]

    # Files every host (container or VM) regenerates for itself: hostname,
    # resolver, machine id. The two engines' hosts are distinct machines, so
    # these can never agree; snapshotting them would make every playbook
    # look state-divergent. `/root/.ansible` is the engine's own
    # control-side state (its collections, its tmp staging root): real
    # ansible creates the tmp root lazily and every --diff run leaves it
    # behind, while krikri stages elsewhere, so it says nothing about what
    # the module did.
    # A module that edits one of these is invisible to this oracle - the
    # deliberate, documented gap (same discipline as ByteDiff::MASKS).
    EXCLUDED_PATHS = %w[/etc/hostname /etc/hosts /etc/resolv.conf /etc/machine-id
      /root/.ansible]

    EXCLUDE_PREDICATE = EXCLUDED_PATHS.map { |path| "-path #{path}" }.join(" -o ")

    # Runs on the host after (and before) an engine run. Every line is
    # deterministic so two snapshots of the same untouched host are
    # byte-identical: GNU find's -printf, LC_ALL=C sorts, no timestamps.
    # Quoted heredoc: the shell sees these backslashes and ${...} verbatim.
    # KPG_ROOTS/EXCLUDE_PREDICATE are substituted into SNAPSHOT_SCRIPT below.
    SNAPSHOT_TEMPLATE = <<-'SH'
      printf '#boot\n'
      cat /proc/sys/kernel/random/boot_id 2>/dev/null
      printf '#files\n'
      for root in KPG_ROOTS; do
        [ -e "$root" ] || continue
        find "$root" -xdev \( EXCLUDE_PREDICATE \) -prune -o \
          -printf '%y\t%U\t%G\t%m\t%s\t%p\n' 2>/dev/null
      done | LC_ALL=C sort
      printf '#hashes\n'
      for root in KPG_ROOTS; do
        [ -e "$root" ] || continue
        find "$root" -xdev \( EXCLUDE_PREDICATE \) -prune -o \
          -type f -size -1048576c -exec sha256sum {} + 2>/dev/null
      done | LC_ALL=C sort
      printf '#packages\n'
      { dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null ||
        rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null; } | LC_ALL=C sort
      printf '#units\n'
      systemctl list-unit-files --state=enabled --no-legend --no-pager 2>/dev/null |
        awk '{print $1}' | LC_ALL=C sort
      printf '#ports\n'
      awk 'NR>1 && ($4=="0A" || $4=="07") {print FILENAME"\t"$2}' \
        /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null | LC_ALL=C sort -u
      SH

    SNAPSHOT_SCRIPT = SNAPSHOT_TEMPLATE
      .gsub("KPG_ROOTS", ROOTS.join(" "))
      .gsub("EXCLUDE_PREDICATE", EXCLUDE_PREDICATE)

    # One engine run's command result plus the state around it; nil before
    # or after means the snapshot could not be taken (the playbook is still
    # compared on stdout/stderr, just without the state oracle).
    record Observation, result : Cmd::Result, before : Snapshot? = nil, after : Snapshot? = nil

    # One comparison pass: each engine's run on its own isolated host (or
    # the same pair again, for the second-run idempotency pass).
    alias Comparison = NamedTuple(ansible: Observation, krikri: Observation)

    class Snapshot
      getter sections : Hash(String, Array(String))

      def initialize(@sections : Hash(String, Array(String)))
      end

      # A run killed mid-write can truncate a section; every section that
      # did arrive is still usable, so a partial snapshot parses.
      def self.parse(text : String) : Snapshot?
        sections = {} of String => Array(String)
        current : String? = nil
        text.each_line do |raw|
          line = raw.strip
          if name = HostState.section_name(line)
            current = name
            sections[name] ||= [] of String
          elsif name = current
            sections[name] << line unless line.empty?
          end
        end
        return if sections.empty?

        Snapshot.new(sections)
      end

      def [](name : String) : Array(String)
        @sections[name]? || [] of String
      end

      # Deterministic text form: fixed section order, sorted lines. This is
      # what gets stored as `state_after` and what a snapshot's digest
      # hashes.
      def canonical : String
        String.build do |str|
          HostState::SECTIONS.each do |name|
            str << '#' << name << '\n'
            self[name].sort.each { |line| str << line << '\n' }
          end
        end
      end

      def digest : String
        Digest::SHA256.hexdigest(canonical)[0, 16]
      end
    end

    # Visible for the specs: the section a `#name` line opens, if any.
    def self.section_name(line : String) : String?
      return unless line.starts_with?('#')

      name = line[1..]
      name if SECTIONS.includes?(name)
    end

    # Whether an engine run completed without failing. `ignore_errors`
    # keeps rc at 0 and turns a failure into a fatal line plus an ignored
    # counter, so all three signals matter.
    def self.succeeded?(observation : Observation) : Bool
      result = observation.result
      return false unless result.rc.zero? && !result.timed_out

      result.stdout.includes?("fatal:") || result.stderr.includes?("fatal:") ? false : true
    end

    # What one engine changed between the two snapshots, one canonical line
    # per change (sorted). Two engines' change lists are then diffed like
    # output, so an identical mutation is not a finding.
    def self.changes(before : Snapshot, after : Snapshot) : Array(String)
      lines = [] of String
      lines << "boot\trebooted" if before["boot"] != after["boot"]
      compare(before["files"], after["files"], "file", lines, ->(line : String) { file_path(line) })
      compare(before["hashes"], after["hashes"], "hash", lines, ->(line : String) { hash_path(line) })
      compare(before["packages"], after["packages"], "package", lines, ->(line : String) { line.split('\t', 2).first })
      compare(before["units"], after["units"], "unit", lines, ->(line : String) { line })
      compare(before["ports"], after["ports"], "port", lines, ->(line : String) { line })
      lines.sort!
    end

    # A per-kind change list: added/removed/changed entries keyed by path,
    # package name or the line itself.
    private def self.compare(before : Array(String), after : Array(String), kind : String,
                             lines : Array(String), key : Proc(String, String)) : Nil
      old = build_map(before, key)
      new = build_map(after, key)
      (old.keys | new.keys).each do |entry|
        old_line = old[entry]?
        new_line = new[entry]?
        if old_line.nil? && (line = new_line)
          lines << "#{kind}\tadded\t#{line}"
        elsif (line = old_line) && new_line.nil?
          lines << "#{kind}\tremoved\t#{line}"
        elsif (from = old_line) && (to = new_line) && from != to
          lines << "#{kind}\tchanged\t#{from}\t#{to}"
        end
      end
    end

    private def self.build_map(lines : Array(String), key : Proc(String, String)) : Hash(String, String)
      map = {} of String => String
      lines.each { |line| map[key.call(line)] = line }
      map
    end

    # `type uid gid mode size path`
    def self.file_path(line : String) : String
      line.split('\t', 6).last
    end

    # `sha256<two spaces>path`
    def self.hash_path(line : String) : String
      line.split("  ", 2).last
    end

    # Unified diff of the two engines' change lists ("" when identical).
    def self.diff(ansible_changes : Array(String), krikri_changes : Array(String)) : String
      ByteDiff.unified(change_text(ansible_changes), change_text(krikri_changes))
    end

    def self.change_text(changes : Array(String)) : String
      changes.empty? ? "" : changes.join('\n') + "\n"
    end

    # Prefixed so a state signature can never collide with an
    # stdout/stderr one in triage's grouping.
    def self.signature(diff : String) : String?
      ByteDiff.signature(diff).try { |signature| "state:#{signature}" }
    end
  end
end
