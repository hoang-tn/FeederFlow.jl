"""
Validation statistics and error metrics.

Functions for computing error metrics between FeederFlow and OpenDSS results,
and for aggregating statistics across scenarios.
"""

using Statistics
using Printf
using CSV
using DataFrames
using JSON3
using Dates

"""
    ErrorMetrics

Per-bus-phase error metrics between FeederFlow and OpenDSS.
"""
struct ErrorMetrics
    bus_phase::String
    abs_voltage_error::Float64      # |V_ff - V_dss|
    mag_voltage_error::Float64      # ||V_ff| - |V_dss||
    angle_error_deg::Float64        # angle difference in degrees
    feederflow_voltage::ComplexF64
    opendss_voltage::ComplexF64
end

"""
    ScenarioSummary

Aggregated statistics for a single scenario.
"""
struct ScenarioSummary
    scenario_id::String
    n_buses::Int
    feederflow_converged::Bool
    opendss_converged::Bool
    max_abs_error::Float64
    mean_abs_error::Float64
    std_abs_error::Float64
    p95_abs_error::Float64
    max_mag_error::Float64
    mean_mag_error::Float64
    max_angle_error::Float64
    mean_angle_error::Float64
end

"""
    compute_error_metrics(feederflow_voltages::Dict{String,ComplexF64},
                         opendss_voltages::Dict{String,ComplexF64})

Compute per-bus-phase error metrics between FeederFlow and OpenDSS results.

Returns Vector{ErrorMetrics}.
"""
function compute_error_metrics(feederflow_voltages::Dict{String,ComplexF64},
                               opendss_voltages::Dict{String,ComplexF64})
    # Find shared bus-phases
    shared_keys = intersect(keys(feederflow_voltages), keys(opendss_voltages))
    
    metrics = ErrorMetrics[]
    
    for key in sort!(collect(shared_keys))
        v_ff = feederflow_voltages[key]
        v_dss = opendss_voltages[key]
        
        # Compute errors
        abs_err = abs(v_ff - v_dss)
        mag_err = abs(abs(v_ff) - abs(v_dss))
        angle_err = wrap_angle_diff_deg(v_ff, v_dss)
        
        push!(metrics, ErrorMetrics(
            key,
            abs_err,
            mag_err,
            angle_err,
            v_ff,
            v_dss
        ))
    end
    
    return metrics
end

"""
    wrap_angle_diff_deg(a::ComplexF64, b::ComplexF64)

Compute angle difference in degrees, wrapped to [-180, 180].
"""
function wrap_angle_diff_deg(a::ComplexF64, b::ComplexF64)
    diff = rad2deg(angle(a) - angle(b))
    return abs(mod(diff + 180, 360) - 180)
end

"""
    aggregate_scenario_metrics(scenario_id::String,
                               metrics::Vector{ErrorMetrics},
                               feederflow_converged::Bool,
                               opendss_converged::Bool)

Aggregate error metrics for a single scenario into summary statistics.

Returns ScenarioSummary.
"""
function aggregate_scenario_metrics(scenario_id::String,
                                   metrics::Vector{ErrorMetrics},
                                   feederflow_converged::Bool,
                                   opendss_converged::Bool)
    if isempty(metrics)
        return ScenarioSummary(
            scenario_id, 0, feederflow_converged, opendss_converged,
            NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN
        )
    end
    
    abs_errors = [m.abs_voltage_error for m in metrics]
    mag_errors = [m.mag_voltage_error for m in metrics]
    angle_errors = [m.angle_error_deg for m in metrics]
    
    return ScenarioSummary(
        scenario_id,
        length(metrics),
        feederflow_converged,
        opendss_converged,
        maximum(abs_errors),
        mean(abs_errors),
        std(abs_errors),
        isempty(abs_errors) ? NaN : quantile(abs_errors, 0.95),
        maximum(mag_errors),
        mean(mag_errors),
        maximum(angle_errors),
        mean(angle_errors)
    )
end

