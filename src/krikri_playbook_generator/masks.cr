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
        Regex.new("\\b\\d{13,}\\b"),
        "N",
        "long digit runs are epoch-millis/nonce-class values (task IDs, temp suffixes) " \
        "that differ per run; short numbers (rcs, counters, ports) stay unmasked",
      },
    ]

    def self.mask(text : String) : String
      MASKS.reduce(text) do |acc, mask|
        acc.gsub(mask[0], mask[1])
      end
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
