using Test
using FeederFlow

@testset "FeederFlow correctness" begin
    include("test_support.jl")
    include("test_opendss_helpers.jl")
    include("test_parser_units.jl")
    include("test_parser_correctness.jl")
    include("test_parser_behaviors.jl")
    include("test_240_bus.jl")
    include("test_ybus_correctness.jl")
    include("test_regulator_yprim.jl")
    include("test_component_admittance_parity.jl")
    include("test_pmd_parser_pu.jl")
    include("test_power_flow_correctness_rigorous.jl")
    include("test_regulator_secondary.jl")
    include("test_line_sanity.jl")
    include("test_switch_admittance_patch.jl")
    include("test_load_reference_vectors.jl")
    include("test_cost_coefficients.jl")
    # WIP: include("test_line_geometry.jl") when geometry parity is stable.
end

#How to run: julia --project=. test\runtests.jl
# cd "C:\Users\hoang\OneDrive - Massachusetts Institute of Technology\1. MIT\2. Projects\4. Dist OPF\multiphase_modelling\FeederFlow.jl"; julia --project=. run_tests.jl
