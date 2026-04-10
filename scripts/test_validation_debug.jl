#!/usr/bin/env julia

"""
DEBUG VERSION: Validation test with extensive logging to identify hang points.
"""

using Pkg
Pkg.activate(normpath(joinpath(@__DIR__, "..")))

using FeederFlow
using Logging
using Printf
using Dates

# Set up detailed logging
global_logger(ConsoleLogger(stderr, Logging.Debug))

println("="^80)
println("DEBUG VALIDATION TEST - Identifying hang point")
println("="^80)
println("Start time: ", now())
println()

# Include validation runner
println("[1/10] Loading validation_runner.jl...")
flush(stdout)
include(joinpath(@__DIR__, "..", "src", "validation_runner.jl"))
println("  ✓ Loaded successfully")
println()

# Get network config
println("[2/10] Loading network registry...")
flush(stdout)
registry = get_network_registry()
println("  ✓ Found $(length(registry)) networks")
println()

# Select IEEE 13 (simplest network, no regulators)
println("[3/10] Getting IEEE 13 configuration...")
flush(stdout)
network_config = get_network_config("ieee13")
if network_config === nothing
    error("Failed to load IEEE 13 network")
end
println("  ✓ Network: $(network_config.name)")
println("  ✓ Path: $(network_config.dss_path)")
println("  ✓ Has regulators: $(network_config.has_regulators)")
println()

# Parse network
println("[4/10] Parsing network...")
flush(stdout)
@time network = FeederFlow.parse_file(network_config.dss_path)
println("  ✓ Loaded $(length(network.loads)) loads")
println("  ✓ Loaded $(length(network.regulators)) regulators")
println()

# Generate scenarios (MINIMAL - just 1)
println("[5/10] Generating 1 scenario...")
flush(stdout)
@time scenarios = generate_all_scenarios(
    network;
    n_random_loads=1,
    n_random_taps=0,
    load_seed=12345,
    tap_seed=54321
)
println("  ✓ Generated $(length(scenarios)) scenarios")
for (i, sc) in enumerate(scenarios)
    println("    $i. $(sc.id): $(sc.description)")
end
println()

# Create temp directory
println("[6/10] Creating temp directory...")
flush(stdout)
temp_dir = mktempdir(; prefix="debug_validation_")
println("  ✓ Temp dir: $temp_dir")
println()

# Run FIRST scenario only
println("[7/10] Running first scenario...")
flush(stdout)
scenario = scenarios[1]
println("  Scenario: $(scenario.id)")
println("  Load scale: $(scenario.load_scale)")
println("  Load variations: $(length(scenario.load_variations))")
println("  Tap positions: $(length(scenario.tap_positions))")
println()

println("[8/10] Running FeederFlow...")
flush(stdout)
try
    @time ff_converged, ff_voltages = run_feederflow_scenario(
        network_config.dss_path,
        scenario,
        temp_dir
    )
    println("  ✓ FeederFlow converged: $ff_converged")
    println("  ✓ FeederFlow voltages: $(length(ff_voltages))")
catch e
    println("  ✗ FeederFlow failed: $e")
    @error "FeederFlow error" exception=(e, catch_backtrace())
end
println()

println("[9/10] Running OpenDSS...")
flush(stdout)
try
    @time dss_converged, dss_voltages = run_opendss_scenario(
        network_config.dss_path,
        scenario,
        temp_dir
    )
    println("  ✓ OpenDSS converged: $dss_converged")
    println("  ✓ OpenDSS voltages: $(length(dss_voltages))")
catch e
    println("  ✗ OpenDSS failed: $e")
    @error "OpenDSS error" exception=(e, catch_backtrace())
end
println()

# Cleanup
println("[10/10] Cleaning up...")
flush(stdout)
rm(temp_dir; recursive=true, force=true)
println("  ✓ Removed temp directory")
println()

println("="^80)
println("DEBUG TEST COMPLETE")
println("End time: ", now())
println("="^80)
