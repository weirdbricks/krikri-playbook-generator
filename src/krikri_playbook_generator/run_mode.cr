module KrikriPlaybookGenerator
  # The two halves a module has to get right: a dry run (`--check`) and a
  # real mutation. A playbook can be correct in one mode and wrong in the
  # other, so an isolated backend compares both by default.
  enum RunMode
    Check
    Real

    def label : String
      check? ? "check" : "real"
    end

    def self.parse(value : String) : RunMode?
      case value
      when "check" then Check
      when "real"  then Real
      end
    end

    # `check`, `real`, or `both` - a comma-separated list is accepted too.
    # Returns nil for any unknown value so the caller can name the flag.
    def self.parse_list(value : String) : Array(RunMode)?
      values = value.split(',').map(&.strip)
      return if values.empty? || !values.all? { |entry| entry.in?(%w[check real both]) }

      modes = [] of RunMode
      values.each do |entry|
        if entry == "both"
          modes << Check << Real
        else
          mode = parse(entry) || return
          modes << mode
        end
      end
      modes.uniq
    end
  end
end
