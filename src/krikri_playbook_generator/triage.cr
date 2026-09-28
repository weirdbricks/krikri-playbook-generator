module KrikriPlaybookGenerator
  # Groups divergences by module + chaos-kind + constraint violated,
  # deduping to root cause the same way krikri's own fix-divergence
  # workflow does.
  class Triage
    def initialize(@results_dir : String)
    end

    def report
      raise "not yet implemented: Triage#report"
    end
  end
end
