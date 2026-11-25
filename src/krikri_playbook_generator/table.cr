require "./color"
require "tablo"

module KrikriPlaybookGenerator
  # Fixed-width box drawing for the human report, green like the other krikri
  # tools' tables. Every cell is single-line by contract: paths, repro
  # commands and diff excerpts are too wide to pad and would defeat the
  # alignment the table exists for, so the report prints them in the
  # numbered footer under the table instead.
  module Table
    def self.render(headers : Array(String), rows : Array(Array(String)),
                    right_align : Array(String) = [] of String) : String
      styler = ->(cell : String) { Color.paint(cell, Color::GREEN, STDOUT) }
      # Tablo drops every styler unless its own stdout is a terminal, which a
      # loop-piped report is not: its width math already runs on the unstyled
      # cells, so color is safe to keep whenever Color.enabled? says so.
      allow_stylers = Tablo::Config.styler_tty_only?
      Tablo::Config.styler_tty_only = false if Color.enabled?(STDOUT)
      begin
        Tablo::Table.new(rows, border: Tablo::Border.new(Tablo::Border::PreSet::Modern)) do |table|
          headers.each_with_index do |header, col|
            width = ([header] + rows.map { |row| row[col]? || "" }).max_of(&.size)
            align = right_align.includes?(header) ? Tablo::Justify::Right : Tablo::Justify::Left
            table.add_column(header, width: width, body_alignment: align,
              body_styler: styler, header_styler: styler) { |row| row[col]? || "" }
          end
        end.to_s
      ensure
        Tablo::Config.styler_tty_only = allow_stylers
      end
    end
  end
end