"""
    compute_network_statistics(summaries::Vector{ScenarioSummary})

Compute aggregate statistics across all scenarios for a network.

Returns NamedTuple with summary statistics.
"""
function compute_network_statistics(summaries::Vector{ScenarioSummary})
    if isempty(summaries)
        return (
            n_scenarios = 0,
            n_converged_both = 0,
            n_converged_ff_only = 0,
            n_converged_dss_only = 0,
            n_failed_both = 0,
            max_abs_error = NaN,
            mean_abs_error = NaN,
            median_abs_error = NaN,
            std_abs_error = NaN,
            p95_abs_error = NaN,
            p99_abs_error = NaN
        )
    end
    
    # Convergence statistics
    n_converged_both = count(s -> s.feederflow_converged && s.opendss_converged, summaries)
    n_converged_ff_only = count(s -> s.feederflow_converged && !s.opendss_converged, summaries)
    n_converged_dss_only = count(s -> !s.feederflow_converged && s.opendss_converged, summaries)
    n_failed_both = count(s -> !s.feederflow_converged && !s.opendss_converged, summaries)
    
    # Extract max errors from each scenario
    max_abs_errors = [s.max_abs_error for s in summaries if isfinite(s.max_abs_error)]
    
    if isempty(max_abs_errors)
        return (
            n_scenarios = length(summaries),
            n_converged_both = n_converged_both,
            n_converged_ff_only = n_converged_ff_only,
            n_converged_dss_only = n_converged_dss_only,
            n_failed_both = n_failed_both,
            max_abs_error = NaN,
            mean_abs_error = NaN,
            median_abs_error = NaN,
            std_abs_error = NaN,
            p95_abs_error = NaN,
            p99_abs_error = NaN
        )
    end
    
    return (
        n_scenarios = length(summaries),
        n_converged_both = n_converged_both,
        n_converged_ff_only = n_converged_ff_only,
        n_converged_dss_only = n_converged_dss_only,
        n_failed_both = n_failed_both,
        max_abs_error = maximum(max_abs_errors),
        mean_abs_error = mean(max_abs_errors),
        median_abs_error = median(max_abs_errors),
        std_abs_error = std(max_abs_errors),
        p95_abs_error = quantile(max_abs_errors, 0.95),
        p99_abs_error = quantile(max_abs_errors, 0.99)
    )
end

"""
    print_scenario_summary(summary::ScenarioSummary)

Print human-readable summary of a scenario's error metrics.
"""
function print_scenario_summary(summary::ScenarioSummary)
    @printf("%-40s | buses=%4d | FF=%s DSS=%s | max|ΔV|=%.6f | mean|ΔV|=%.6f | p95=%.6f\n",
            summary.scenario_id,
            summary.n_buses,
            summary.feederflow_converged ? "✓" : "✗",
            summary.opendss_converged ? "✓" : "✗",
            summary.max_abs_error,
            summary.mean_abs_error,
            summary.p95_abs_error)
end

"""
    print_network_statistics(network_name::String, stats::NamedTuple)

Print human-readable network-level statistics.
"""
function print_network_statistics(network_name::String, stats::NamedTuple)
    println("\n=== $network_name Network Statistics ===")
    @printf("Scenarios: %d total\n", stats.n_scenarios)
    @printf("Convergence: %d both, %d FF-only, %d DSS-only, %d failed\n",
            stats.n_converged_both, stats.n_converged_ff_only,
            stats.n_converged_dss_only, stats.n_failed_both)
    @printf("Max |ΔV|:    %.8f pu\n", stats.max_abs_error)
    @printf("Mean |ΔV|:   %.8f pu\n", stats.mean_abs_error)
    @printf("Median |ΔV|: %.8f pu\n", stats.median_abs_error)
    @printf("Std |ΔV|:    %.8f pu\n", stats.std_abs_error)
    @printf("95th %%ile:   %.8f pu\n", stats.p95_abs_error)
    @printf("99th %%ile:   %.8f pu\n", stats.p99_abs_error)
end

# ============================================================================
# CSV Export Functions
# ============================================================================

