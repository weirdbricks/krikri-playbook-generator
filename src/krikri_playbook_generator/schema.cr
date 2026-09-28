require "yaml"

module KrikriPlaybookGenerator
  # A single option in a module's argument_spec, normalized from either a
  # scraped `DOCUMENTATION` YAML block or a vendored snapshot.
  class OptionSchema
    property name : String
    property type : String
    property choices : Array(String)
    property? required : Bool
    property default : YAML::Any?
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
    property required_if : Array(Array(YAML::Any))
    property required_one_of : Array(Array(String))

    def initialize(@module_name, @collection = "ansible.builtin",
                   @options = {} of String => OptionSchema,
                   @mutually_exclusive = [] of Array(String),
                   @required_together = [] of Array(String),
                   @required_if = [] of Array(YAML::Any),
                   @required_one_of = [] of Array(String))
    end
  end

  # Scans installed ansible-core + collection Python module source for
  # `DOCUMENTATION` YAML blocks and normalizes them into ModuleSchema.
  #
  # TODO: locate module source (ansible-core site-packages + installed
  # collections), extract the `DOCUMENTATION = r"""..."""` block, parse as
  # YAML, and map into ModuleSchema/OptionSchema. See open question #1 in
  # KRIKRI_PLAYBOOK_GENERATOR.md re: scrape-installed vs vendored-snapshot.
  class SchemaScanner
    def initialize(@module_filter : Array(String)? = nil)
    end

    def scan : Array(ModuleSchema)
      raise "not yet implemented: SchemaScanner#scan"
    end
  end
end
