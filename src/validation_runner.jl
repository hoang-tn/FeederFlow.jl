"""
Validation runner - orchestrates scenario execution and comparison.

Main module for running FeederFlow vs OpenDSS validation scenarios.
"""

using Printf
using Logging

# Import validation modules
include("scenarios.jl")
include("opendss_interface.jl")
include("validation_stats.jl")

"""
    NetworkConfig

Configuration for a test network.
"""
struct NetworkConfig
    name::String
    dss_path::String
    has_regulators::Bool
    description::String
end

"""
    get_network_registry()

Return registry of available test networks.
"""
function get_network_registry()
    repo_root = normpath(joinpath(@__DIR__, "..", ".."))
    
    networks = Dict{String,NetworkConfig}(
        "ieee13" => NetworkConfig(
            "ieee13",
            joinpath(repo_root, "FeederFlow.jl", "examples", "grids", "13_bus", "IEEE13Nodeckt.dss"),
            false,  # Will be auto-detected
            "IEEE 13-bus test feeder"
        ),
        "ieee240" => NetworkConfig(
            "ieee240",
            joinpath(repo_root, "FeederFlow.jl", "examples", "grids", "240_bus", "Master.dss"),
            true,
            "IEEE 240-bus test feeder"
        ),
        "ieee37" => NetworkConfig(
            "ieee37",
            joinpath(repo_root, "three-phase-modeling", "IEEE 37-bus feeder", "IEEE37openDSSdata", "ieee37opendss.dss"),
            true,
            "IEEE 37-bus test feeder"
        ),
        "ieee123" => NetworkConfig(
            "ieee123",
            joinpath(repo_root, "three-phase-modeling", "IEEE 123-bus feeder", "IEEE123openDSSdata", "IEEE123Master.dss"),
            true,
            "IEEE 123-bus test feeder"
        ),
        "ieee906" => NetworkConfig(
            "ieee906",
            joinpath(repo_root, "three-phase-modeling", "European 906-bus LV feeder", "IEEELVopenDSSdata", "Master.dss"),
            false,
            "European 906-bus LV test feeder"
        )
    )
    
    return networks
end

"""
    detect_regulators(network_path::String)

Parse DSS file to detect if network has regulators.

Returns:
- `Bool` when parsing succeeds
- `nothing` when the DSS file is not currently supported by the parser
"""
function detect_regulators(network_path::String)
    try
        network = FeederFlow.parse_file(network_path)
        return !isempty(network.regulators)
    catch e
        @warn "Could not parse network for validation support check" path=network_path exception=e
        return nothing
    end
end

"""
    get_network_config(network_name::String)

Get configuration for a specific network, auto-detecting regulator presence.

Returns NetworkConfig or nothing if network not found.
"""
function get_network_config(network_name::String)
    registry = get_network_registry()
    
    if !haskey(registry, network_name)
        @warn "Network '$network_name' not found in registry"
        available = join(sort(collect(keys(registry))), ", ")
        @info "Available networks: $available"
        return nothing
    end
    
    config = registry[network_name]
    
    # Verify file exists
    if !isfile(config.dss_path)
        @warn "DSS file not found: $(config.dss_path)"
        return nothing
    end
    
    # Auto-detect regulators if needed
    has_regs = detect_regulators(config.dss_path)
    if has_regs === nothing
        @warn "Skipping network '$network_name': DSS file not currently supported by FeederFlow parser"
        return nothing
    end
    
    return NetworkConfig(
        config.name,
        config.dss_path,
        has_regs,
        config.description
    )
end

"""
    list_available_networks()

List all available test networks.
"""
function list_available_networks()
    registry = get_network_registry()
    
    println("Available test networks:")
    for name in sort(collect(keys(registry)))
        config = registry[name]
        exists = isfile(config.dss_path) ? "✓" : "✗"
        println("  $exists $name: $(config.description)")
        if isfile(config.dss_path)
            has_regs = detect_regulators(config.dss_path)
            println("      Path: $(config.dss_path)")
            if has_regs === nothing
                println("      Supported by parser: no")
            else
                println("      Regulators: $(has_regs ? "yes" : "no")")
            end
        end
    end
end

"""
    ValidationResult

Results from running a single scenario.
"""
struct ValidationResult
    scenario::ScenarioConfig
    feederflow_converged::Bool
    feederflow_voltages::Dict{String,ComplexF64}
    opendss_converged::Bool
    opendss_voltages::Dict{String,ComplexF64}
    error_metrics::Vector{ErrorMetrics}
    summary::ScenarioSummary
