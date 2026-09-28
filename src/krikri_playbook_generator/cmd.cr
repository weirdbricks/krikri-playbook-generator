module KrikriPlaybookGenerator
  # Mirrors krikri-role-tester's Cmd wrapper: every external command goes
  # through here rather than a bare Process.run, and stdin can carry a
  # script body (used to run the constraint extractor without a tempfile).
  module Cmd
    record Result, rc : Int32, stdout : String, stderr : String

    def self.run(command : String, args : Array(String) = [] of String, input : String? = nil) : Result
      proc = Process.new(command, args: args,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Pipe)
      if input
        proc.input.print(input)
      end
      proc.input.close

      out_ch = Channel(String).new
      err_ch = Channel(String).new
      spawn { out_ch.send(proc.output.gets_to_end) }
      spawn { err_ch.send(proc.error.gets_to_end) }
      out_text = out_ch.receive
      err_text = err_ch.receive
      status = proc.wait
      Result.new(status.exit_code, out_text, err_text)
    end

    def self.success?(result : Result) : Bool
      result.rc == 0
    end
  end
end
