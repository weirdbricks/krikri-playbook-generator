require "./generator"

module KrikriPlaybookGenerator
  # Assembles generated tasks into playbook YAML, one task per module per
  # play, following the shape of krikri's own testing/test-*.yml fixtures.
  class PlaybookBuilder
    def initialize(@out_dir : String)
    end

    def build(tasks : Array(GeneratedTask)) : Array(String)
      raise "not yet implemented: PlaybookBuilder#build"
    end
  end
end
