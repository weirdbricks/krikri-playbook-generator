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

    def initialize(@name, @type = "str", @choices = [] of String,
                   @required = false, @default = nil, @elements = nil)
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

    class ScanError < Exception
    end

    def initialize(@module_filter : Array(String)? = nil)
    end

    def scan : Array(ModuleSchema)
      names = @module_filter || discover_module_names
      names.compact_map { |name| scan_module(name) }
    end

    private def discover_module_names : Array(String)
      result = Cmd.run("ansible-doc", ["--list", "-j", "-t", "module"])
      raise ScanError.new("ansible-doc --list failed: #{result.stderr}") unless Cmd.success?(result)

      JSON.parse(result.stdout).as_h.keys
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
      OptionSchema.new(
        name,
        option["type"]?.try(&.as_s?) || "str",
        option["choices"]?.try(&.as_a?).try(&.map(&.to_s)) || [] of String,
        option["required"]?.try(&.as_bool?) || false,
        option["default"]?,
        option["elements"]?.try(&.as_s?)
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
