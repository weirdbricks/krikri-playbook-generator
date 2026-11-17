module KrikriPlaybookGenerator
  # Which identity the engines run as. Local means "the account invoking
  # this tool" (the shared live host cannot be switched); Root and Nonroot
  # are the accounts the isolated backends provision: containers run the
  # engine process under the selected user, so permission and umask bugs
  # that root hides become visible.
  enum UserProfile
    Local
    Root
    Nonroot

    def label : String
      case self
      in Local   then "local"
      in Root    then "root"
      in Nonroot then "nonroot"
      end
    end

    def self.parse(value : String) : UserProfile?
      case value
      when "root"    then Root
      when "nonroot" then Nonroot
      end
    end

    # `root`, `nonroot`, or `both` - a comma-separated list is accepted
    # too. nil for any unknown value so the caller can name the flag.
    def self.parse_list(value : String) : Array(UserProfile)?
      values = value.split(',').map(&.strip)
      return if values.empty? || !values.all? { |entry| entry.in?(%w[root nonroot both]) }

      profiles = [] of UserProfile
      values.each do |entry|
        if entry == "both"
          profiles << Root << Nonroot
        else
          profile = parse(entry) || return
          profiles << profile
        end
      end
      profiles.uniq
    end
  end

  # 022 is the common production default (and what the images happened to
  # have); 002 and 077 are the other axis points `--umask` documents.
  DEFAULT_UMASK = "022"

  # Accepts 002, 022, 077 and the 2/22/77 shorthand; returns the normalized
  # three-digit octal form, nil for anything that is not an octal mode.
  def self.normalize_umask(value : String) : String?
    return unless value.matches?(/\A[0-7]{1,3}\z/)

    value.rjust(3, '0')
  end
end
