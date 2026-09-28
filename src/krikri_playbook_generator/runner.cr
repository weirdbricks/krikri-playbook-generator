module KrikriPlaybookGenerator
  # Thin wrapper delegating to krikri-role-tester's dual-engine execution
  # and diffing (cold+warm, SUMMARY| normalization, PLAY RECAP diffing) —
  # reused rather than reimplemented. See ../../krikri-role-tester.
  class Runner
    def initialize(@playbook_paths : Array(String), @results_dir : String,
                   @atlantic_hosts : Int32 = 22)
    end

    def run
      raise "not yet implemented: Runner#run"
    end
  end
end
