"""
Compare voltages from the power flow solver before and after regulator post-processing.

This script:
1. Solves power flow and gets raw voltages from the solver
2. Computes regulator secondary voltages
3. Compares what changes
"""

using FeederFlow
using Printf

function compare_voltages_before_after_regulator(dss_path::String; use_benchmark=:auto)
    println("=" ^ 80)
    println("Voltage Comparison: Before vs After Regulator Post-Processing")
    println("=" ^ 80)
    println("File: $dss_path")
    println()

    # Parse and build the network
    network = FeederFlow.parse_file(dss_path; use_benchmark)
    
    # Build Y-bus and solve
    ybus = FeederFlow.build_y(network)
    noload = FeederFlow.compute_no_load(ybus)
    loads = FeederFlow.build_load_model(network, ybus, noload)
    bundle = FeederFlow.AnalysisBundle(
        network, ybus, noload, loads,
        FeederFlow.PowerFlowResult(0, false, ComplexF64[], Dict{FeederFlow.BusPhase,ComplexF64}(), Float64[], Float64[], Float64[])
    )
    
    # Solve power flow (BEFORE regulator post-processing)
    raw_result = FeederFlow.solve_power_flow(bundle)
    
    println("Power Flow Solver Results:")
    println("  Iterations: $(raw_result.iterations)")
    println("  Converged: $(raw_result.converged)")
    println("  Final residual: $(isempty(raw_result.history) ? "N/A" : raw_result.history[end])")
    println()
    
    # Create bundle with raw result for regulator post-processing
    bundle_with_result = FeederFlow.AnalysisBundle(network, ybus, noload, loads, raw_result)
    
    # Compute regulator secondary voltages
    secondary_voltages = FeederFlow.compute_regulator_secondary_voltages(bundle_with_result)
    
    println("Regulator Post-Processing:")
    println("  Number of regulators: $(length(network.regulators))")
    println("  Secondary voltages computed: $(length(secondary_voltages))")
    println()
    
    if isempty(secondary_voltages)
        println("No secondary voltages were computed.")
        println("This means all regulator secondary buses are already in the Y-bus.")
        println("The solver voltages are the final voltages - no post-processing needed.")
        println()
        println("All bus voltages from solver (system-base per-unit):")
        println("-" ^ 80)
        println("$(rpad("Bus", 15)) $(rpad("Phase", 8)) $(rpad("|V| (pu)", 12)) $(rpad("Angle (deg)", 12))")
        println("-" ^ 80)
        for (bp, v) in sort(collect(raw_result.phase_voltages), by=x->(x[1].bus, x[1].phase))
            println("$(rpad(bp.bus, 15)) $(rpad(string(bp.phase), 8)) $(rpad(@sprintf("%.6f", abs(v)), 12)) $(rpad(@sprintf("%.4f", rad2deg(angle(v))), 12))")
        end
    else
        println("Secondary voltages computed (NOT in Y-bus):")
        println("-" ^ 80)
        println("$(rpad("Bus", 15)) $(rpad("Phase", 8)) $(rpad("|V| (pu)", 12)) $(rpad("Angle (deg)", 12))")
        println("-" ^ 80)
        for (bp, v) in sort(collect(secondary_voltages), by=x->(x[1].bus, x[1].phase))
            println("$(rpad(bp.bus, 15)) $(rpad(string(bp.phase), 8)) $(rpad(@sprintf("%.6f", abs(v)), 12)) $(rpad(@sprintf("%.4f", rad2deg(angle(v))), 12))")
        end
        println()
        
        # Show comparison with primary voltages
        println("Primary vs Secondary Voltage Comparison:")
        println("-" ^ 80)
        println("$(rpad("Regulator", 15)) $(rpad("Phase", 8)) $(rpad("|V_primary|", 12)) $(rpad("|V_secondary|", 14)) $(rpad("Ratio", 10))")
        println("-" ^ 80)
        
        for regulator in network.regulators
            length(regulator.windings) >= 2 || continue
            w1 = regulator.windings[1]
            w2 = regulator.windings[2]
            primary_bus = w1.bus.bus
            secondary_bus = w2.bus.bus
            
            for phase in w1.bus.phases
                bp_primary = FeederFlow.BusPhase(primary_bus, phase)
                bp_secondary = FeederFlow.BusPhase(secondary_bus, phase)
                
                v_primary = get(raw_result.phase_voltages, bp_primary, nothing)
                v_secondary = get(secondary_voltages, bp_secondary, nothing)
                
                if v_primary !== nothing && v_secondary !== nothing
                    ratio = abs(v_secondary) / abs(v_primary)
                    println("$(rpad(regulator.name, 15)) $(rpad(string(phase), 8)) $(rpad(@sprintf("%.6f", abs(v_primary)), 12)) $(rpad(@sprintf("%.6f", abs(v_secondary)), 14)) $(rpad(@sprintf("%.4f", ratio), 10))")
                end
            end
        end
    end
    
    println()
    println("=" ^ 80)
    println("Summary:")
    println("  Total buses in Y-bus: $(length(ybus.all_order))")
    println("  Buses with solved voltages: $(length(raw_result.phase_voltages))")
    println("  Additional buses from regulator post: $(length(secondary_voltages))")
    println("=" ^ 80)
    
    return raw_result, secondary_voltages
end

# Run comparison
if length(ARGS) >= 1
    global dss_path = ARGS[1]
    compare_voltages_before_after_regulator(dss_path)
else
    # Default: try IEEE 37
    dss_path = joinpath(@__DIR__, "examples", "grids", "37_bus", "ieee37.dss")
    if isfile(dss_path)
        compare_voltages_before_after_regulator(dss_path)
    end
end
