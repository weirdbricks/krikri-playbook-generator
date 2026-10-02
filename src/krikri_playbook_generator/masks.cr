require "digest"

module KrikriPlaybookGenerator
  # Byte-comparison support: a single, explicit MASKS list applied
  # identically to BOTH engines' raw output before diffing, plus a
  # LCS-based line diff and a stable diff signature for triage.
  module ByteDiff
    # Each mask is {regex, replacement, justification}. Applied to both
    # engines identically. Nothing else is masked - if output differs
    # beyond these, that IS the divergence being hunted.
    MASKS = [
      {
        Regex.new("^\\[WARNING\\][^\\n]*discovered Python interpreter[^\\n]*\\n?", Regex::Options::MULTILINE),
        "",
        "real ansible warns that the host uses the discovered Python interpreter; " \
        "krikri has no Python interpreter and can never emit this line",
      },
      {
        Regex.new("\"ansible_facts\": \\{\"discovered_interpreter_python\": \"[^\"]*\"\\}, "),
        "",
        "real ansible attaches the Python interpreter it discovered to a failed task's " \
        "result (ansible_facts.discovered_interpreter_python, shown in the fatal: JSON " \
        "dump); same class as the interpreter-discovery warning above - krikri has no " \
        "Python interpreter and can never emit it. Only that lone key is masked",
      },
      {
        Regex.new("(Valid booleans include: )[^\"\\n]*"),
        "\\1<BOOLEAN-SET-ORDER>",
        "convert_bool's error text lists BOOLEANS in Python set-iteration order, which " \
        "changes per process (string hash randomization) - two real ansible runs already " \
        "disagree byte-for-byte; the membership is fixed and covered by krikri's own specs",
      },
      {
        Regex.new("(value of fstype must be one of: )[^\\n]*?(, got: )"),
        "\\1<FSTYPE-SET-ORDER>\\2",
        "community.general.filesystem builds its fstype choices from a Python set of " \
        "strings (filesystem.py: `fstypes = set(FILESYSTEMS.keys()) - " \
        "set(friendly_names.values()) | set(friendly_names.keys())`, then " \
        "`choices=list(fstypes)`), so the list's order changes per process (string hash " \
        "randomization) - five consecutive real ansible-playbook runs with the same bad " \
        "fstype each printed a different order; the membership is fixed and covered by " \
        "krikri's own specs. Anchored so only the list is masked - the surrounding text " \
        "and the `got: <value>` tail must still match",
      },
      {
        Regex.new("\"delta\": \"\\d+:\\d{2}:\\d{2}(?:\\.\\d+)?\""),
        "\"delta\": \"<DELTA>\"",
        "command/shell results carry the run's duration (delta), different on every " \
        "execution by construction; the key itself must still match",
      },
      {
        Regex.new("(on )[0-9a-f]{12}('s Python)"),
        "\\1<CONTAINER-HOSTNAME>\\2",
        "missing_required_lib() embeds platform.node() - the podman container's own " \
        "random 12-hex hostname - and the two engines run in two different containers, " \
        "so the hostname can never match by construction; the rest of the message " \
        "(library name, interpreter path) must still match",
      },
      {
        Regex.new("ansible-tmp-\\d+(?:[.\\-]\\d+)*"),
        "ansible-tmp-N",
        "ansible's per-task temp directory embeds an epoch timestamp and a random " \
        "suffix; the name can never match between runs, let alone engines",
      },
      {
        Regex.new("\\.\\d+\\.\\d{4}-\\d{2}-\\d{2}@\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?~"),
        ".N.<TIMESTAMP>~",
        "copy/lineinfile backup file names embed a pid-like random number plus a " \
        "timestamp; the name differs on every run by construction (matched before " \
        "the generic timestamp mask, which would eat the date and leave the " \
        "random number behind)",
      },
      {
        Regex.new("\\d{4}-\\d{2}-\\d{2}[T@ ]\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?(?:Z|[+-]\\d{2}:?\\d{2})?"),
        "<TIMESTAMP>",
        "wall-clock timestamps (ISO-8601, ansible's log format, and lineinfile-style " \
        "backup suffixes) differ on every run by construction",
      },
      {
        Regex.new("(ansible\\.)[a-z0-9_]{8}([^'\"]*)(')"),
        "\\1<RND>\\2\\3",
        "tempfile's failure message quotes the name Python's mkstemp/mkdtemp would have " \
        "picked: the module's default `ansible.` prefix, 8 random characters ([a-z0-9_]) " \
        "and the suffix. Those 8 characters are random per run on both engines and can " \
        "never match; only that run is masked (anchored on the prefix and exactly 8 " \
        "characters, up to the closing quote)",
      },
      {
        Regex.new("(\\[Errno \\d+\\] [^:]+: '[^']*/[^'/]*)[a-z0-9_]{8}((?:\\.|[^a-z0-9_'/])[^'/]*)?'"),
        "\\1<RND>\\2'",
        "the same mkstemp name as above but with a CUSTOM prefix (`prefix:` given): the " \
        "prefix and suffix are deterministic, the 8 characters between them are random per " \
        "run on both engines. Anchored on an Errno message's single-quoted path: the last " \
        "8 [a-z0-9_] characters of the last path component, before its suffix (which " \
        "starts with a non-[a-z0-9_] character such as `.`) or the closing quote",
      },
      {
        Regex.new("\\b\\d{13,}\\b"),
        "N",
        "long digit runs are epoch-millis/nonce-class values (task IDs, temp suffixes) " \
        "that differ per run; short numbers (rcs, counters, ports) stay unmasked",
      },
    ]

    def self.mask(text : String) : String
      masked = MASKS.reduce(text) do |acc, mask|
        acc.gsub(mask[0], mask[1])
      end
      # include_role/import_role list several invalid options in Python
      # set-iteration order, which is random per real process (string hash
      # randomization), so compare the list sorted on both sides. Only the
      # order is normalized; the membership must still match.
      masked = masked.gsub(/(Invalid options for [\w.]+: )([\w,]+)/) do |_, match|
        "#{match[1]}#{match[2].split(',').sort.join(',')}"
      end
      # With several wrong-typed string options (defaults_from, handlers_from,
      # tasks_from, vars_from) real reports whichever its set iteration hits
      # first: random per process (verified: the same playbook alternates
      # between tasks_from and vars_from). The option name is masked; the
      # message text and type still have to match.
      masked.gsub(/Expected a string for (?:defaults_from|handlers_from|tasks_from|vars_from) but got/, "Expected a string for <OPT> but got")
    end

    # Minimal LCS-based line diff. Output is a list of lines prefixed
    # with "-", "+" or " " (no hunks - the results are stored whole and
    # signatures only look at the changed lines).
    def self.unified(a : String, b : String) : String
      a_lines = a.lines
      b_lines = b.lines
      return "" if a_lines == b_lines

      n = a_lines.size
      m = b_lines.size
      lcs = Array.new(n + 1) { Array(Int32).new(m + 1, 0) }
      (n - 1).downto(0) do |i|
        (m - 1).downto(0) do |j|
          lcs[i][j] = a_lines[i] == b_lines[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1])
        end
      end

      String.build do |str|
        i = 0
        j = 0
        while i < n && j < m
          if a_lines[i] == b_lines[j]
            str << " #{a_lines[i]}\n"
            i += 1
            j += 1
          elsif lcs[i + 1][j] >= lcs[i][j + 1]
            str << "-#{a_lines[i]}\n"
            i += 1
          else
            str << "+#{b_lines[j]}\n"
            j += 1
          end
        end
        a_lines[i..].each { |line| str << "-#{line}\n" }
        b_lines[j..].each { |line| str << "+#{line}\n" }
      end
    end

    # A stable root-cause signature for triage: the diff's changed lines
    # with digits, paths and quoted values generalized away, hashed. Two
    # playbooks diverging from the same bug produce the same signature
    # even when the concrete values differ.
    def self.signature(masked_diff : String) : String?
      changed = masked_diff.lines.select { |line| line.starts_with?('-') || line.starts_with?('+') }
      return if changed.empty?

      shaped = changed.map { |line| shape(line[1..]) }
      Digest::SHA256.hexdigest(shaped.join('\n'))[0, 12]
    end

    private def self.shape(line : String) : String
      line.gsub(/\/[\w.~\/$%@+-]+/, "P")
        .gsub(/\d+/, "N")
        .gsub(/'[^']*'/, "'S'")
        .gsub(/"[^"]*"/, "\"S\"")
        .strip
    end
  end
end
