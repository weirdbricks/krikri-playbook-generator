require "random/pcg32"

module KrikriPlaybookGenerator
  # The structural include/import forms real playbooks use: a
  # playbook-relative include whose child includes another file relatively,
  # a role included with task-level vars, a role whose own tasks include
  # further files, looped includes, and the play-level `import_playbook`
  # directive (which a task list cannot express). Both spellings (short and
  # FQCN) appear across the shapes, so a fix verified on one cannot hide a
  # gap in the other.
  enum IncludeShape
    Off
    Relative
    RoleVars
    RoleInner
    LoopTasks
    LoopRole
    ImportPlaybook
    ImportRole

    def self.parse(value : String) : IncludeShape?
      case value
      when "off"             then Off
      when "relative"        then Relative
      when "role-vars"       then RoleVars
      when "role-inner"      then RoleInner
      when "loop-tasks"      then LoopTasks
      when "loop-role"       then LoopRole
      when "import-playbook" then ImportPlaybook
      when "import-role"     then ImportRole
      end
    end

    def label : String
      to_s.gsub(/([a-z])([A-Z])/, "\\1-\\2").downcase
    end
  end

  module IncludeShapes
    KINDS = %w[relative role-vars role-inner loop-tasks loop-role
      import-playbook import-role]

    def self.parse_list(value : String) : Array(String)?
      values = value.split(',').map(&.strip)
      return [] of String if values == ["none"]
      return if values.empty? || !values.all? { |entry| KINDS.includes?(entry) }

      values.uniq
    end
  end

  # Deterministic per seed, with its own RNG so drawing an include shape
  # never shifts the other draws.
  class IncludeShapeSampler
    def initialize(@seed : Int32, @kinds : Array(String) = IncludeShapes::KINDS)
      @rng = Random::PCG32.new(@seed.to_u64 + 4)
    end

    def empty? : Bool
      @kinds.empty?
    end

    def sample : IncludeShape
      return IncludeShape::Off if @kinds.empty?

      IncludeShape.parse(@kinds.sample(@rng)) || IncludeShape::Off
    end
  end
end
