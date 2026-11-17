require "./fixtures"

module KrikriPlaybookGenerator
  # The transport a row's engines use to reach the play's hosts. Local is
  # the historical `ansible_connection=local` inventory; the SSH variants
  # reach a real sshd inside the same isolated container/VM, so user
  # defaults, key discovery, host:port inventory entries and delegation
  # over the wire are compared too.
  #
  # The variants exist because the connection settings can arrive through
  # several different doors, and a fix verified through one door can hide a
  # gap in another:
  #   ssh           - every setting in the inventory
  #   ssh-cli       - user and key as `-u` / `--private-key` flags
  #   ssh-hostport  - `host:port` inventory entry, user/key as flags
  #   ssh-env-key   - ANSIBLE_PRIVATE_KEY_FILE
  #   ssh-env-user  - ANSIBLE_REMOTE_USER
  struct ConnectionProfile
    enum Kind
      Local
      Ssh
      SshCli
      SshHostPort
      SshEnvKey
      SshEnvUser
    end

    KINDS     = %w[local ssh ssh-cli ssh-hostport ssh-env-key ssh-env-user]
    SSH_KINDS = %w[ssh ssh-cli ssh-hostport ssh-env-key ssh-env-user]

    getter kind : Kind

    def initialize(@kind : Kind)
    end

    def self.local : ConnectionProfile
      new(Kind::Local)
    end

    def self.ssh_profiles : Array(ConnectionProfile)
      SSH_KINDS.map { |value| parse(value) || local }
    end

    def self.parse(value : String) : ConnectionProfile?
      case value
      when "local"        then new(Kind::Local)
      when "ssh"          then new(Kind::Ssh)
      when "ssh-cli"      then new(Kind::SshCli)
      when "ssh-hostport" then new(Kind::SshHostPort)
      when "ssh-env-key"  then new(Kind::SshEnvKey)
      when "ssh-env-user" then new(Kind::SshEnvUser)
      end
    end

    # `local`, `ssh`, `both` (local plus every SSH variant) or a
    # comma-separated list of the variants. nil for any unknown value so
    # the caller can name the flag.
    def self.parse_list(value : String) : Array(ConnectionProfile)?
      values = value.split(',').map(&.strip)
      return if values.empty?

      profiles = [] of ConnectionProfile
      values.each do |entry|
        if entry == "both"
          profiles << local
          profiles.concat(ssh_profiles)
        else
          profile = parse(entry) || return
          profiles << profile
        end
      end
      profiles.uniq
    end

    def local? : Bool
      kind.local?
    end

    def ssh? : Bool
      !local?
    end

    def label : String
      case kind
      in Kind::Local       then "local"
      in Kind::Ssh         then "ssh"
      in Kind::SshCli      then "ssh-cli"
      in Kind::SshHostPort then "ssh-hostport"
      in Kind::SshEnvKey   then "ssh-env-key"
      in Kind::SshEnvUser  then "ssh-env-user"
      end
    end

    # The inventory line for one play host. `port` is the target's sshd
    # port (2222 in a container, 22 inside a microVM).
    def inventory_line(name : String, user : UserProfile, port : Int32) : String
      return "#{name} ansible_connection=local" unless ssh?

      account = self.account(user)
      key = Fixtures.ssh_key_path(user)
      case kind
      in Kind::Ssh
        "#{name} ansible_connection=ssh ansible_host=127.0.0.1 ansible_port=#{port} " \
        "ansible_user=#{account} ansible_private_key_file=#{key}"
      in Kind::SshCli
        "#{name} ansible_connection=ssh ansible_host=127.0.0.1 ansible_port=#{port}"
      in Kind::SshHostPort
        "#{name}:#{port} ansible_connection=ssh ansible_host=127.0.0.1"
      in Kind::SshEnvKey
        "#{name} ansible_connection=ssh ansible_host=127.0.0.1 ansible_port=#{port} ansible_user=#{account}"
      in Kind::SshEnvUser
        "#{name} ansible_connection=ssh ansible_host=127.0.0.1 ansible_port=#{port} " \
        "ansible_private_key_file=#{key}"
      in Kind::Local
        "#{name} ansible_connection=local"
      end
    end

    # Connection arguments the engine command itself carries (`-u`,
    # `--private-key`). Empty for the local row and the inventory/env
    # variants.
    def cli_flags(user : UserProfile) : Array(String)
      return [] of String unless kind.ssh_cli? || kind.ssh_host_port?

      ["-u", account(user), "--private-key", Fixtures.ssh_key_path(user)]
    end

    # Environment the SSH variants need. The host key is generated into the
    # committed image and reused by every per-playbook container, but the
    # engines still get a deterministic answer rather than a known_hosts
    # lookup; both engines read the same variables.
    def env(user : UserProfile) : Hash(String, String)
      return {} of String => String unless ssh?

      env = {"ANSIBLE_HOST_KEY_CHECKING" => "False"}
      env["ANSIBLE_PRIVATE_KEY_FILE"] = Fixtures.ssh_key_path(user) if kind.ssh_env_key?
      env["ANSIBLE_REMOTE_USER"] = account(user) if kind.ssh_env_user?
      env
    end

    # The account the SSH session logs in as. A row under --user-profile
    # nonroot must log in as the provisioned unprivileged account, since
    # only that account and root have the generated key installed.
    def account(user : UserProfile) : String
      user.nonroot? ? Fixtures::UNPRIVILEGED_USER : "root"
    end
  end
end