end

"""
    sanitize_filename(s::String)

Sanitize a string for safe use in filenames.
Removes or replaces unsafe characters.
"""
function sanitize_filename(s::String)
    # Replace unsafe characters with underscores
    sanitized = replace(s, r"[<>:\"/\\|?*\x00-\x1f]" => "_")
    # Limit length to avoid filesystem issues
    if length(sanitized) > 200
        sanitized = sanitized[1:200]
    end
    return sanitized
end

"""
    run_feederflow_scenario(network_path::String, scenario::ScenarioConfig, temp_dir::String)

Run FeederFlow on a scenario.
Since FeederFlow doesn't natively support load/tap modification, we use the modified DSS file.

Returns (converged::Bool, voltages::Dict{String,ComplexF64})
"""
function run_feederflow_scenario(network_path::String, scenario::ScenarioConfig, temp_dir::String)
    # Create temporary modified DSS file with sanitized filename
    safe_id = sanitize_filename(scenario.id)
    temp_dss = joinpath(temp_dir, "ff_scenario_$(safe_id).dss")
    modify_dss_file(network_path, temp_dss, scenario)
    
    try
        # Parse and solve with FeederFlow
        network = FeederFlow.parse_file(temp_dss)
        bundle = FeederFlow.solve_power_flow(network; max_iter=20, tol=1e-6)
        
        # Convert to standard format
        voltages = feederflow_voltage_map(bundle.result.phase_voltages)
        
        # Use solver convergence metadata directly.
        converged = bundle.result.converged
        
        return converged, voltages
    catch e
        @warn "FeederFlow failed for scenario $(scenario.id)" exception=(e, catch_backtrace())
        return false, Dict{String,ComplexF64}()
    finally
        # Clean up temp file
        rm(temp_dss; force=true)
    end
end

"""
    run_opendss_scenario(network_path::String,
                        scenario::ScenarioConfig,
                        temp_dir::String;
                        global_vbase=nothing)

Run OpenDSS on a scenario.

Returns (converged::Bool, voltages::Dict{String,ComplexF64})
"""
function run_opendss_scenario(network_path::String,
                              scenario::ScenarioConfig,
                              temp_dir::String;
                              global_vbase::Union{Nothing,Float64}=nothing)
    # Create temporary modified DSS file with sanitized filename
    safe_id = sanitize_filename(scenario.id)
    temp_dss = joinpath(temp_dir, "dss_scenario_$(safe_id).dss")
    modify_dss_file(network_path, temp_dss, scenario)
    
    try
        converged, voltages = execute_opendss(temp_dss; global_vbase=global_vbase)
        return converged, voltages
    catch e
        @warn "OpenDSS failed for scenario $(scenario.id)" exception=(e, catch_backtrace())
        return false, Dict{String,ComplexF64}()
    finally
        # Clean up temp file
        rm(temp_dss; force=true)
    end
end

"""
    run_single_scenario(network_path::String,
                       scenario::ScenarioConfig,
                       temp_dir::String;
                       verbose=false,
                       global_vbase=nothing)

Run both FeederFlow and OpenDSS on a single scenario and compute error metrics.

Returns ValidationResult.
"""
function run_single_scenario(network_path::String, 
                            scenario::ScenarioConfig,
                            temp_dir::String;
                            verbose=false,
                            global_vbase::Union{Nothing,Float64}=nothing)
    if verbose
        @info "Running scenario: $(scenario.id)"
    end
    
    # Run FeederFlow
    ff_converged, ff_voltages = run_feederflow_scenario(network_path, scenario, temp_dir)
    
    # Run OpenDSS
    dss_converged, dss_voltages = run_opendss_scenario(
        network_path,
        scenario,
        temp_dir;
        global_vbase=global_vbase,
    )
    
    # Compute error metrics
    metrics = compute_error_metrics(ff_voltages, dss_voltages)
    
    # Aggregate summary
    summary = aggregate_scenario_metrics(scenario.id, metrics, ff_converged, dss_converged)
    
    if verbose
        print_scenario_summary(summary)
    end
    
    return ValidationResult(
        scenario,
        ff_converged,
        ff_voltages,
        dss_converged,
        dss_voltages,
        metrics,
        summary
    )
end

