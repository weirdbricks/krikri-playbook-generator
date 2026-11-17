require "json"
require "yaml"
require "./cmd"
require "./overrides"

module KrikriPlaybookGenerator
  class LibraryProbeError < Exception
  end

  # A generated custom module under a playbook's `library/` directory plus
  # the task arguments that invoke it. `target` is what the module probes
  # (an `ansible.module_utils` import path, or a custom-module shape);
  # `deliberate_failure` marks a probe whose reference-side run is supposed
  # to fail, so the happy-path quality metric leaves it out.
  record LibraryProbe, module_name : String, shape : String, target : String?,
    source : String, args : Hash(String, YAML::Any) = {} of String => YAML::Any,
    deliberate_failure : Bool = false

  # The `ansible.module_utils` import surface of the installed ansible-core:
  # the tree krikri's Python compatibility shim is measured against, which
  # no installed-module schema scan can reach.
  module ModuleUtilsSurface
    PREFIX       = "ansible.module_utils."
    PROBE_PREFIX = "kpg_mu_"

    # Private submodules (`_internal`, `_embed`, ...) are not import
    # surface for custom modules - ansible itself says not to import them -
    # so `all` leaves them out. An explicitly named one is still probed.
    ENUMERATOR = <<-PYTHON
      import json, os, pkgutil
      import ansible.module_utils
      root = os.path.dirname(ansible.module_utils.__file__)
      names = [m.name for m in pkgutil.walk_packages([root], prefix="ansible.module_utils.")]
      names = [n for n in names if not any(p.startswith("_") for p in n.split("."))]
      print(json.dumps(sorted(names)))
      PYTHON

    # Every non-private module under `ansible.module_utils` on the python3
    # that backs the reference engine, sorted.
    def self.names : Array(String)
      result = Cmd.run("python3", ["-"], input: ENUMERATOR, timeout: 120.0)
      unless Cmd.success?(result)
        raise LibraryProbeError.new("enumerating ansible.module_utils failed: #{result.stderr.strip}")
      end

      parsed = JSON.parse(result.stdout).as_a?
      raise LibraryProbeError.new("ansible.module_utils listing was not a JSON array") unless parsed

      parsed.compact_map(&.as_s?).sort!
    rescue JSON::ParseException
      raise LibraryProbeError.new("ansible.module_utils listing was not valid JSON")
    rescue IO::Error
      raise LibraryProbeError.new("could not run python3 to enumerate ansible.module_utils")
    end

    # The requested names split into the ones to probe and the ones the
    # overrides data marks as needing an optional third-party library (with
    # the reason, so the caller can report the skip). `all` expands to the
    # whole public surface; an explicit name wins even when it is private.
    # Unknown explicit names are kept so ansible can report the miss
    # instead of this tool silently dropping it.
    def self.select(requested : Array(String),
                    overrides : Overrides) : {Array(String), Array({String, String})}
      names = requested.includes?("all") ? names() : [] of String
      names += requested.reject { |entry| entry == "all" }
      names.uniq!

      kept = [] of String
      skipped = [] of {String, String}
      names.each do |name|
        if reason = overrides.module_utils_skip_reason(name)
          skipped << {name, reason}
        else
          kept << name
        end
      end
      {kept, skipped}
    end

    # The public names each requested module exposes on the reference
    # ansible-core, so a probe covers missing NAMES as well as a missing
    # module. A module that cannot be imported here reports its error and
    # gets an import-only probe (the reference side then records the
    # harness gap).
    SYMBOLS = <<-PYTHON
      import importlib, json, sys
      result = {}
      for name in sys.argv[1:]:
          try:
              module = importlib.import_module(name)
              result[name] = sorted(n for n in dir(module) if not n.startswith("_"))
          except Exception as exc:
              result[name] = {"error": "%s: %s" % (type(exc).__name__, exc)}
      print(json.dumps(result))
      PYTHON

    def self.symbols(names : Array(String)) : Hash(String, Array(String))
      return {} of String => Array(String) if names.empty?

      result = Cmd.run("python3", ["-"] + names, input: SYMBOLS, timeout: 120.0)
      unless Cmd.success?(result)
        raise LibraryProbeError.new("enumerating ansible.module_utils names failed: #{result.stderr.strip}")
      end

      parsed = JSON.parse(result.stdout).as_h?
      raise LibraryProbeError.new("ansible.module_utils name listing was not a JSON object") unless parsed

      mapping = {} of String => Array(String)
      parsed.each do |name, entry|
        if list = entry.as_a?
          mapping[name.to_s] = list.compact_map(&.as_s?)
        end
      end
      mapping
    rescue JSON::ParseException
      raise LibraryProbeError.new("ansible.module_utils name listing was not valid JSON")
    end

    # One generated module per import path: the module statically imports
    # the target (AnsiballZ only bundles module_utils it can see in the
    # source), then exits with a fixed result naming what was imported.
    # Its public names are imported too, so a missing symbol is a finding
    # of the same run instead of surfacing when a production module first
    # imports it.
    def self.probes(names : Array(String)) : Array(LibraryProbe)
      exposed = symbols(names)
      names.map do |name|
        LibraryProbe.new(probe_name(name), "module-utils", name, source(name, exposed[name]? || [] of String))
      end
    end

    def self.probe_name(name : String) : String
      PROBE_PREFIX + name.sub(PREFIX, "").gsub(/[^A-Za-z0-9_]/, "_")
    end

    def self.source(name : String, exposed : Array(String) = [] of String) : String
      imports = exposed.each_slice(20).map do |slice|
        "from #{name} import #{slice.join(", ")}"
      end.to_a
      import_block = imports.empty? ? "" : imports.join("\n")
      <<-PYTHON
        #!/usr/bin/python
        from ansible.module_utils.basic import AnsibleModule
        import #{name} as kpg_probe_target
        #{import_block}

        def main():
            module = AnsibleModule(argument_spec={}, supports_check_mode=True)
            module.exit_json(changed=False, target="#{name}", module_name=kpg_probe_target.__name__, names=#{exposed.size})

        if __name__ == '__main__':
            main()
        PYTHON
    end
  end

  module ModuleUtilsShapes
    def self.parse_list(value : String) : Array(String)?
      values = value.split(',').map(&.strip).reject(&.empty?)
      return [] of String if values == ["none"]
      return if values.empty?

      values.uniq
    end
  end

  # The custom-module shapes: the AnsibleModule surfaces a hand-written
  # module in a role's library/ exposes (argument specs, check-mode
  # support, warning and error plumbing, verbosity, imports). Each shape is
  # one generated module plus the task arguments that drive it.
  enum LibraryShape
    CheckMode
    NoCheck
    Required
    Choices
    MutuallyExclusive
    RequiredOneOf
    NoLog
    Warnings
    FailTraceback
    Verbosity
    DictArg
    CommonImport
    CollectionImport

    def self.parse(value : String) : LibraryShape?
      LibraryShapes.names[value]?
    end

    def label : String
      to_s.gsub(/([a-z])([A-Z])/, "\\1-\\2").downcase
    end

    # Shapes whose reference-side run fails by design (an argument spec
    # rejection or an explicit fail_json). Their failure IS the comparison
    # under test, so Triage keeps them out of the quality metric even when
    # the library row itself is not excluded.
    def deliberate_failure? : Bool
      required? || choices? || mutually_exclusive? || required_one_of? || fail_traceback?
    end
  end

  module LibraryShapes
    KINDS = %w[check-mode no-check required choices mutually-exclusive required-one-of
      no-log warnings fail-traceback verbosity dict-arg common-import collection-import]

    @@names : Hash(String, LibraryShape)?

    def self.names : Hash(String, LibraryShape)
      @@names ||= {
        "check-mode"         => LibraryShape::CheckMode,
        "no-check"           => LibraryShape::NoCheck,
        "required"           => LibraryShape::Required,
        "choices"            => LibraryShape::Choices,
        "mutually-exclusive" => LibraryShape::MutuallyExclusive,
        "required-one-of"    => LibraryShape::RequiredOneOf,
        "no-log"             => LibraryShape::NoLog,
        "warnings"           => LibraryShape::Warnings,
        "fail-traceback"     => LibraryShape::FailTraceback,
        "verbosity"          => LibraryShape::Verbosity,
        "dict-arg"           => LibraryShape::DictArg,
        "common-import"      => LibraryShape::CommonImport,
        "collection-import"  => LibraryShape::CollectionImport,
      }
    end

    def self.parse_list(value : String) : Array(String)?
      values = value.split(',').map(&.strip).reject(&.empty?)
      return [] of String if values == ["none"]
      return KINDS.dup if values == ["all"]
      return if values.empty? || !values.all? { |entry| KINDS.includes?(entry) }

      values.uniq
    end

    def self.parse(value : String) : LibraryShape?
      LibraryShape.parse(value)
    end

    def self.probes(shapes : Array(LibraryShape)) : Array(LibraryProbe)
      shapes.map do |shape|
        name = "kpg_lib_#{shape.label.tr("-", "_")}"
        LibraryProbe.new(name, "library", shape.label, source(shape), args(shape),
          deliberate_failure: shape.deliberate_failure?)
      end
    end

    # The generated Python source for each custom-module shape. Kept as
    # data rather than a per-shape method so a new probe is one entry.
    SOURCES = {
      LibraryShape::CheckMode => <<-PYTHON,
          #!/usr/bin/python
          from ansible.module_utils.basic import AnsibleModule

          def main():
              module = AnsibleModule(argument_spec={}, supports_check_mode=True)
              module.exit_json(changed=True, check_mode=module.check_mode)

          if __name__ == '__main__':
              main()
        PYTHON
      LibraryShape::NoCheck => <<-PYTHON,
          #!/usr/bin/python
          from ansible.module_utils.basic import AnsibleModule

          def main():
              module = AnsibleModule(argument_spec={})
              module.exit_json(changed=False, ran=True)

          if __name__ == '__main__':
              main()
        PYTHON
      LibraryShape::Required => <<-PYTHON,
          #!/usr/bin/python
          from ansible.module_utils.basic import AnsibleModule

          def main():
              module = AnsibleModule(argument_spec={"name": {"type": "str", "required": True}})
              module.exit_json(changed=False, name=module.params["name"])

          if __name__ == '__main__':
              main()
        PYTHON
      LibraryShape::Choices => <<-PYTHON,
          #!/usr/bin/python
          from ansible.module_utils.basic import AnsibleModule

          def main():
              module = AnsibleModule(argument_spec={"mode_choice": {"type": "str", "choices": ["one", "two"]}})
              module.exit_json(changed=False, mode_choice=module.params["mode_choice"])

          if __name__ == '__main__':
              main()
        PYTHON
      LibraryShape::MutuallyExclusive => <<-PYTHON,
          #!/usr/bin/python
          from ansible.module_utils.basic import AnsibleModule

          def main():
              module = AnsibleModule(argument_spec={"left": {"type": "str"}, "right": {"type": "str"}},
                                     mutually_exclusive=[["left", "right"]])
              module.exit_json(changed=False, left=module.params["left"], right=module.params["right"])

          if __name__ == '__main__':
              main()
        PYTHON
      LibraryShape::RequiredOneOf => <<-PYTHON,
          #!/usr/bin/python
          from ansible.module_utils.basic import AnsibleModule

          def main():
              module = AnsibleModule(argument_spec={"alpha": {"type": "str"}, "beta": {"type": "str"}},
                                     required_one_of=[["alpha", "beta"]])
              module.exit_json(changed=False, alpha=module.params["alpha"], beta=module.params["beta"])

          if __name__ == '__main__':
              main()
        PYTHON
      LibraryShape::NoLog => <<-PYTHON,
          #!/usr/bin/python
          from ansible.module_utils.basic import AnsibleModule

          def main():
              module = AnsibleModule(argument_spec={"secret": {"type": "str", "no_log": True}})
              module.exit_json(changed=False, has_secret=bool(module.params["secret"]))

          if __name__ == '__main__':
              main()
        PYTHON
      LibraryShape::Warnings => <<-PYTHON,
          #!/usr/bin/python
          from ansible.module_utils.basic import AnsibleModule

          def main():
              module = AnsibleModule(argument_spec={})
              module.exit_json(changed=False, warnings=["kpg synthetic warning"])

          if __name__ == '__main__':
              main()
        PYTHON
      LibraryShape::FailTraceback => <<-PYTHON,
          #!/usr/bin/python
          import traceback
          from ansible.module_utils.basic import AnsibleModule

          def main():
              module = AnsibleModule(argument_spec={})
              try:
                  raise RuntimeError("kpg synthetic traceback")
              except RuntimeError:
                  module.fail_json(msg="kpg synthetic failure", exception=traceback.format_exc())

          if __name__ == '__main__':
              main()
        PYTHON
      LibraryShape::Verbosity => <<-PYTHON,
          #!/usr/bin/python
          from ansible.module_utils.basic import AnsibleModule

          def main():
              module = AnsibleModule(argument_spec={})
              module.exit_json(changed=False, verbosity=module._verbosity)

          if __name__ == '__main__':
              main()
        PYTHON
      LibraryShape::DictArg => <<-PYTHON,
          #!/usr/bin/python
          from ansible.module_utils.basic import AnsibleModule

          def main():
              module = AnsibleModule(argument_spec={
                  "config": {"type": "dict", "required": True,
                             "options": {"name": {"type": "str", "required": True}}},
              })
              module.exit_json(changed=False, name=module.params["config"]["name"])

          if __name__ == '__main__':
              main()
        PYTHON
      LibraryShape::CommonImport => <<-PYTHON,
          #!/usr/bin/python
          from ansible.module_utils.basic import AnsibleModule
          from ansible.module_utils.common.text.converters import to_bytes, to_native, to_text

          def main():
              module = AnsibleModule(argument_spec={})
              module.exit_json(changed=False, text=to_text(b"kpg"), native=to_native(b"kpg"),
                               length=len(to_bytes("kpg")))

          if __name__ == '__main__':
              main()
        PYTHON
      LibraryShape::CollectionImport => <<-PYTHON,
          #!/usr/bin/python
          from ansible.module_utils.basic import AnsibleModule
          from ansible_collections.community.general.plugins.module_utils.version import LooseVersion

          def main():
              module = AnsibleModule(argument_spec={})
              module.exit_json(changed=False, loose_version=LooseVersion("1.2.3").vstring,
                               greater=LooseVersion("2.0") > LooseVersion("1.0"))

          if __name__ == '__main__':
              main()
        PYTHON
    }

    # The arguments one shape's task passes. A shape that must trip its
    # argument spec passes exactly the values that trip it (and nothing
    # else), so the error is the spec's own, not a typo in the probe.
    ARGS = {
      LibraryShape::Choices           => {"mode_choice" => YAML::Any.new("three")},
      LibraryShape::MutuallyExclusive => {"left" => YAML::Any.new("one"), "right" => YAML::Any.new("two")},
      LibraryShape::NoLog             => {"secret" => YAML::Any.new("kpg-secret-value")},
      LibraryShape::DictArg           => {"config" => YAML::Any.new({YAML::Any.new("name") => YAML::Any.new("kpg")})},
    }

    def self.args(shape : LibraryShape) : Hash(String, YAML::Any)
      ARGS[shape]? || {} of String => YAML::Any
    end

    def self.source(shape : LibraryShape) : String
      body = SOURCES[shape]? || raise LibraryProbeError.new("unknown library shape #{shape}")
      body.lines.map { |line| line.starts_with?("  ") ? line[2..] : line }.join('\n') + "\n"
    end
  end
end
