module KrikriPlaybookGenerator
  # Mirrors krikri-role-tester's Cmd wrapper: every external command goes
  # through here rather than a bare Process.run, and stdin can carry a
  # script body (used to run the constraint extractor without a tempfile).
  # An optional timeout kills the child with SIGKILL and reports rc 124
  # (the GNU timeout convention) so a hang is its own result instead of
  # wedging the whole batch.
  module Cmd
    TIMEOUT_RC = 124

    record Result, rc : Int32, stdout : String, stderr : String, timed_out : Bool = false

    def self.run(command : String, args : Array(String) = [] of String, input : String? = nil,
                 timeout : Float64? = nil) : Result
      proc = Process.new(command, args: args,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe)
      if input
        proc.input.print(input)
      end
      proc.input.close

      reaped = false
      timed_out = false
      if timeout
        spawn do
          sleep timeout.seconds
          unless reaped
            timed_out = true
            begin
              proc.signal(Signal::KILL)
            rescue
              # the child already exited between the flag check and the
              # signal - nothing left to kill, which is fine.
            end
          end
        end
      end

      out_ch = Channel(String).new
      err_ch = Channel(String).new
      spawn { out_ch.send(proc.output.gets_to_end) }
      spawn { err_ch.send(proc.error.gets_to_end) }
      out_text = out_ch.receive
      err_text = err_ch.receive
      status = proc.wait
      reaped = true
      Result.new(timed_out ? TIMEOUT_RC : status.exit_code, out_text, err_text, timed_out)
    end

    def self.success?(result : Result) : Bool
      result.rc == 0
    end
  end
end
