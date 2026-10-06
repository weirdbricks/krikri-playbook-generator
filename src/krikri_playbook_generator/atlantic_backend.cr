require "base64"
require "http/client"
require "json"
require "openssl/hmac"
require "./cmd"
require "./fixtures"

module KrikriPlaybookGenerator
  class AtlanticProvisionError < Exception
  end

  # Real disposable-host backend: one Debian 13 or Rocky 10 VM per module
  # profile, both engines executed on the VM over SSH with the identical
  # invocation, VM terminated in `ensure` afterwards.
  #
  # Why one VM per profile rather than per playbook: provisioning a VM
  # costs minutes (Atlantic run-instance -> RUNNING -> SSH reachable ->
  # package installs), so the per-playbook freshness the podman backend
  # guarantees is traded away - playbooks of one profile run sequentially
  # on the same VM and can observe each other's state. Divergence triage
  # already discounts happy-path failures on real ansible (quality
  # section), and any suspected state-leak finding can be re-run alone
  # (`run <playbook.yml> --run-on-atlantic`) on a fresh VM.
  #
  # Unlike the podman backend, the engines run for real (no --check):
  # the VM is disposable, so mutation is the point - dnf installs, mariadb
  # databases and docker images are genuinely created.
  #
  # Talks to the Atlantic.net Cloud API directly (the same HMAC-SHA256
  # signing scheme terraform-provider-atlanticnet implements) instead of
  # shelling out to terraform: a batch needs at most a handful of VMs, and
  # programmatic create/terminate beats per-profile tfstate workspaces
  # here. Credentials come from KeePass via the same helper krikri-role-
  # tester uses. The account server cap (25 total, 2 permanently reserved)
  # is checked against live instances before any create.
  class AtlanticBackend
    API_ENDPOINT = "https://cloudapi.atlantic.net/"
    API_VERSION  = "2010-12-30"

    ACCOUNT_SERVER_CAP    = 25
    RESERVED_SERVERS      =  2
    USABLE_SERVER_CEILING = 22

    PLAN         = "G3.2GB"
    LOCATION     = "USEAST1"
    IMAGE_DEBIAN = "Debian-13.0.0_64bit"
    IMAGE_ROCKY  = "Rocky-10.0_64bit"
    IMAGE_UBUNTU = "ubuntu-24.04_64bit"

    # Byte-parity needs the same ansible-core everywhere (the podman path
    # asserts 2.19.11); pip pins it on the VMs too.
    EXPECTED_ANSIBLE_VERSION = "2.19.11"
    ANSIBLE_CORE_PIN         = "ansible-core==#{EXPECTED_ANSIBLE_VERSION}"

    INVENTORY        = "target ansible_connection=local\n"
    ENGINE_ENV_STRIP = "env -u ANSIBLE_GATHERING -u ANSIBLE_CACHE_PLUGIN -u ANSIBLE_CACHE_PLUGIN_CONNECTION ANSIBLE_NOCOLOR=1"

    # Which supported modules need a real host, and which VM profile
    # serves them. Anything not listed here belongs to the local/podman
    # path; Runner refuses to dispatch unlisted modules with
    # --run-on-atlantic rather than guessing.
    PROFILE_FOR_MODULE = {
      "dnf"             => "rpm",
      "dnf5"            => "rpm",
      "yum"             => "rpm",
      "yum_repository"  => "rpm",
      "dnf_versionlock" => "rpm",
      "yum_versionlock" => "rpm",
      "mysql_db"        => "db",
      "mysql_user"      => "db",
      "mysql_info"      => "db",
      "mysql_query"     => "db",
      "mysql_variables" => "db",
      "postgresql_db"   => "db",
      "postgresql_user" => "db",
      "postgresql_privs" => "db",
      "postgresql_query" => "db",
      "docker_container" => "containers",
      "docker_image"     => "containers",
      "docker_image_build" => "containers",
      "docker_login"       => "containers",
      "docker_network"     => "containers",
      "docker_network_info" => "containers",
      "docker_compose_v2"   => "containers",
      "podman_image"        => "containers",
      "zfs"            => "misc",
      "snap"           => "misc",
      "rabbitmq_plugin" => "misc",
      "rabbitmq_user"  => "misc",
      "virt_net"       => "misc",
      "nsupdate"       => "misc",
    }

    record Profile, image : String, packages : String, prep : String

    # `prep` runs AFTER the common prep (python3, pip, pinned ansible-core)
    # and after `packages`; it starts services and shapes their config so
    # the profile's modules have something real to talk to.
    PROFILES = {
      "rpm" => Profile.new(
        image: IMAGE_ROCKY,
        # python3-libdnf5 and dnf5 do not exist in Rocky 10's repos (the
        # RHEL family stays on dnf4 - verified live against BaseOS,
        # AppStream, CRB and EPEL), so real ansible's dnf5 module fails at
        # its import probe on these VMs; that failure is still comparable
        # byte-for-byte (krikri probes the same python path), only the
        # happy paths count as wasted coverage. versionlock IS in BaseOS.
        packages: "python3-dnf-plugin-versionlock",
        prep: "",
      ),
      "db" => Profile.new(
        image: IMAGE_DEBIAN,
        packages: "mariadb-server python3-pymysql postgresql python3-psycopg2",
        prep: <<-PREP
          systemctl enable --now mariadb
          systemctl enable --now postgresql
          PGHBA=$(ls /etc/postgresql/*/main/pg_hba.conf | head -1)
          sed -i '1i local all all trust\\nhost all all 127.0.0.1/32 trust\\nhost all all ::1/128 trust' "$PGHBA"
          systemctl reload postgresql
          su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='kpgdb'\" | grep -q 1 || psql -c 'CREATE DATABASE kpgdb'"
          su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='kpguser'\" | grep -q 1 || psql -c 'CREATE USER kpguser'"
        PREP
      ),
      "containers" => Profile.new(
        image: IMAGE_DEBIAN,
        packages: "docker.io podman python3-docker iptables",
        prep: <<-PREP
          systemctl enable --now docker
          docker pull alpine:3.20 >/dev/null 2>&1 || true
          docker pull busybox:latest >/dev/null 2>&1 || true
        PREP
      ),
      "misc" => Profile.new(
        # Ubuntu, not Debian 13: the Debian image's running kernel has no
        # matching headers in the current repo (6.12.43 installed vs
        # 6.12.107+ in the pool), so zfs-dkms can never build; Ubuntu 24.04
        # ships the zfs module in its stock linux-modules-extra. Its glibc
        # (2.39) still satisfies the binary's 2.38 maximum.
        image: IMAGE_UBUNTU,
        packages: "zfsutils-linux linux-modules-extra-$(uname -r) snapd rabbitmq-server python3-pika libvirt-daemon-system libvirt-clients python3-libvirt bind9 python3-dnspython",
        prep: <<-PREP
          depmod -a
          modprobe zfs
          if ! zpool list kpgpool >/dev/null 2>&1; then
            mkdir -p /tmp/kpg-zfs
            truncate -s 128M /tmp/kpg-zfs/pool.img
            zpool create -f kpgpool /tmp/kpg-zfs/pool.img
          fi
          systemctl enable --now snapd.socket
          systemctl enable --now rabbitmq-server
          systemctl enable --now libvirtd
          cat > /etc/bind/named.conf.local <<'KPG_BIND_EOF'
          zone "kpg-test.zone" {
              type master;
              file "/etc/bind/db.empty";
              allow-update { any; };
          };
          KPG_BIND_EOF
          systemctl enable --now named
        PREP
      ),
    }

    # Overrides pinning the connection-ish options the daemon-dependent
    # modules need to reach the profile's live services. Compiled into the
    # binary from module_overrides.yml - these YAML fragments live in
    # data/module_overrides.yml, not here.
    #
    # docker-compose-v2's CLI plugin ships under a name that moved between
    # Debian releases; install both candidate names, tolerate one failing.
    DOCKER_COMPOSE_INSTALL = "apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 || apt-get install -y -qq docker-compose >/dev/null 2>&1 || true"

    record Credentials, user : String, pass : String

    record Instance, id : String, name : String, ip : String?

    getter profiles_used : Array(String)

    @created_key_id : String? = nil

    def initialize(@krikri_bin : String, @engine_timeout : Int32, @max_hosts : Int32,
                   @work_dir : String = "")
      @work_dir = Path.home.join(".kpg-atlantic").to_s if @work_dir.empty?
      @suffix = "#{Time.utc.to_unix}-#{Process.pid}"
      @created_instances = [] of Instance
      @profiles_used = [] of String
    end

    def self.available? : Bool
      File.exists?("/usr/local/bin/keypass-tool.sh") &&
        File.exists?("/home/labros/Dropbox/Dirless/DirlessPasswords.kdbx")
    end

    def fetch_credentials : Credentials
      unlock = Cmd.run("/usr/local/bin/keypass-tool.sh", timeout: 60.0)
      password = unlock.stdout.strip
      raise AtlanticProvisionError.new("CREDENTIALS_FAILED: KeePass unlock failed") if password.empty?

      user = Cmd.run("keepassxc-cli", ["show", "-s", "-a", "Username",
        "/home/labros/Dropbox/Dirless/DirlessPasswords.kdbx", "atlanticnet"],
        input: password, timeout: 60.0).stdout.strip
      pass = Cmd.run("keepassxc-cli", ["show", "-s", "-a", "Password",
        "/home/labros/Dropbox/Dirless/DirlessPasswords.kdbx", "atlanticnet"],
        input: password, timeout: 60.0).stdout.strip
      raise AtlanticProvisionError.new("CREDENTIALS_FAILED") if user.empty? || pass.empty? || pass == "PROTECTED"

      Credentials.new(user, pass)
    end

    # ---- Atlantic.net API (same signing scheme as the terraform provider)

    private def api(creds : Credentials, action : String, extra : Hash(String, String) = {} of String => String) : JSON::Any
      ts = Time.utc.to_unix
      guid = random_guid
      sig = Base64.strict_encode(OpenSSL::HMAC.digest(:sha256, creds.pass, "#{ts}#{guid}"))

      params = HTTP::Params.new
      params["Action"] = action
      params["Format"] = "json"
      params["Version"] = API_VERSION
      params["ACSAccessKeyId"] = creds.user
      params["Timestamp"] = ts.to_s
      params["Rndguid"] = guid
      params["Signature"] = sig
      extra.each { |k, v| params[k] = v }

      headers = HTTP::Headers.new
      headers["User-Agent"] = "krikri-playbook-generator"
      client = HTTP::Client.new(URI.parse(API_ENDPOINT))
      client.connect_timeout = 30.seconds
      client.read_timeout = 120.seconds
      response = client.get("/?#{params}", headers: headers)
      unless response.status.success?
        raise AtlanticProvisionError.new("Atlantic API #{action} HTTP #{response.status}: #{response.body[0, 300]}")
      end

      begin
        parsed = JSON.parse(response.body)
      rescue e : JSON::ParseException
        raise AtlanticProvisionError.new("Atlantic API #{action} returned non-JSON: #{response.body[0, 300]} (#{e})")
      end

      # the API reports failures as HTTP 200 with an {"error": ...} body
      if error = parsed["error"]?
        raise AtlanticProvisionError.new("Atlantic API #{action} error #{error.dig?("code")}: #{error.dig?("message")}")
      end

      parsed
    end

    def random_guid : String
      bytes = Random::Secure.random_bytes(16)
      # RFC 4122 v4 shape, like the provider's uuid.New()
      bytes[6] = (bytes[6] & 0x0f) | 0x40
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      hex = bytes.hexstring
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end

    # Live instance count via list-instances; statuses that don't consume
    # quota are excluded, mirroring the terraform path's capacity math.
    def live_instance_count(creds : Credentials) : Int32
      resp = api(creds, "list-instances")
      set = resp.dig?("list-instancesresponse", "instancesSet")
      return 0 unless set
      items = set.as_h?.try(&.values) || [] of JSON::Any
      items.count do |item|
        status = item.dig?("vm_status").try(&.as_s?) || ""
        !NON_COUNTED_STATUSES.includes?(status.upcase)
      end
    end

    NON_COUNTED_STATUSES = Set{"REMOVED", "TERMINATED"}

    # every instance live under the account (id, name, status) - the leak
    # sweep uses this to find kpg* servers a crashed run never tore down
    def list_instances(creds : Credentials) : Array(Instance)
      resp = api(creds, "list-instances")
      set = resp.dig?("list-instancesresponse", "instancesSet")
      return [] of Instance unless set
      items = set.as_h?.try(&.values) || [] of JSON::Any
      items.compact_map do |item|
        next unless item.as_h?
        # list-instances spells it "InstanceId"; run-instance "instanceid"
        id = item.dig?("InstanceId").try(&.to_s) || item.dig?("instanceid").try(&.to_s)
        next unless id
        Instance.new(id: id,
          name: item.dig?("vm_description").try(&.as_s?) || "",
          ip: item.dig?("vm_ip_address").try(&.as_s?))
      end
    end

    def create_ssh_key(creds : Credentials, name : String, public_key : String) : String
      resp = api(creds, "add-sshkey", {"key_name" => name, "public_key" => public_key})
      result = resp.dig?("add-sshkeyresponse", "result") || resp.dig?("result")
      key_id = result.try(&.dig?("key_id")).try(&.as_s?)
      raise AtlanticProvisionError.new("add-sshkey returned no key_id: #{resp.inspect[0, 300]}") unless key_id
      key_id
    end

    def delete_ssh_key(creds : Credentials, key_id : String) : Nil
      api(creds, "delete-sshkey", {"key_id" => key_id})
    rescue e : AtlanticProvisionError
      # a stray key is a cleanup annoyance, not a batch failure
      STDERR.puts "warning: delete-sshkey #{key_id} failed: #{e.message}"
    end

    def run_instance(creds : Credentials, name : String, image : String, key_id : String) : String
      resp = api(creds, "run-instance", {
        "servername"  => name,
        "imageid"     => image,
        "planname"    => PLAN,
        "vm_location" => LOCATION,
        "server_qty"  => "1",
        "key_id"      => key_id,
      })
      item = resp.dig?("run-instanceresponse", "instancesSet", "item")
      instance_id = item.try(&.dig?("instanceid")).try(&.to_s)
      raise AtlanticProvisionError.new("run-instance returned no instanceid: #{resp.inspect[0, 300]}") unless instance_id
      instance_id
    end

    def describe_instance(creds : Credentials, instance_id : String) : Instance?
      resp = api(creds, "describe-instance", {"instanceid" => instance_id})
      item = resp.dig?("describe-instanceresponse", "instancesSet", "item")
      return unless item && item.as_h?

      Instance.new(
        id: instance_id,
        name: item.dig?("vm_description").try(&.as_s?) || "",
        ip: item.dig?("vm_ip_address").try(&.as_s?))
    end

    def terminate_instance(creds : Credentials, instance_id : String) : Nil
      api(creds, "terminate-instance", {"instanceid" => instance_id})
    rescue e : AtlanticProvisionError
      STDERR.puts "warning: terminate-instance #{instance_id} failed: #{e.message}"
    end

    # ---- VM lifecycle

    # Runs all profile groups, at most @max_hosts VMs concurrently, and
    # returns {profile, playbook_path, ansible, krikri} tuples for every
    # playbook. Groups is profile => playbook paths.
    def run_groups(groups : Hash(String, Array(String))) : Array(NamedTuple(
      profile: String, playbook: String, ansible: Cmd::Result, krikri: Cmd::Result))
      raise AtlanticProvisionError.new("no playbook groups to run") if groups.empty?
      unknown = groups.keys.reject { |p| PROFILES.has_key?(p) }
      raise AtlanticProvisionError.new("unknown profile(s): #{unknown.join(", ")}") unless unknown.empty?

      creds = fetch_credentials
      existing = live_instance_count(creds)
      request = groups.size
      if existing + request > USABLE_SERVER_CEILING
        raise AtlanticProvisionError.new(
          "Atlantic server cap: #{existing} live + #{request} requested exceeds the usable ceiling (#{USABLE_SERVER_CEILING})")
      end

      Dir.mkdir_p(@work_dir)
      done = Channel(NamedTuple(profile: String, results: Array(NamedTuple(playbook: String, ansible: Cmd::Result, krikri: Cmd::Result)))).new
      # buffered: the main fiber enqueues every profile before the worker
      # fibers even exist, so an unbuffered channel would deadlock here
      workers = Channel(String).new(groups.size * 2)
      groups.each_key { |profile| workers.send(profile) }
      groups.size.times { workers.send("") }

      concurrency = Math.min(groups.size, @max_hosts)
      concurrency.times do
        spawn do
          loop do
            profile = workers.receive
            break if profile.empty?
            run_profile_group(creds, profile, groups[profile], done)
          end
        rescue e
          STDERR.puts "ERROR: atlantic worker failed: #{e.message}"
          done.send({profile: "", results: [] of NamedTuple(playbook: String, ansible: Cmd::Result, krikri: Cmd::Result)})
        end
      end

      all_results = [] of NamedTuple(profile: String, playbook: String, ansible: Cmd::Result, krikri: Cmd::Result)
      groups.size.times do
        received = done.receive
        received[:results].each do |entry|
          all_results << {profile: received[:profile], playbook: entry[:playbook], ansible: entry[:ansible], krikri: entry[:krikri]}
        end
      end
      all_results
    ensure
      teardown(creds)
    end

    private def run_profile_group(creds : Credentials, profile : String, playbooks : Array(String),
                                  done : Channel(NamedTuple(profile: String, results: Array(NamedTuple(playbook: String, ansible: Cmd::Result, krikri: Cmd::Result))))) : Nil
      results = [] of NamedTuple(playbook: String, ansible: Cmd::Result, krikri: Cmd::Result)
      begin
        begin
          vm = provision_profile(creds, profile)
        rescue e : AtlanticProvisionError
          # first-boot flakes happen (an Ubuntu VM once never reached SSH in
          # 600s while an identical one came up immediately); a retry on a
          # fresh VM is cheap next to a whole profile of errored results.
          # The failed attempt's VM/key are still tracked and torn down.
          STDERR.puts "warning: profile #{profile} provisioning failed (#{e.message}) - retrying once on a fresh VM"
          vm = provision_profile(creds, profile)
        end
        @profiles_used << profile
        playbooks.each do |path|
          outcome = run_playbook(vm, path)
          results << {playbook: path, ansible: outcome[:ansible], krikri: outcome[:krikri]}
        end
      rescue e : Exception
        STDERR.puts "ERROR: profile #{profile}: #{e.message}"
        already = results.map(&.[:playbook]).to_set
        playbooks.each do |path|
          next if already.includes?(path)
          results << {playbook: path,
            ansible: Cmd::Result.new(-1, "", "profile provisioning failed: #{e.message}"),
            krikri: Cmd::Result.new(-1, "", "profile provisioning failed: #{e.message}")}
        end
      end
      done.send({profile: profile, results: results})
    end

    record Vm, ip : String, ssh_key : String, ssh_base : Array(String)

    # shared ssh option vector; callers append "root@ip" and the remote
    # command as separate argv entries (Cmd.run never goes through a shell)
    private def ssh_options(key_path : String) : Array(String)
      ["-i", key_path, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=15", "-o", "ConnectionAttempts=12", "-o", "ServerAliveInterval=30"]
    end

    private def provision_profile(creds : Credentials, profile : String) : Vm
      spec = PROFILES[profile]
      key_path = File.join(@work_dir, "kpg-key-#{profile}-#{@suffix}")
      Cmd.run("ssh-keygen", ["-t", "ed25519", "-N", "", "-q", "-f", key_path])
      public_key = File.read("#{key_path}.pub").strip

      key_name = "kpg#{@suffix}-#{profile}"
      key_id = create_ssh_key(creds, key_name, public_key)
      @created_key_id = key_id

      server_name = "kpg#{@suffix}-#{profile}"
      instance_id = run_instance(creds, server_name, spec.image, key_id)
      @created_instances << Instance.new(instance_id, server_name, nil)

      ip = wait_for_ip(creds, instance_id, server_name)
      @created_instances = @created_instances.map { |i| i.id == instance_id ? Instance.new(i.id, i.name, ip) : i }

      ssh_base = ssh_options(key_path)
      vm = Vm.new(ip, key_path, ssh_base)
      wait_ssh(vm)
      prep_vm(vm, profile, spec)
      vm
    end

    private def wait_for_ip(creds : Credentials, instance_id : String, pending_name : String,
                            timeout : Float64 = 420.0) : String
      deadline = Time.instant + timeout.seconds
      loop do
        begin
          instance = list_instances(creds).find { |i| i.id == instance_id || i.name == pending_name }
          ip = instance.try(&.ip)
          return ip if ip && !ip.empty?
        rescue e : AtlanticProvisionError
          # transient list failure; keep polling until the deadline
        end
        raise AtlanticProvisionError.new("instance #{instance_id} had no IP after #{timeout.to_i}s") if Time.instant > deadline
        sleep 10.seconds
      end
    end

    private def wait_ssh(vm : Vm, timeout : Float64 = 600.0) : Nil
      deadline = Time.instant + timeout.seconds
      loop do
        result = Cmd.run("timeout", ["60", "ssh"] + vm.ssh_base + ["root@#{vm.ip}", "echo up"], timeout: 70.0)
        return if result.rc == 0
        raise AtlanticProvisionError.new("SSH never came up on #{vm.ip} after #{timeout.to_i}s") if Time.instant > deadline
        sleep 10.seconds
      end
    end

    private def prep_vm(vm : Vm, profile : String, spec : Profile) : Nil
      # one failed package must not blank out the whole profile's set: the
      # original single apt line died wholesale on the first unavailable
      # package (zfsutils-linux without contrib), leaving rabbitmq/bind/
      # libvirt uninstalled too
      installs = spec.packages.split.map do |pkg|
        "(apt-get install -y -qq --no-install-recommends #{pkg} >/dev/null 2>&1 || " \
        "dnf install -y -q #{pkg} >/dev/null 2>&1 || echo PREP_PKG_FAIL #{pkg})"
      end.join("\n")
      script = common_prep + "\n" + installs + "\n" +
               (profile == "containers" ? "#{DOCKER_COMPOSE_INSTALL}\n" : "") +
               spec.prep + "\n"
      result = run_script(vm, script, 1200.0)
      failed = result.stdout.lines.select(&.starts_with?("PREP_PKG_FAIL "))
      raise AtlanticProvisionError.new("prep packages failed on #{vm.ip}: #{failed.join(", ")}") unless failed.empty?
      stage_krikri_binary(vm, profile)
      seed_fixtures(vm)
      write_inventory(vm)
      assert_ansible_version!(vm)
    end

    private def common_prep : String
      <<-PREP
        set -e
        export DEBIAN_FRONTEND=noninteractive
        (systemctl stop unattended-upgrades 2>/dev/null || true)
        (pkill -9 -f /unattended-upgrad[e] 2>/dev/null || true)
        if command -v apt-get >/dev/null; then
          rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
          dpkg --configure -a
          # zfsutils-linux lives in contrib on Debian; deb822 (debian.sources)
          # and classic sources.list both need the component added. Ubuntu
          # has no contrib - leave its sources alone.
          if grep -qi debian /etc/os-release; then
            sed -i 's/^Components:.*/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
            sed -i 's/main non-free-firmware/main contrib non-free non-free-firmware/' /etc/apt/sources.list 2>/dev/null || true
          fi
          apt-get update -qq
          apt-get install -y -qq python3 python3-pip rsync sudo >/dev/null
          pip3 install --quiet --break-system-packages #{ANSIBLE_CORE_PIN}
        else
          dnf makecache -q 2>/dev/null || dnf makecache || true
          dnf install -y -q python3 python3-pip
          pip3 install --quiet #{ANSIBLE_CORE_PIN}
        fi
        mkdir -p /work /opt/krikri/bin
      PREP
    end

    private def run_script(vm : Vm, script : String, timeout : Float64) : Cmd::Result
      result = Cmd.run("ssh", vm.ssh_base + ["root@#{vm.ip}", "bash -s"], input: script, timeout: timeout)
      raise AtlanticProvisionError.new("prep script failed on #{vm.ip} rc=#{result.rc}: #{(result.stdout + result.stderr)[-500, 500]}") unless result.rc == 0
      result
    end

    private def stage_krikri_binary(vm : Vm, profile : String) : Nil
      plugins_dir = File.join(File.dirname(@krikri_bin), "plugins")
      raise AtlanticProvisionError.new("krikri plugins dir #{plugins_dir.inspect} not found next to #{@krikri_bin.inspect}") unless File.exists?(plugins_dir)

      # one tar stream instead of ~130 scp round trips: per-file sftp
      # latency over the WAN turned the plugins upload into a >10min
      # transfer (Cmd timeout rc 124). The name is per-profile: profile
      # workers run concurrently and one worker's File.delete must never
      # truncate another worker's upload (seen live in the first batch).
      tar_path = File.join(@work_dir, "kpg-krikri-#{profile}-#{@suffix}.tar.gz")
      tar = Cmd.run("tar", ["-czf", tar_path, "-C", File.dirname(@krikri_bin), File.basename(@krikri_bin), "plugins"], timeout: 300.0)
      raise AtlanticProvisionError.new("krikri tar failed: #{tar.stderr}") unless tar.rc == 0

      scp_args = ["-i", vm.ssh_key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]
      upload = Cmd.run("scp", scp_args + [tar_path, "root@#{vm.ip}:/tmp/kpg-krikri.tar.gz"], timeout: 600.0)
      raise AtlanticProvisionError.new("krikri upload failed rc=#{upload.rc}: OUT=#{upload.stdout[0, 300]} ERR=#{upload.stderr[0, 300]}") unless upload.rc == 0
      exec!(vm, "tar -xzf /tmp/kpg-krikri.tar.gz -C /opt/krikri/bin && rm -f /tmp/kpg-krikri.tar.gz && chmod +x /opt/krikri/bin/krikri-playbook /opt/krikri/bin/plugins/*", 300.0)
      File.delete(tar_path)
    end

    private def seed_fixtures(vm : Vm) : Nil
      result = Cmd.run("ssh", vm.ssh_base + ["root@#{vm.ip}", "bash -s"], input: Fixtures::SEED_SCRIPT, timeout: 120.0)
      raise AtlanticProvisionError.new("seeding fixtures failed: #{result.stderr}") unless result.rc == 0
    end

    private def write_inventory(vm : Vm) : Nil
      result = Cmd.run("ssh", vm.ssh_base + ["root@#{vm.ip}", "cat > /work/inventory.ini"], input: INVENTORY, timeout: 60.0)
      raise AtlanticProvisionError.new("writing inventory.ini failed: #{result.stderr}") unless result.rc == 0
    end

    private def assert_ansible_version!(vm : Vm) : Nil
      result = exec_remote(vm, "ansible-playbook --version")
      raise AtlanticProvisionError.new("ansible-playbook --version failed on #{vm.ip}: #{result.stderr}") unless result.rc == 0
      version = result.stdout.match(/core (\d+\.\d+\.\d+)/).try(&.[1])
      unless version == EXPECTED_ANSIBLE_VERSION
        raise AtlanticProvisionError.new(
          "VM ansible-core is #{version.inspect}, expected #{EXPECTED_ANSIBLE_VERSION} - " \
          "byte-parity comparisons against a different engine version are meaningless")
      end
    end

    private def exec!(vm : Vm, script : String, timeout : Float64 = 120.0) : Nil
      result = exec_remote(vm, script, timeout)
      raise AtlanticProvisionError.new("exec failed on #{vm.ip} rc=#{result.rc}: #{result.stderr[0, 300]}") unless result.rc == 0
    end

    private def exec_remote(vm : Vm, script : String, timeout : Float64 = 120.0) : Cmd::Result
      Cmd.run("timeout", [(timeout + 60).to_i.to_s, "ssh"] + vm.ssh_base + ["root@#{vm.ip}", script], timeout: timeout + 90.0)
    end

    def run_playbook(vm : Vm, playbook_path : String) : {ansible: Cmd::Result, krikri: Cmd::Result}
      basename = File.basename(playbook_path)
      copy = Cmd.run("scp", ["-i", vm.ssh_key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
        playbook_path, "root@#{vm.ip}:/work/#{basename}"], timeout: 120.0)
      raise AtlanticProvisionError.new("playbook upload failed: #{copy.stderr}") unless copy.rc == 0

      ansible = exec_engine(vm, "ansible-playbook", basename)
      krikri = exec_engine(vm, "/opt/krikri/bin/krikri-playbook", basename)
      {ansible: ansible, krikri: krikri}
    end

    private def exec_engine(vm : Vm, engine_cmd : String, basename : String) : Cmd::Result
      script = "cd /work && #{ENGINE_ENV_STRIP} timeout #{@engine_timeout} " \
               "#{engine_cmd} -i inventory.ini /work/#{basename} </dev/null"
      result = exec_remote(vm, script, @engine_timeout + 60.0)
      # ssh reports its own failures as 255; those are provisioning errors,
      # not engine results.
      if result.rc == 255
        raise AtlanticProvisionError.new("ssh session failed running #{engine_cmd}: #{result.stderr[0, 300]}")
      end
      result
    end

    def teardown(creds : Credentials?) : Nil
      return unless creds
      @created_instances.each do |instance|
        terminate_instance(creds, instance.id)
      end
      @created_instances.clear
      if key_id = @created_key_id
        delete_ssh_key(creds, key_id)
        @created_key_id = nil
      end
    end

    # Any kpg* instances still live after teardown are orphans - surfaced
    # so the caller can terminate them manually.
    def self.leak_check(creds : Credentials) : Array(String)
      backend = new("/dev/null", 1, 1)
      backend.list_instances(creds).map do |instance|
        "#{instance.name} (#{instance.id}, #{instance.ip})"
      end
    end
  end
end