"""
    export_scenario_definitions(scenarios::Vector, output_path::String, network_name::String)

Export scenario definitions to CSV.
"""
function export_scenario_definitions(scenarios::Vector, output_path::String, network_name::String)
    df = DataFrame(
        network = String[],
        scenario_id = String[],
        description = String[],
        load_scale = Float64[],
        n_load_variations = Int[],
        n_tap_positions = Int[]
    )
    
    for scenario in scenarios
        push!(df, (
            network_name,
            scenario.id,
            scenario.description,
            scenario.load_scale,
            length(scenario.load_variations),
            length(scenario.tap_positions)
        ))
    end
    
    CSV.write(output_path, df)
    return df
end

"""
    export_raw_results(metrics::Vector{ErrorMetrics}, 
                      scenario_id::String,
                      network_name::String,
                      output_path::String;
                      append=false)

Export raw per-bus-phase error metrics to CSV.
"""
function export_raw_results(metrics::Vector{ErrorMetrics}, 
                           scenario_id::String,
                           network_name::String,
                           output_path::String;
                           append=false)
    df = DataFrame(
        network = String[],
        scenario_id = String[],
        bus_phase = String[],
        abs_voltage_error = Float64[],
        mag_voltage_error = Float64[],
        angle_error_deg = Float64[],
        feederflow_mag = Float64[],
        feederflow_angle = Float64[],
        opendss_mag = Float64[],
        opendss_angle = Float64[]
    )
    
    for m in metrics
        push!(df, (
            network_name,
            scenario_id,
            m.bus_phase,
            m.abs_voltage_error,
            m.mag_voltage_error,
            m.angle_error_deg,
            abs(m.feederflow_voltage),
            rad2deg(angle(m.feederflow_voltage)),
            abs(m.opendss_voltage),
            rad2deg(angle(m.opendss_voltage))
        ))
    end
    
    CSV.write(output_path, df; append=append)
    return df
end

"""
    export_scenario_summary(summaries::Vector{ScenarioSummary},
                           network_name::String,
                           output_path::String;
                           append=false)

Export per-scenario summary statistics to CSV.
"""
function export_scenario_summary(summaries::Vector{ScenarioSummary},
                                network_name::String,
                                output_path::String;
                                append=false)
    df = DataFrame(
        network = String[],
        scenario_id = String[],
        n_buses = Int[],
        feederflow_converged = Bool[],
        opendss_converged = Bool[],
        max_abs_error = Float64[],
        mean_abs_error = Float64[],
        std_abs_error = Float64[],
        p95_abs_error = Float64[],
        max_mag_error = Float64[],
        mean_mag_error = Float64[],
        max_angle_error = Float64[],
        mean_angle_error = Float64[]
    )
    
    for s in summaries
        push!(df, (
            network_name,
            s.scenario_id,
            s.n_buses,
            s.feederflow_converged,
            s.opendss_converged,
            s.max_abs_error,
            s.mean_abs_error,
            s.std_abs_error,
            s.p95_abs_error,
            s.max_mag_error,
            s.mean_mag_error,
            s.max_angle_error,
            s.mean_angle_error
        ))
    end
    
    CSV.write(output_path, df; append=append)
    return df
end

"""
    export_network_summary(network_stats::Dict{String,NamedTuple},
                          output_path::String)

Export per-network summary statistics to CSV.
"""
function export_network_summary(network_stats::Dict{String,NamedTuple},
                               output_path::String)
    df = DataFrame(
        network = String[],
        n_scenarios = Int[],
        n_converged_both = Int[],
        n_converged_ff_only = Int[],
        n_converged_dss_only = Int[],
        n_failed_both = Int[],
        max_abs_error = Float64[],
        mean_abs_error = Float64[],
        median_abs_error = Float64[],
        std_abs_error = Float64[],
        p95_abs_error = Float64[],
        p99_abs_error = Float64[]
    )
    
    for (network, stats) in sort(collect(network_stats))
        push!(df, (
            network,
            stats.n_scenarios,
            stats.n_converged_both,
            stats.n_converged_ff_only,
            stats.n_converged_dss_only,
            stats.n_failed_both,
            stats.max_abs_error,
            stats.mean_abs_error,
            stats.median_abs_error,
            stats.std_abs_error,
            stats.p95_abs_error,
            stats.p99_abs_error
        ))
    end
    
    CSV.write(output_path, df)
    return df
end

