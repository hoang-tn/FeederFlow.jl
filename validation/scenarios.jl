"""
Scenario generation for OpenDSS validation testing.

Generates deterministic and random scenarios for:
- Load scaling (50%-150%)
- Random load variations (±30%)
- Regulator tap sweeps (±16 steps)
- Random tap positions
"""

using Random

"""
    ScenarioConfig

Configuration for a single validation scenario.
"""
struct ScenarioConfig
    id::String
    description::String
    load_scale::Float64
    load_variations::Dict{String,Float64}  # load_name => scale_factor
    tap_positions::Dict{String,Int}        # regcontrol_name => tap_position
end

function Base.show(io::IO, sc::ScenarioConfig)
    print(io, "ScenarioConfig(id=\"$(sc.id)\", load_scale=$(sc.load_scale), ",
          "$(length(sc.load_variations)) load vars, $(length(sc.tap_positions)) taps)")
end

"""
    generate_load_scaling_scenarios(; scales=[0.5, 0.75, 1.0, 1.25, 1.5])

Generate deterministic load scaling scenarios.
All loads are scaled uniformly by the given factors.
"""
function generate_load_scaling_scenarios(; scales=[0.5, 0.75, 1.0, 1.25, 1.5])
    scenarios = ScenarioConfig[]
    for (i, scale) in enumerate(scales)
        push!(scenarios, ScenarioConfig(
            "load_scale_$(i)_$(Int(round(scale*100)))pct",
            "Uniform load scaling to $(Int(round(scale*100)))%",
            scale,
            Dict{String,Float64}(),
            Dict{String,Int}()
        ))
    end
    return scenarios
end

"""
    generate_random_load_scenarios(load_names::Vector{String}; 
                                   n_scenarios=10, 
                                   variation_pct=0.30, 
                                   seed=12345)

Generate random load variation scenarios.
Each load is independently scaled by a random factor in [1-variation_pct, 1+variation_pct].
"""
function generate_random_load_scenarios(load_names::Vector{String}; 
                                       n_scenarios=10, 
                                       variation_pct=0.30, 
                                       seed=12345)
    scenarios = ScenarioConfig[]
    rng = MersenneTwister(seed)
    
    for i in 1:n_scenarios
        variations = Dict{String,Float64}()
        for load_name in load_names
            # Random factor in [1-variation_pct, 1+variation_pct]
            factor = 1.0 + (rand(rng) * 2 - 1) * variation_pct
            variations[load_name] = factor
        end
        
        push!(scenarios, ScenarioConfig(
            "load_random_$(i)",
            "Random load variations (±$(Int(round(variation_pct*100)))%), seed=$(seed+i-1)",
            1.0,
            variations,
            Dict{String,Int}()
        ))
    end
    
    return scenarios
end

"""
    generate_tap_sweep_scenarios(regcontrol_names::Vector{String}; 
                                 tap_positions=[-16, -12, -8, -4, 0, 4, 8, 12, 16])

Generate deterministic tap sweep scenarios.
All regulators set to the same tap position for each scenario.
"""
function generate_tap_sweep_scenarios(regcontrol_names::Vector{String}; 
                                     tap_positions=[-16, -12, -8, -4, 0, 4, 8, 12, 16])
    scenarios = ScenarioConfig[]
    
    for (i, tap) in enumerate(tap_positions)
        taps = Dict{String,Int}()
        for reg_name in regcontrol_names
            taps[reg_name] = tap
        end
        
        push!(scenarios, ScenarioConfig(
            "tap_sweep_$(i)_$(tap >= 0 ? "p" : "m")$(abs(tap))",
            "All regulators at tap position $tap",
            1.0,
            Dict{String,Float64}(),
            taps
        ))
    end
    
    return scenarios
end