"""
    run_all_scenarios(network_path::String,
                     scenarios::Vector,
                     temp_dir::String;
                     verbose=true,
                     progress_interval=10)

Run all scenarios for a network.

Returns Vector{ValidationResult}.
"""
function run_all_scenarios(network_path::String,
                          scenarios::Vector{ScenarioConfig},
                          temp_dir::String;
                          verbose=true,
                          progress_interval=10,
                          global_vbase::Union{Nothing,Float64}=nothing)
    results = ValidationResult[]
    n_scenarios = length(scenarios)
    
    @info "Running $n_scenarios scenarios for network: $network_path"
    
    for (i, scenario) in enumerate(scenarios)
        if verbose && (i % progress_interval == 0 || i == 1 || i == n_scenarios)
            @info "Progress: $i / $n_scenarios scenarios"
        end
        
        result = run_single_scenario(
            network_path,
            scenario,
            temp_dir;
            verbose=false,
            global_vbase=global_vbase,
        )
        push!(results, result)
    end
    
    @info "Completed $n_scenarios scenarios"
    
    return results
end

"""
    save_validation_results(results::Vector{ValidationResult},
                           network_name::String,
                           output_dir::String)

Save validation results to CSV files.

Creates:
- scenarios/\$(network_name)_scenarios.csv
- raw_results/\$(network_name)_raw.csv
- (appends to) summary/scenario_summary.csv
"""
function save_validation_results(results::Vector{ValidationResult},
                                network_name::String,
                                output_dir::String)
    # Create output directories
    scenarios_dir = joinpath(output_dir, "scenarios")
    raw_dir = joinpath(output_dir, "raw_results")
    summary_dir = joinpath(output_dir, "summary")
    
    mkpath(scenarios_dir)
    mkpath(raw_dir)
    mkpath(summary_dir)
    
    # Export scenario definitions
    scenarios = [r.scenario for r in results]
    scenario_path = joinpath(scenarios_dir, "$(network_name)_scenarios.csv")
    export_scenario_definitions(scenarios, scenario_path, network_name)
    @info "Saved scenario definitions to $scenario_path"
    
    # Export raw results (all at once for this network)
    raw_path = joinpath(raw_dir, "$(network_name)_raw.csv")
    first_write = true
    for result in results
        export_raw_results(result.error_metrics, result.scenario.id, 
                          network_name, raw_path; append=!first_write)
        first_write = false
    end
    @info "Saved raw results to $raw_path"
    
    # Export scenario summaries
    summaries = [r.summary for r in results]
    summary_path = joinpath(summary_dir, "scenario_summary.csv")
    append_mode = isfile(summary_path)
    export_scenario_summary(summaries, network_name, summary_path; append=append_mode)
    @info "Saved scenario summary to $summary_path"
    
    return (scenarios_dir, raw_dir, summary_dir)
end

"""
    generate_final_reports(all_results::Dict{String,Vector{ValidationResult}},
                          output_dir::String,
                          config::Dict)

Generate final network and overall summary reports.

Creates:
- summary/network_summary.csv
- summary/overall_summary.csv
- metadata.json
"""
function generate_final_reports(all_results::Dict{String,Vector{ValidationResult}},
                               output_dir::String,
                               config::Dict)
    summary_dir = joinpath(output_dir, "summary")
    mkpath(summary_dir)
    
    # Compute per-network statistics
    network_stats = Dict{String,NamedTuple}()
    for (network_name, results) in all_results
        summaries = [r.summary for r in results]
        network_stats[network_name] = compute_network_statistics(summaries)
    end
    
    # Export network summary
    network_summary_path = joinpath(summary_dir, "network_summary.csv")
    export_network_summary(network_stats, network_summary_path)
    @info "Saved network summary to $network_summary_path"
    
    # Export overall summary
    overall_summary_path = joinpath(summary_dir, "overall_summary.csv")
    export_overall_summary(network_stats, overall_summary_path)
    @info "Saved overall summary to $overall_summary_path"
    
    # Export metadata
    metadata_path = joinpath(output_dir, "metadata.json")
    export_metadata(config, metadata_path)
    @info "Saved metadata to $metadata_path"
    
    # Print summary to console
    println("\n" * "="^80)
    println("VALIDATION RUN COMPLETE")
    println("="^80)
    
    for (network_name, stats) in sort(collect(network_stats))
        print_network_statistics(network_name, stats)
    end
    
    println("\nResults saved to: $output_dir")
    println("="^80)
    
    return network_stats
end
