require "yaml"
require "./overrides"

module KrikriPlaybookGenerator
  # Union dependency model for the podman template pair. See
  # data/module_dependencies.yml for the file format. The backend
  # installs the union of the base lists plus the selected modules'
  # extras, once per profile, instead of one image per module.
  class Dependencies
    record PackageSets, real_debian : Array(String), krikri_debian : Array(String),
      real_rpm : Array(String), krikri_rpm : Array(String),
      python : Array(String), collections : Array(String)

    DEPENDENCIES_YAML = {{ read_file("#{__DIR__}/data/module_dependencies.yml") }}

    # The base lists are sections of the data file, not modules: giving them
    # to the microvm profile selection let rpm_modules count as an Ubuntu
    # "module", so the Ubuntu golden tried to install python3-dnf and
    # python3-dnf-plugin-versionlock (which do not exist there).
    BASE_SECTIONS = %w[deb_modules rpm_modules]

    # Modules that need rpm tooling or an SELinux-enabled kernel: no Debian
    # or Ubuntu host can run them. The placement lives here because it picks
    # the host image a module belongs to, the same decision the package
    # lists express, and both the runner and the generator need it.
    ROCKY_MODULES = Set{
      "dnf", "dnf5", "yum", "yum_repository", "rpm_key", "dnf_versionlock", "yum_versionlock",
      "selinux", "seboolean", "sefcontext", "seport", "firewalld", "firewalld_info",
    }

    # The host profile a playbook's tasks must share: one playbook runs on
    # one golden/container image, and the two profiles cannot be installed
    # side by side. `module_names` may hold short names or FQCNs.
    def self.host_profile(module_names : Array(String)) : String
      module_names.any? { |name| ROCKY_MODULES.includes?(name.split(".").last) } ? "rocky" : "ubuntu"
    end

    # Which images one playbook runs on. One playbook still runs on one
    # image; a module marked distro-polymorphic in the overrides
    # (`profiles: [debian, rocky]`) is simply run once per image, so its
    # coverage spans both. A rocky-only module pins the playbook to Rocky
    # (the Debian image cannot host it), and a v2 playbook needs EVERY
    # task's module to accept the extra profile.
    def self.playbook_profiles(module_names : Array(String), overrides : Overrides) : Array(String)
      return ["rocky"] if module_names.any? { |name| host_profile([name]) == "rocky" }

      requested = module_names.map { |name| overrides.profiles(name) }
      if !requested.empty? && requested.all? { |list| list.includes?("debian") && list.includes?("rocky") }
        ["debian", "rocky"]
      else
        ["debian"]
      end
    end

    def self.load : Dependencies
      Dependencies.new(DEPENDENCIES_YAML)
    end

    # The data file's `collection_pins:` section, not a module entry.
    COLLECTION_PINS_KEY = "collection_pins"

    @supported : Array(String)
    @modules : Hash(String, Hash(String, Array(String)))
    @collection_pins : Hash(String, String)

    def initialize(yaml : String)
      parsed = YAML.parse(yaml)
      @supported = parsed["supported"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      @collection_pins = parse_collection_pins(parsed[COLLECTION_PINS_KEY]?)
      @modules = parse_modules(parsed)
    end

    # The deliberate chosen-support set (FQCNs). Promoting a module is a
    # one-line data-file commit, not a code change.
    def supported : Array(String)
      @supported.dup
    end

    def installed_modules : Array(String)
      @modules.keys.reject { |key| BASE_SECTIONS.includes?(key) }.sort!
    end

    # collection name -> the version the reference engine must install.
    def collection_pins : Hash(String, String)
      @collection_pins.dup
    end

    # Union of the base lists and the given modules' extras, partitioned
    # for the real vs krikri template container.
    def package_sets(module_fqcns : Array(String)) : PackageSets
      real_debian, krikri_debian = union_base("deb_modules")
      real_rpm, krikri_rpm = union_base("rpm_modules")
      real_debian += union_entries(module_fqcns, "real_debian") + union_entries(module_fqcns, "real")
      krikri_debian += union_entries(module_fqcns, "krikri_debian") + union_entries(module_fqcns, "krikri")
      real_rpm += union_entries(module_fqcns, "real_rpm")
      krikri_rpm += union_entries(module_fqcns, "krikri_rpm")
      python = union_entries(module_fqcns, "python") + union_entries(module_fqcns, "real_python")
      collections = union_entries(module_fqcns, "collections") + union_entries(module_fqcns, "real_collections")
      # The real engine resolves a module through its collection, so a
      # module's FQCN already names the collection that must be installed;
      # deriving it here means a new module in the scope works without a
      # hand-written `collections:` entry (forgetting one turned every task
      # of that module into a "couldn't resolve module/action" harness gap).
      collections += module_fqcns.compact_map { |fqcn| Dependencies.collection_for(fqcn) }

      PackageSets.new(
        real_debian.uniq!, krikri_debian.uniq!,
        real_rpm.uniq!, krikri_rpm.uniq!,
        python.uniq!, pin_collections(collections))
    end

    # Every collection requirement is spelled `name:==pin` when the data
    # file pins it, so a hand-written `collections:` entry and the
    # FQCN-derived name for the same collection collapse to one pinned
    # requirement instead of installing both the pin and a floating
    # latest. A bump therefore lands in the fingerprint (and a rebake).
    private def pin_collections(requirements : Array(String)) : Array(String)
      pinned = requirements.map do |requirement|
        name, version = Dependencies.split_collection(requirement)
        next requirement if version

        pin = @collection_pins[name]?
        pin ? "#{name}:==#{pin}" : name
      end
      pinned.uniq!
    end

    # `community.general:==12.5.0` -> {"community.general", "==12.5.0"};
    # an unpinned `community.general` yields a nil version.
    def self.split_collection(requirement : String) : {String, String?}
      name, separator, version = requirement.partition(':')
      {name, separator.empty? ? nil : version}
    end

    # Parses `ansible-galaxy collection list --format json` (install path ->
    # collection -> {"version": ...}) into name -> the installed versions in
    # search-path order. ansible prints those paths in the order it searches
    # them and Crystal's JSON parser keeps object order, so the first entry
    # is the copy both engines actually load; the rest are lower-priority
    # copies (e.g. Debian's distro collections) that only matter if they
    # come first.
    def self.installed_collection_versions(json : String) : Hash(String, Array(String))
      result = {} of String => Array(String)
      parsed = JSON.parse(json).as_h?
      parsed.try &.each_value do |collections|
        collections.as_h?.try do |entries|
          entries.each do |name, info|
            version = info.as_h?.try(&.["version"]?).try(&.as_s?)
            next unless version

            (result[name]? || (result[name] = [] of String)) << version
          end
        end
      end
      result
    end

    # One line per pinned requirement the resolved install does not satisfy.
    # Only the first copy counts: `~/.ansible/collections` outranks the
    # distro tree for both engines, so a pinned install there wins even when
    # Debian's ansible package ships an older copy. A collection whose first
    # copy is not the pin (or that is missing) would hand real ansible a
    # different argument spec than krikri targets.
    def self.collection_version_mismatches(requirements : Array(String),
                                           installed : Hash(String, Array(String))) : Array(String)
      requirements.compact_map do |requirement|
        name, version = split_collection(requirement)
        next unless version

        versions = installed[name]? || [] of String
        next if versions.first? == strip_operator(version)

        "expected #{name} #{strip_operator(version)}, resolved " +
          (versions.empty? ? "no installed copy" : versions.join(" then "))
      end
    end

    private def self.strip_operator(version : String) : String
      version.sub(/^[=<>!~]+/, "")
    end

    private def union_base(key : String) : {Array(String), Array(String)}
      base = @modules[key]?
      return {[] of String, [] of String} unless base

      real = (base["real"]? || [] of String) + (base["both"]? || [] of String)
      krikri = (base["krikri"]? || [] of String) + (base["both"]? || [] of String)
      {real, krikri}
    end

    # `community.general.ini_file` -> `community.general`; nil for the core
    # namespace (bundled with ansible-core) and for bare module names.
    def self.collection_for(fqcn : String) : String?
      parts = fqcn.split('.')
      return if parts.size < 3
      namespace = parts[0, 2].join('.')
      return if namespace == "ansible.builtin" || namespace == "ansible.legacy"
      namespace
    end

    private def union_entries(module_fqcns : Array(String), key : String) : Array(String)
      module_fqcns.flat_map { |fqcn| entry_for(fqcn).try(&.[key]?) || [] of String }
    end

    # A hand-written playbook may name a module by its short name
    # (`seboolean`), which the table knows only by FQCN; match the unique
    # entry whose last segment is that name so its packages are still
    # installed.
    private def entry_for(name : String) : Hash(String, Array(String))?
      return @modules[name]? if @modules.has_key?(name)
      short = name.split(".").last
      matches = @modules.select { |key, _| key.split(".").last == short }
      matches.size == 1 ? matches.values.first : nil
    end

    def unknown?(module_fqcns : Array(String)) : Array(String)
      module_fqcns.reject { |fqcn| !entry_for(fqcn).nil? }
    end

    private def parse_modules(parsed : YAML::Any) : Hash(String, Hash(String, Array(String)))
      result = {} of String => Hash(String, Array(String))
      return result unless parsed.as_h?

      parsed.as_h.each do |key, value|
        next if key.to_s == "supported" || key.to_s == COLLECTION_PINS_KEY

        result[key.to_s] = parse_entry(value)
      end
      result
    end

    private def parse_collection_pins(value : YAML::Any?) : Hash(String, String)
      result = {} of String => String
      value.try(&.as_h?).try do |pins|
        pins.each do |name, pin|
          version = pin.as_s?
          result[name.to_s] = version if version
        end
      end
      result
    end

    private def parse_entry(value : YAML::Any?) : Hash(String, Array(String))
      result = Hash(String, Array(String)).new do |hash, key|
        hash[key] = [] of String
      end
      hash = value.try(&.as_h?)
      return result unless hash

      # Base entries use real/krikri/both; per-module entries use
      # real_debian/krikri_debian/real_rpm/krikri_rpm/python/collections
      # or the grouped real:/krikri:/both: form (see the data file).
      hash.each do |key, child|
        case key.to_s
        when "real", "krikri", "both"
          add_grouped_entry(result, key.to_s, child)
        else
          result[key.to_s] = (result[key.to_s]? || [] of String) + (child.as_a?.try(&.compact_map(&.as_s?)) || [] of String)
        end
      end
      merged = Hash(String, Array(String)).new
      result.each do |key, list|
        merged[key] = (merged[key]? || [] of String) + list
      end
      merged
    end

    private def append_entry(result : Hash(String, Array(String)), key : String, list : Array(String)) : Nil
      return if list.empty?
      result[key] = (result[key]? || [] of String) + list
    end

    private def add_grouped_entry(result : Hash(String, Array(String)), group : String, child : YAML::Any) : Nil
      if child.as_a?
        append_entry(result, group, child.as_a.compact_map(&.as_s?))
        return
      end
      child.as_h?.try do |parts|
        parts.each do |part_key, part_value|
          list = part_value.as_a?.try(&.compact_map(&.as_s?)) || [] of String
          suffix = grouped_suffix(part_key.to_s)
          sides = grouped_sides(group)
          sides.each { |side| append_entry(result, "#{side}#{suffix}", list) }
        end
      end
    end

    private def grouped_suffix(part_key : String) : String
      case part_key
      when "debian_packages" then "_debian"
      when "rpm_packages"    then "_rpm"
      when "python_packages" then "_python"
      when "collections"     then "_collections"
      else                        "_#{part_key}"
      end
    end

    private def grouped_sides(group : String) : Array(String)
      case group
      when "real"   then ["real", "real"]
      when "krikri" then ["krikri", "krikri"]
      else               ["real", "krikri"]
      end
    end
  end
end