"""
    export_overall_summary(network_stats::Dict{String,NamedTuple},
                          output_path::String)

Export overall cross-network summary to CSV.
"""
function export_overall_summary(network_stats::Dict{String,NamedTuple},
                               output_path::String)
    # Aggregate across all networks
    total_scenarios = sum(s.n_scenarios for s in values(network_stats))
    total_converged_both = sum(s.n_converged_both for s in values(network_stats))
    total_converged_ff = sum(s.n_converged_ff_only for s in values(network_stats))
    total_converged_dss = sum(s.n_converged_dss_only for s in values(network_stats))
    total_failed = sum(s.n_failed_both for s in values(network_stats))
    
    max_errors = [s.max_abs_error for s in values(network_stats) if isfinite(s.max_abs_error)]
    mean_errors = [s.mean_abs_error for s in values(network_stats) if isfinite(s.mean_abs_error)]
    
    df = DataFrame(
        metric = ["total_scenarios", "converged_both", "converged_ff_only", 
                 "converged_dss_only", "failed_both", "overall_max_error", 
                 "overall_mean_error", "networks_tested"],
        value = [total_scenarios, total_converged_both, total_converged_ff,
                total_converged_dss, total_failed, 
                isempty(max_errors) ? NaN : maximum(max_errors),
                isempty(mean_errors) ? NaN : mean(mean_errors),
                length(network_stats)]
    )
    
    CSV.write(output_path, df)
    return df
end

"""
    export_metadata(config::Dict, output_path::String)

Export run metadata to JSON file.
"""
function export_metadata(config::Dict, output_path::String)
    metadata = merge(config, Dict(
        "timestamp" => string(now()),
        "julia_version" => string(VERSION)
    ))
    
    open(output_path, "w") do f
        JSON3.pretty(f, metadata)
    end
    
    return metadata
end

# ============================================================================
# Grouping and Analysis Functions
# ============================================================================

"""
    group_scenarios_by_type(summaries::Vector{ScenarioSummary})

Group scenario summaries by scenario type (load scaling, random load, tap sweep, random tap, combined).

Returns Dict{String,Vector{ScenarioSummary}}.
"""
function group_scenarios_by_type(summaries::Vector{ScenarioSummary})
    groups = Dict{String,Vector{ScenarioSummary}}()
    
    for summary in summaries
        # Determine scenario type from ID
        if occursin("load_scale", summary.scenario_id)
            type = "load_scaling"
        elseif occursin("load_random", summary.scenario_id)
            type = "load_random"
        elseif occursin("tap_sweep", summary.scenario_id)
            type = "tap_sweep"
        elseif occursin("tap_random", summary.scenario_id)
            type = "tap_random"
        elseif occursin("_x_", summary.scenario_id)
            type = "combined"
        else
            type = "other"
        end
        
        if !haskey(groups, type)
            groups[type] = ScenarioSummary[]
        end
        push!(groups[type], summary)
    end
    
    return groups
end

"""
    compute_grouped_statistics(summaries::Vector{ScenarioSummary})

Compute statistics for each scenario type group.

Returns Dict{String,NamedTuple}.
"""
function compute_grouped_statistics(summaries::Vector{ScenarioSummary})
    groups = group_scenarios_by_type(summaries)
    stats = Dict{String,NamedTuple}()
    
    for (type, group_summaries) in groups
        stats[type] = compute_network_statistics(group_summaries)
    end
    
    return stats
end

"""
    print_grouped_statistics(network_name::String, grouped_stats::Dict{String,NamedTuple})

Print statistics grouped by scenario type.
"""
function print_grouped_statistics(network_name::String, grouped_stats::Dict{String,NamedTuple})
    println("\n=== $network_name Grouped Statistics ===")
    
    for (type, stats) in sort(collect(grouped_stats))
        println("\n  Scenario Type: $type")
        @printf("    Scenarios: %d\n", stats.n_scenarios)
        @printf("    Max |ΔV|:  %.8f pu\n", stats.max_abs_error)
        @printf("    Mean |ΔV|: %.8f pu\n", stats.mean_abs_error)
        @printf("    95th %%ile: %.8f pu\n", stats.p95_abs_error)
    end
end
