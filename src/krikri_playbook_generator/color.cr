module KrikriPlaybookGenerator
  # ANSI colors for the human report: only when the target is a terminal, and
  # never when NO_COLOR is set (https://no-color.org). krikri-loop pipes this
  # process but sets KRIKRI_FORCE_COLOR when its own stdout is a terminal, so
  # color still reaches the user's terminal through the pipe.
  module Color
    GREEN = 32

    def self.enabled?(io : IO) : Bool
      return false unless ENV["NO_COLOR"]?.to_s.empty?
      io.tty? || (ENV["KRIKRI_FORCE_COLOR"]? == "1" && io.same?(STDOUT))
    end

    def self.paint(text : String, code : Int32, io : IO) : String
      enabled?(io) ? "\e[#{code}m#{text}\e[0m" : text
    end
  end
end
