module KrikriPlaybookGenerator
  # Single source of truth for progress output. The tool does long
  # provisioning (podman template builds, per-playbook runs, VM
  # provisioning) and the caller wants the same stamping the other
  # tooling in this workspace uses:
  #
  #     23:21:27 #<pid> [podman] debian template: installing packages (2 packages)
  #     23:22:16 #<pid> [podman] debian template: packages installed in 49s ...
  #
  # Timestamps and durations are on STDERR so STDOUT stays machine
  # parseable (report --json, run verdicts). `info`/`warn` never raise;
  # they are the only diagnostic channel the run/provision paths use.
  module Log
    def self.timestamp : String
      Time.utc.to_s("%H:%M:%S")
    end

    def self.info(component : String, message : String) : Nil
      STDERR.puts "#{timestamp} pid=#{Process.pid} [#{component}] #{message}"
    end

    def self.phase(component : String, label : String, &)
      started_mono = Time.instant
      started_clock = Time.utc.to_s("%H:%M:%S")
      info(component, "#{label} ...")
      result = yield
      elapsed = ((Time.instant - started_mono).total_seconds).round(1)
      info(component, "#{label} done in #{elapsed}s (started #{started_clock})")
      result
    end

    def self.warn(component : String, message : String) : Nil
      STDERR.puts "#{timestamp} pid=#{Process.pid} [#{component}] WARNING: #{message}"
    end

    def self.error(component : String, message : String) : Nil
      STDERR.puts "#{timestamp} pid=#{Process.pid} [#{component}] ERROR: #{message}"
    end
  end
end
