require "./spec_helper"
require "../src/krikri_playbook_generator/log"

module KrikriPlaybookGenerator
  describe Log do
    it "formats a stamped line with pid + component + message" do
      timestamp = Log.timestamp
      assert(timestamp.matches?(/\A\d{2}:\d{2}:\d{2}\z/), "timestamp not HH:MM:SS: #{timestamp}")

      line = formatted("test", "hello world")
      assert(line.includes?("pid=#{Process.pid}"))
      assert(line.includes?("[test]"))
      assert(line.includes?("hello world"))
      assert(line.includes?(timestamp))
    end

    it "warn/error nest the severity inside the bracketed component line" do
      warn_line = formatted("test", "slow", "WARNING")
      error_line = formatted("test", "failed", "ERROR")
      assert(warn_line.includes?("WARNING: slow"))
      assert(error_line.includes?("ERROR: failed"))
    end

    it "phase returns the block's value" do
      assert_equal(42, Log.phase("test", "label") { 42 })
    end

    private def formatted(component : String, message : String, severity : String? = nil) : String
      parts = ["pid=#{Process.pid}", "[#{component}]"]
      message = "#{severity}: #{message}" if severity
      # Mirror Log.info exactly: timestamp + pid + [component] + message
      "#{Log.timestamp} #{parts.join(" ")} #{message}"
    end
  end
end
