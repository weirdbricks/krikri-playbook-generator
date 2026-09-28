require "./schema"
require "random/pcg32"

module KrikriPlaybookGenerator
  enum ChaosKind
    Typo
    Hallucinate
    WrongType
    BadChoice
    ViolateConstraint
  end

  # One generated task's arguments plus, for chaos-mode tasks, which
  # slots were mutated and how — carried through to triage so a
  # divergence can always be traced back to a specific mutation kind.
  class GeneratedTask
    property module_name : String
    property args : Hash(String, YAML::Any)
    property mutations : Array({String, ChaosKind})

    def initialize(@module_name, @args = {} of String => YAML::Any,
                   @mutations = [] of {String, ChaosKind})
    end

    def chaos? : Bool
      !mutations.empty?
    end
  end

  # Given a module's schema, an RNG seed, and a chaos-percentage, builds
  # random-but-schema-aware argument sets: mostly valid ("happy path"),
  # with each option-slot independently eligible for a chaos mutation at
  # probability `chaos_percentage`.
  class Generator
    def initialize(@seed : Int32, @chaos_percentage : Float64 = 0.0,
                   @chaos_kinds : Array(ChaosKind) = ChaosKind.values)
      @rng = Random::PCG32.new(@seed.to_u64)
    end

    def generate(schema : ModuleSchema, count : Int32) : Array(GeneratedTask)
      raise "not yet implemented: Generator#generate"
    end
  end
end
