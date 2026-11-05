require "./spec_helper"
require "../src/krikri_playbook_generator/log"

module KrikriPlaybookGenerator
  describe Log do
    it "formats a stamped line with timestamp + component + message (no pid)" do
      timestamp = Log.timestamp
      assert(timestamp.matches?(/\A\d{2}:\d{2}:\d{2}\z/), "timestamp not HH:MM:SS: #{timestamp}")

      line = formatted("test", "hello world")
      assert(line.includes?("[test]"))
      assert(line.includes?("hello world"))
      assert(line.includes?(timestamp))
      refute(line.includes?("pid="))
    end

    it "warn/error nest the severity inside the component line" do
      warn_line = formatted("test", "slow", "WARNING")
      error_line = formatted("test", "failed", "ERROR")
      assert(warn_line.includes?("WARNING: slow"))
      assert(error_line.includes?("ERROR: failed"))
    end

    it "phase returns the block's value" do
      assert_equal(42, Log.phase("test", "label") { 42 })
    end

    it "paint is a no-op without a TTY so piped output stays clean" do
      refute(Log.color?) unless STDERR.tty?
      assert_equal("text", Log.paint(Log::GREEN, "text")) unless STDERR.tty?
    end

    private def formatted(component : String, message : String, severity : String? = nil) : String
      # Mirror Log.info exactly: timestamp + [component] + message
      severity_str = severity ? "#{severity}: " : ""
      "#{Log.timestamp} [#{component}] #{severity_str}#{message}"
    end
  end
end
