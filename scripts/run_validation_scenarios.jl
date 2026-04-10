#!/usr/bin/env julia

"""
Main validation script for running OpenDSS validation scenarios.

Usage:
    julia scripts/run_validation_scenarios.jl [options]

Options:
    --networks=NAMES    Comma-separated network names (e.g., ieee37,ieee123) or "all"
    --num-scenarios=N   Number of random scenarios (default: 10)
    --output-dir=PATH   Output directory (default: validation_results)
    --load-seed=N       Random seed for load variations (default: 12345)
    --tap-seed=N        Random seed for tap variations (default: 54321)
    --list              List available networks and exit
    --verbose           Enable verbose output
    --help              Show this help message

Examples:
    # List available networks
    julia scripts/run_validation_scenarios.jl --list

    # Run validation on IEEE 37 only
    julia scripts/run_validation_scenarios.jl --networks=ieee37

    # Run on all networks with 20 random scenarios each
    julia scripts/run_validation_scenarios.jl --networks=all --num-scenarios=20

    # Custom output directory
    julia scripts/run_validation_scenarios.jl --networks=ieee123 --output-dir=my_results
"""

using Pkg
Pkg.activate(normpath(joinpath(@__DIR__, "..")))

using FeederFlow
using Logging
using Printf
using Dates

# Include validation runner (which includes other modules)
include(joinpath(@__DIR__, "..", "src", "validation_runner.jl"))

"""
    parse_args(args::Vector{String})

Parse command-line arguments.
"""
function parse_args(args::Vector{String})
    config = Dict{String,Any}(
        "networks" => String[],
        "num_scenarios" => 10,
        "output_dir" => "validation_results",
        "load_seed" => 12345,
        "tap_seed" => 54321,
        "list" => false,
        "verbose" => false,
        "help" => false
    )
    
    for arg in args
        if arg == "--list"
            config["list"] = true
        elseif arg == "--verbose"
            config["verbose"] = true
        elseif arg == "--help" || arg == "-h"
            config["help"] = true
        elseif startswith(arg, "--networks=")
            networks_str = split(arg, "=")[2]
            if networks_str == "all"
                config["networks"] = ["ieee13", "ieee37", "ieee123", "ieee906"]
            else
                config["networks"] = String.(split(networks_str, ","))
            end
        elseif startswith(arg, "--num-scenarios=")
            config["num_scenarios"] = parse(Int, split(arg, "=")[2])
        elseif startswith(arg, "--output-dir=")
            config["output_dir"] = String(split(arg, "=")[2])
        elseif startswith(arg, "--load-seed=")
            config["load_seed"] = parse(Int, split(arg, "=")[2])
        elseif startswith(arg, "--tap-seed=")
            config["tap_seed"] = parse(Int, split(arg, "=")[2])
        else
            @warn "Unknown argument: $arg"
        end
    end
    
    return config
end

"""
    print_help()

Print help message.
"""
function print_help()
    println(__doc__)
end

"""
    cleanup_temp_directory(path::String; retries=5)

Best-effort temp directory cleanup with retries for transient Windows file locks.
"""
function cleanup_temp_directory(path::String; retries::Int=5)
    for attempt in 1:retries
        try
            rm(path; recursive=true, force=true)
            return true
        catch cleanup_error
            if attempt == retries
                @info "Leaving temporary directory in place (locked by external process)" path=path exception=cleanup_error
                return false
            end
            GC.gc()
            sleep(0.15 * attempt)
        end
    end
    return false
end

"""
    run_network_validation(network_config::NetworkConfig, 
                          output_dir::String,
                          num_random_scenarios::Int,
                          load_seed::Int,
                          tap_seed::Int;
                          verbose=false)

Run validation for a single network.
"""
function run_network_validation(network_config::NetworkConfig, 
                               output_dir::String,
                               num_random_scenarios::Int,
                               load_seed::Int,
                               tap_seed::Int;
                               verbose=false)
    @info "Starting validation for $(network_config.name)"
    @info "  Path: $(network_config.dss_path)"
    @info "  Has regulators: $(network_config.has_regulators)"
    
    # Create temporary directory for modified DSS files
    temp_dir = mktempdir(; prefix="validation_$(network_config.name)_", cleanup=false)
    
    try
        # Parse network to get load and regcontrol names
        network = FeederFlow.parse_file(network_config.dss_path)
        
        # Generate scenarios
        scenarios = generate_all_scenarios(
            network;
            n_random_loads=num_random_scenarios,
            n_random_taps=num_random_scenarios ÷ 2,  # Fewer tap scenarios
            load_seed=load_seed,
            tap_seed=tap_seed
        )
        
        @info "Generated $(length(scenarios)) scenarios for $(network_config.name)"
        
        # Run all scenarios
        results = run_all_scenarios(
            network_config.dss_path,
            scenarios,
            temp_dir;
            verbose=verbose,
            global_vbase=network.base.Vbase,
        )
        
        # Save results
        save_validation_results(results, network_config.name, output_dir)
        
        # Compute and print statistics
        summaries = [r.summary for r in results]
        stats = compute_network_statistics(summaries)
        print_network_statistics(network_config.name, stats)
        
        return results
    finally
        # Clean up temp directory - always runs even on errors
        cleanup_temp_directory(temp_dir)
    end
end

"""
    main(args::Vector{String})

Main entry point.
"""
function main(args::Vector{String})
    # Parse arguments
    config = parse_args(args)
    
    # Handle help
    if config["help"]
        print_help()
        return 0
    end
    
    # Handle list
    if config["list"]
        list_available_networks()
        return 0
    end
    
    # Validate that networks are specified
    if isempty(config["networks"])
        @error "No networks specified. Use --networks=NAMES or --networks=all"
        println("\nRun with --help for usage information")
        return 1
    end
    
    # Set logging level
    if config["verbose"]
        global_logger(ConsoleLogger(stderr, Logging.Debug))
    else
        global_logger(ConsoleLogger(stderr, Logging.Info))
    end
    
    # Print configuration
    println("="^80)
    println("OpenDSS Validation Scenario Runner")
    println("="^80)
    println("Networks: ", join(config["networks"], ", "))
    println("Random scenarios per network: ", config["num_scenarios"])
    println("Output directory: ", config["output_dir"])
    println("Load seed: ", config["load_seed"])
    println("Tap seed: ", config["tap_seed"])
    println("="^80)
    println()
    
    # Create output directory
    mkpath(config["output_dir"])
    
    # Run validation for each network
    all_results = Dict{String,Vector{ValidationResult}}()
    
    for network_name in config["networks"]
        # Get network configuration
        network_config = get_network_config(String(network_name))
        
        if network_config === nothing
            @info "Skipping network '$network_name' (missing file or parser-unsupported DSS)"
            continue
        end
        
        try
            results = run_network_validation(
                network_config,
                String(config["output_dir"]),
                config["num_scenarios"],
                config["load_seed"],
                config["tap_seed"];
                verbose=config["verbose"]
            )
            
            all_results[network_name] = results
        catch e
            @error "Validation failed for $network_name" exception=(e, catch_backtrace())
        end
    end
    
    # Generate final reports
    if !isempty(all_results)
        generate_final_reports(all_results, String(config["output_dir"]), config)
    else
        @warn "No results generated"
    end
    
    return 0
end

# Run main if executed as script
if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end
