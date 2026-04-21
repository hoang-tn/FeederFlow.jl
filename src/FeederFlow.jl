module FeederFlow

using LinearAlgebra
using Logging
using Printf
using SparseArrays
using StaticArrays

include("types.jl")
include("utils.jl")
include("parser.jl")
include("ybus.jl")
include("loads.jl")
include("solver.jl")
include("regulator_post.jl")
include("switch_admittance_patch.jl")
include("precompile.jl")

export AnalysisBundle,
    BaseQuantities,
    BusPhase,
    BusSpec,
    CapacitorDevice,
    ComponentTable,
    DSSParseError,
    GeneratorDevice,
    LineCode,
    LineDevice,
    LoadDevice,
    LoadModel,
    NetworkModel,
    NoLoadResult,
    PowerFlowResult,
    Provenance,
    RegControl,
    SourceSpec,
    TerminalSpec,
    TransformerDevice,
    TransformerWinding,
    YBusModel,
    balanced_slack,
    build_load_model,
    build_load_reference_vectors,
    build_y,
    component_names,
    compute_bus_voltage_bases,
    compute_no_load,
    get_normalized_result,
    get_voltages_local_base,
    normalize_result_to_local_bases,
    normalize_voltage_to_bus_base,
    parse_file,
    patch_switch_admittance!,
    scaled_ybus_matrix,
    solve_case,
    solve_power_flow,
    switch_line_admittance,
    verify_switch_admittance_patch

end
