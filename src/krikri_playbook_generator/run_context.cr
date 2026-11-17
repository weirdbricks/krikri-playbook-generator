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

  # The inventory a host-count row uses. Every isolated backend runs the
  # engines inside ONE container/VM, so N "hosts" are N local aliases of the
  # same machine: enough for per-host task execution, the recap's host list
  # and `included:` grouping to be compared without a second machine (that
  # is what the SSH profile would add). The first alias keeps the
  # historical `target` name, so a one-host row's output is unchanged.
  #
  # Every play targets the `kpg_targets` group, never `all`, so the
  # delegate-only aliases below can exist in the inventory without also
  # becoming play hosts: a delegated task needs its delegate to resolve,
  # even on a one-host row.
  module HostInventory
    MAX_HOSTS = 3
    GROUP     = "kpg_targets"
    # A host that can never be reached: loopback with a closed port, so a
    # connection attempt is refused immediately instead of hanging. It is
    # added to the play group only for a --limit row, which is the axis
    # whose whole point is that ansible must NOT contact out-of-limit
    # hosts (including during implicit fact gathering).
    UNREACHABLE_HOST  = "kpg_unreachable"
    UNREACHABLE_ENTRY = "#{UNREACHABLE_HOST} ansible_connection=ssh ansible_host=127.0.0.1 " \
                        "ansible_port=1 ansible_user=root"

    def self.aliases(count : Int32) : Array(String)
      (1..count).map { |index| index == 1 ? "target" : "target#{index}" }
    end

    def self.render(count : Int32, include_unreachable : Bool = false) : String
      targets = aliases(count)
      leftovers = aliases(MAX_HOSTS) - targets
      String.build do |io|
        leftovers.each { |name| io << "#{name} ansible_connection=local\n" }
        io << "\n[#{GROUP}]\n"
        targets.each { |name| io << "#{name} ansible_connection=local\n" }
        io << "#{UNREACHABLE_ENTRY}\n" if include_unreachable
      end
    end
  end

  # The engine environment every backend invokes: gathering and its fact
  # cache are stripped (an inherited ANSIBLE_GATHERING=smart plus a
  # populated cache silently skips implicit fact gathering on the real
  # engine, which would make the gathering axis compare "ansible did not
  # run it" against an engine that has no cache), and ANSIBLE_NOCOLOR
  # keeps the compared bytes free of terminal styling. Local runs use this
  # too, not just the isolated ones: an inherited cache is exactly the kind
  # of environment leak this tool must not turn into a finding.
  ENGINE_ENV_STRIP = "env -u ANSIBLE_GATHERING -u ANSIBLE_CACHE_PLUGIN -u ANSIBLE_CACHE_PLUGIN_CONNECTION ANSIBLE_NOCOLOR=1"

  # Shell assignments for a row's engine environment, empty when the
  # playbook's keyword is a play key instead of an env variant. Values come
  # from the overrides/play-keyword data, never from user input, but they
  # are quoted anyway so one bad entry cannot change the command shape.
  def self.env_prefix(env : Hash(String, String)) : String
    return "" if env.empty?

    env.map { |name, value| "#{name}=#{Process.quote(value)}" }.join(" ") + " "
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
