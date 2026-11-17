require "json"
require "./cmd"

module KrikriPlaybookGenerator
  # A single option in a module's argument_spec, normalized from
  # `ansible-doc -j`'s own parse of the module's DOCUMENTATION block.
  class OptionSchema
    property name : String
    property type : String
    property choices : Array(String)
    property? required : Bool
    property default : JSON::Any?
    property elements : String?
    # Populated for `type: dict` and for `type: list`/`elements: dict`: the
    # keys each dict element accepts, so a generated value can satisfy their
    # required entries instead of being a bare word (which real ansible
    # rejects with "dictionary requested, could not parse JSON or
    # key=value").
    property suboptions : Hash(String, OptionSchema)

    def initialize(@name, @type = "str", @choices = [] of String,
                   @required = false, @default = nil, @elements = nil,
                   @suboptions = {} of String => OptionSchema)
    end
  end

  # Normalized schema for one Ansible module: its options plus the
  # cross-option constraints Ansible's own argument_spec enforces.
  class ModuleSchema
    property module_name : String
    property collection : String
    property options : Hash(String, OptionSchema)
    property mutually_exclusive : Array(Array(String))
    property required_together : Array(Array(String))
    property required_if : Array(JSON::Any)
    property required_one_of : Array(Array(String))

    def initialize(@module_name, @collection = "ansible.builtin",
                   @options = {} of String => OptionSchema,
                   @mutually_exclusive = [] of Array(String),
                   @required_together = [] of Array(String),
                   @required_if = [] of JSON::Any,
                   @required_one_of = [] of Array(String))
    end
  end

  # Scans installed ansible-core + collection modules and normalizes them
  # into ModuleSchema, using the real, installed ansible-core's own
  # `ansible-doc -j` parse of each module's DOCUMENTATION block (more
  # robust than re-parsing the YAML ourselves, and it's exactly the schema
  # real ansible-playbook validates arguments against). Cross-option
  # constraints (mutually_exclusive/required_together/required_if/
  # required_one_of) aren't part of DOCUMENTATION, so those are filled in
  # separately via best-effort static extraction from the module's source
  # (see scripts/extract_constraints.py) — left empty when they can't be
  # statically resolved, never guessed at.
  class SchemaScanner
    CONSTRAINT_EXTRACTOR = {{ read_file("#{__DIR__}/scripts/extract_constraints.py") }}

    CORE_PREFIX = "ansible.builtin."

    class ScanError < Exception
    end

    def initialize(@module_filter : Array(String)? = nil, @all_modules : Bool = false,
                   @supported_community : Array(String)? = nil)
    end

    def scan : Array(ModuleSchema)
      names = @module_filter || discover_module_names
      scanned_names = [] of String
      schemas = names.compact_map do |name|
        schema = scan_module(name)
        scanned_names << name if schema
        schema
      end

      if requested = @module_filter
        skipped = requested.reject { |name| scanned_names.includes?(name) }
        unless skipped.empty?
          STDERR.puts "warning: skipped #{skipped.size} unscannable module(s): #{skipped.join(", ")}"
        end
      end

      schemas
    end

    # krikri's obligation is ansible.builtin core only, plus any community
    # modules explicitly chosen for support (Dependencies#supported, empty
    # until a module is promoted there). Those are FQCNs and stay FQCNs;
    # core names are returned short ("copy", not "ansible.builtin.copy")
    # since that's how the rest of the tool already addresses core modules.
    def self.core_module_names(listing : JSON::Any) : Array(String)
      listing.as_h.keys
        .select(&.starts_with?(CORE_PREFIX))
        .map(&.lchop(CORE_PREFIX))
        .sort!
    end

    def self.supported_module_names(listing : JSON::Any, supported : Array(String)) : Array(String)
      return [] of String if supported.empty?

      available = listing.as_h.keys
      supported.select { |fqcn| available.includes?(fqcn) }.sort!
    end

    # The default scope the loop's rotation is sourced from: ansible.builtin
    # core plus the promoted supported community FQCNs, straight from the
    # installed ansible-doc listing (one subprocess, same source `scan`
    # uses - the two cannot drift).
    def self.default_module_names(supported : Array(String)? = nil,
                                  warn_missing : Bool = true) : Array(String)
      names_from_listing(fetch_module_listing, supported || Dependencies.load.supported, warn_missing)
    end

    # krikri's own supported-module set, read from the binary under test
    # (`--list-modules`). The registry is the only source of truth for what
    # the engine implements, so a generator scope derived from it cannot
    # drift from the engine; an older binary without the flag, or one whose
    # answer cannot be parsed, yields no extra modules rather than a failed
    # scope listing.
    def self.krikri_module_names(krikri_bin : String) : Array(String)
      result = Cmd.run(krikri_bin, ["--list-modules"], timeout: 120.0)
      return [] of String unless result.rc == 0
      parsed = JSON.parse(result.stdout).as_a?
      return [] of String unless parsed

      parsed.compact_map(&.as_s?).map { |name| SCOPE_ALIASES.fetch(name, name) }.uniq!
    rescue JSON::ParseException
      [] of String
    rescue IO::Error
      [] of String
    end

    # Registry spellings ansible-doc cannot resolve on its own. krikri
    # registers some plugins under a bare alias (or a krikri-only FQCN) as
    # well as the real collection FQCN; the scope needs a name ansible-doc
    # can scan, so the alias is mapped to the module the real engine ships.
    SCOPE_ALIASES = {
      "virt_net" => "community.libvirt.virt_net",
    }

    # Modules krikri implements but this harness cannot exercise: they need
    # AWS credentials and a cloud, macOS, they are krikri-internal (no real
    # ansible counterpart exists to compare against), or they are play-level
    # keywords ansible does not accept inside `tasks:`. Excluding them keeps
    # the rotation free of playbooks that can only ever be wasted.
    SCOPE_EXCLUDED = Set{
      "py_module", "homebrew",
      # Removed from ansible-core 2.21 (only dnf/setup/gather_facts ship
      # now), so ansible-doc cannot resolve them and a generated task
      # could only ever fail on the real engine. krikri keeps the old
      # spellings registered for legacy playbooks.
      "facts", "yum",
      "ec2_ami_info", "ec2_instance", "ec2_key", "ec2_security_group",
      "ec2_vpc_net_info", "ec2_vpc_subnet_info", "ec2_metadata_facts",
      "iam_user_info",
      # import_playbook is a play/playbook-level directive: it takes a
      # playbook file and cannot be a task, so every generated task form
      # of it fails on real ansible before reaching any module logic.
      "import_playbook",
    }

    def self.fetch_module_listing : JSON::Any
      result = Cmd.run("ansible-doc", ["--list", "-j", "-t", "module"])
      raise ScanError.new("ansible-doc --list failed: #{result.stderr}") unless Cmd.success?(result)
      JSON.parse(result.stdout)
    end

    def self.names_from_listing(listing : JSON::Any, supported : Array(String)?,
                                warn_missing : Bool = true) : Array(String)
      names = core_module_names(listing).reject { |name| SCOPE_EXCLUDED.includes?(name) }
      return names if supported.nil? || supported.empty?

      extra = supported_module_names(listing, supported.reject { |fqcn| SCOPE_EXCLUDED.includes?(fqcn.split(".").last) })
      missing = supported.reject { |fqcn| extra.includes?(fqcn) || SCOPE_EXCLUDED.includes?(fqcn.split(".").last) }
      if warn_missing && (warning = uninstalled_warning(missing))
        STDERR.puts(warning)
      end
      names.concat(extra)
    end

    # The names are mostly legacy spellings of modules the scope already
    # carries under their installed FQCNs, and the line was long enough to
    # drown out real warnings - only the count is actionable. The JSON
    # listing asks for no warning at all: its stderr is echoed into a
    # caller's console (krikri-loop's), where the count is noise.
    def self.uninstalled_warning(missing : Array(String)) : String?
      return if missing.empty?
      "warning: #{missing.size} supported module(s) not installed"
    end

    private def discover_module_names : Array(String)
      listing = self.class.fetch_module_listing
      return listing.as_h.keys.sort! if @all_modules

      self.class.names_from_listing(listing, @supported_community)
    end

    private def scan_module(name : String) : ModuleSchema?
      result = Cmd.run("ansible-doc", ["-j", "-t", "module", name])
      return unless Cmd.success?(result)

      doc = JSON.parse(result.stdout).as_h[name]?.try(&.as_h?).try(&.["doc"]?).try(&.as_h?)
      return unless doc

      module_name = doc["module"]?.try(&.as_s?) || name
      collection = doc["collection"]?.try(&.as_s?) || "ansible.builtin"
      schema = ModuleSchema.new(module_name, collection)

      doc["options"]?.try(&.as_h?).try do |options|
        options.each do |option_name, option|
          option.as_h?.try { |opt_hash| schema.options[option_name] = build_option(option_name, opt_hash) }
        end
      end

      filename = doc["filename"]?.try(&.as_s?)
      apply_constraints!(schema, filename) if filename

      schema
    end

    private def build_option(name : String, option : Hash(String, JSON::Any)) : OptionSchema
      suboptions = {} of String => OptionSchema
      option["suboptions"]?.try(&.as_h?).try do |nested|
        nested.each do |sub_name, sub_option|
          sub_option.as_h?.try { |sub_hash| suboptions[sub_name] = build_option(sub_name, sub_hash) }
        end
      end

      OptionSchema.new(
        name,
        option["type"]?.try(&.as_s?) || "str",
        option["choices"]?.try(&.as_a?).try(&.map(&.to_s)) || [] of String,
        option["required"]?.try(&.as_bool?) || false,
        option["default"]?,
        option["elements"]?.try(&.as_s?),
        suboptions
      )
    end

    private def apply_constraints!(schema : ModuleSchema, filename : String) : Nil
      result = Cmd.run("python3", ["-", filename], input: CONSTRAINT_EXTRACTOR)
      return unless Cmd.success?(result)

      constraints = JSON.parse(result.stdout).as_h?
      return unless constraints

      schema.mutually_exclusive = string_groups(constraints["mutually_exclusive"]?)
      schema.required_together = string_groups(constraints["required_together"]?)
      schema.required_one_of = string_groups(constraints["required_one_of"]?)
      schema.required_if = constraints["required_if"]?.try(&.as_a?) || [] of JSON::Any
    rescue JSON::ParseException
      # the extractor always prints valid JSON on success; a malformed
      # stdout means something upstream broke (e.g. python3 missing) —
      # leave constraints empty rather than fail the whole scan over it.
    end

    private def string_groups(value : JSON::Any?) : Array(Array(String))
      return [] of Array(String) unless value
      groups = value.as_a?
      return [] of Array(String) unless groups

      groups.compact_map do |group|
        elements = group.as_a?
        elements.try(&.compact_map(&.as_s?))
      end
    end
  end
end
