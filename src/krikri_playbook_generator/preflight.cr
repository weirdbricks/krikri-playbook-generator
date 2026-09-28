module KrikriPlaybookGenerator
  class PreflightError < Exception
  end

  # Confirms both engines this tool diffs against are actually present
  # before doing any work — schema scraping needs a real ansible-core
  # install, and `run`/`report` are pointless without krikri-playbook too.
  # Mirrors krikri-role-tester's `--krikri-bin` convention (a path, since
  # krikri-playbook is never installed system-wide) alongside plain PATH
  # lookup for ansible-playbook.
  module Preflight
    def self.check!(ansible_playbook_bin : String, krikri_bin : String)
      missing = [] of String

      missing << "ansible-playbook (#{ansible_playbook_bin.inspect}, expected on PATH)" unless Process.find_executable(ansible_playbook_bin)
      missing << "krikri-playbook (#{krikri_bin.inspect}, pass --krikri-bin if it lives elsewhere)" unless executable_file?(krikri_bin)

      return if missing.empty?

      raise PreflightError.new("missing required engine(s):\n  - #{missing.join("\n  - ")}")
    end

    private def self.executable_file?(path : String) : Bool
      return true if Process.find_executable(path)
      File.exists?(path) && File.info(path).permissions.owner_execute?
    end
  end
end
