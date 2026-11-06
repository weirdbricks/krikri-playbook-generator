module KrikriPlaybookGenerator
  # Single source of truth for progress output. The tool does long
  # provisioning (podman template builds, per-playbook runs, VM
  # provisioning) and the caller wants the same stamping the other
  # tooling in this workspace uses:
  #
  #     23:21:27 [podman] debian template: installing packages (2 packages)
  #     23:22:16 [podman] debian template: packages installed in 49s ...
  #
  # Timestamps and durations are on STDERR so STDOUT stays machine
  # parseable (report --json, run verdicts). `info`/`warn` never raise;
  # they are the only diagnostic channel the run/provision paths use.
  module Log
    RESET  = "\e[0m"
    DIM    = "\e[2m"
    GREEN  = "\e[32m"
    YELLOW = "\e[33m"
    RED    = "\e[31m"
    CYAN   = "\e[36m"

    # TTY-only color: piped/captured output stays plain and parseable.
    def self.color? : Bool
      STDERR.tty?
    end

    def self.paint(code : String, text : String) : String
      return text unless color?
      "#{code}#{text}#{RESET}"
    end

    def self.timestamp : String
      # Local (system) time, like krikri-loop's own stamps - a 07:11 UTC
      # line on a 02:11 wall clock reads as five hours in the future.
      Time.local.to_s("%H:%M:%S")
    end

    def self.info(component : String, message : String) : Nil
      STDERR.puts "#{paint(DIM, timestamp)} #{paint(CYAN, "[#{component}]")} #{message}"
    end

    def self.phase(component : String, label : String, &)
      started_mono = Time.instant
      started_clock = Time.utc.to_s("%H:%M:%S")
      info(component, "#{label} ...")
      result = yield
      elapsed = ((Time.instant - started_mono).total_seconds).round(1)
      info(component, "#{paint(GREEN, "✓")} #{label} done in #{elapsed}s (started #{started_clock})")
      result
    end

    def self.warn(component : String, message : String) : Nil
      STDERR.puts "#{paint(DIM, timestamp)} #{paint(CYAN, "[#{component}]")} #{paint(YELLOW, "WARNING")} #{message}"
    end

    def self.error(component : String, message : String) : Nil
      STDERR.puts "#{paint(DIM, timestamp)} #{paint(CYAN, "[#{component}]")} #{paint(RED, "ERROR")} #{message}"
    end
  end
end
