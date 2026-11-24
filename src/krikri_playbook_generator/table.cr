module KrikriPlaybookGenerator
  # Fixed-width box drawing for the human report. Every cell is single-line
  # by contract: paths, repro commands and diff excerpts are too wide to pad
  # and would defeat the alignment the table exists for, so the report
  # prints them in the numbered footer under the table instead.
  #
  # Deliberately no ANSI color: the report is piped by krikri-loop, and
  # padding computed over escape sequences lines up in a terminal but not in
  # the captured text.
  module Table
    def self.render(headers : Array(String), rows : Array(Array(String)),
                    right_align : Array(String) = [] of String) : String
      right = headers.map { |header| right_align.includes?(header) }
      widths = headers.map_with_index do |header, column|
        rows.reduce(header.size) do |width, row|
          value = row[column]? || ""
          value.size > width ? value.size : width
        end
      end

      lines = [] of String
      lines << border("┌", "┬", "┐", widths)
      lines << cells(headers, widths, Array(Bool).new(headers.size, false))
      lines << border("├", "┼", "┤", widths)
      rows.each { |row| lines << cells(row, widths, right) }
      lines << border("└", "┴", "┘", widths)
      lines.join("\n")
    end

    private def self.border(left : String, middle : String, right : String, widths : Array(Int32)) : String
      left + widths.map { |width| "─" * (width + 2) }.join(middle) + right
    end

    private def self.cells(values : Array(String), widths : Array(Int32), right : Array(Bool)) : String
      padding = widths.map_with_index do |width, column|
        value = values[column]? || ""
        right[column] ? value.rjust(width) : value.ljust(width)
      end
      "│ #{padding.join(" │ ")} │"
    end
  end
end
