require "yaml"

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

    def self.load : Dependencies
      Dependencies.new(DEPENDENCIES_YAML)
    end

    @supported : Array(String)
    @modules : Hash(String, Hash(String, Array(String)))

    def initialize(yaml : String)
      parsed = YAML.parse(yaml)
      @supported = parsed["supported"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      @modules = parse_modules(parsed)
    end

    # The deliberate chosen-support set (FQCNs). Promoting a module is a
    # one-line data-file commit, not a code change.
    def supported : Array(String)
      @supported.dup
    end

    def installed_modules : Array(String)
      @modules.keys.sort!
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

      PackageSets.new(
        real_debian.uniq!, krikri_debian.uniq!,
        real_rpm.uniq!, krikri_rpm.uniq!,
        python.uniq!, collections.uniq!)
    end

    private def union_base(key : String) : {Array(String), Array(String)}
      base = @modules[key]?
      return {[] of String, [] of String} unless base

      real = (base["real"]? || [] of String) + (base["both"]? || [] of String)
      krikri = (base["krikri"]? || [] of String) + (base["both"]? || [] of String)
      {real, krikri}
    end

    private def union_entries(module_fqcns : Array(String), key : String) : Array(String)
      module_fqcns.flat_map { |fqcn| @modules[fqcn]?.try(&.[key]?) || [] of String }
    end

    def unknown?(module_fqcns : Array(String)) : Array(String)
      module_fqcns.reject { |fqcn| @modules.has_key?(fqcn) }
    end

    private def parse_modules(parsed : YAML::Any) : Hash(String, Hash(String, Array(String)))
      result = {} of String => Hash(String, Array(String))
      return result unless parsed.as_h?

      parsed.as_h.each do |key, value|
        next if key.to_s == "supported"

        result[key.to_s] = parse_entry(value)
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