"""
    generate_random_tap_scenarios(regcontrol_names::Vector{String}; 
                                  n_scenarios=5, 
                                  tap_range=(-16, 16), 
                                  seed=54321)

Generate random tap position scenarios.
Each regulator independently set to a random tap position in the range.
"""
function generate_random_tap_scenarios(regcontrol_names::Vector{String}; 
                                      n_scenarios=5, 
                                      tap_range=(-16, 16), 
                                      seed=54321)
    scenarios = ScenarioConfig[]
    rng = MersenneTwister(seed)
    
    for i in 1:n_scenarios
        taps = Dict{String,Int}()
        for reg_name in regcontrol_names
            taps[reg_name] = rand(rng, tap_range[1]:tap_range[2])
        end
        
        push!(scenarios, ScenarioConfig(
            "tap_random_$(i)",
            "Random tap positions [$(tap_range[1]), $(tap_range[2])], seed=$(seed+i-1)",
            1.0,
            Dict{String,Float64}(),
            taps
        ))
    end
    
    return scenarios
end

"""
    combine_scenarios(base::ScenarioConfig, modifier::ScenarioConfig)

Combine two scenarios by merging their load variations and tap positions.
Load scales are multiplied, load variations are merged, tap positions from modifier override base.
"""
function combine_scenarios(base::ScenarioConfig, modifier::ScenarioConfig)
    # Merge load variations (modifier overrides base)
    merged_variations = merge(base.load_variations, modifier.load_variations)
    
    # Merge tap positions (modifier overrides base)
    merged_taps = merge(base.tap_positions, modifier.tap_positions)
    
    # Multiply load scales
    combined_scale = base.load_scale * modifier.load_scale
    
    # Create combined ID and description
    combined_id = base.id * "_x_" * modifier.id
    combined_desc = base.description * " + " * modifier.description
    
    return ScenarioConfig(
        combined_id,
        combined_desc,
        combined_scale,
        merged_variations,
        merged_taps
    )
end

"""
    generate_combined_scenarios(load_scenarios::Vector{ScenarioConfig},
                                tap_scenarios::Vector{ScenarioConfig})

Generate all combinations of load and tap scenarios.
Returns the cross product of load_scenarios × tap_scenarios.
"""
function generate_combined_scenarios(load_scenarios::Vector{ScenarioConfig},
                                    tap_scenarios::Vector{ScenarioConfig})
    combined = ScenarioConfig[]
    
    for load_sc in load_scenarios
        for tap_sc in tap_scenarios
            push!(combined, combine_scenarios(load_sc, tap_sc))
        end
    end
    
    return combined
end

"""
    generate_all_scenarios(network::NetworkModel; 
                          n_random_loads=10, 
                          n_random_taps=5,
                          load_seed=12345,
                          tap_seed=54321)

Generate complete scenario set for a network:
- Load scaling scenarios (5)
- Random load scenarios (n_random_loads)
- If network has regulators:
  - Tap sweep scenarios (9)
  - Random tap scenarios (n_random_taps)
  - Combined load×tap scenarios

Returns vector of ScenarioConfig.
"""
function generate_all_scenarios(network; 
                                n_random_loads=10, 
                                n_random_taps=5,
                                load_seed=12345,
                                tap_seed=54321)
    # Generate base load scenarios
    load_scaling = generate_load_scaling_scenarios()
    
    # Get load names from network
    load_names = String[string(load.name) for load in network.loads]
    load_random = generate_random_load_scenarios(load_names; 
                                                 n_scenarios=n_random_loads, 
                                                 seed=load_seed)
    
    all_load_scenarios = vcat(load_scaling, load_random)
    
    # Check if network has regulators
    regcontrol_names = String[string(reg.name) for reg in network.regulators]
    
    if isempty(regcontrol_names)
        # No regulators - just return load scenarios
        return all_load_scenarios
    else
        # Has regulators - generate tap scenarios and combinations
        tap_sweep = generate_tap_sweep_scenarios(regcontrol_names)
        tap_random = generate_random_tap_scenarios(regcontrol_names; 
                                                   n_scenarios=n_random_taps, 
                                                   seed=tap_seed)
        
        all_tap_scenarios = vcat(tap_sweep, tap_random)
        
        # Generate combined scenarios
        combined = generate_combined_scenarios(all_load_scenarios, all_tap_scenarios)
        
        # Return load-only + tap-only + combined
        return vcat(all_load_scenarios, all_tap_scenarios, combined)
    end
end
