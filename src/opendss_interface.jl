"""
OpenDSS interface for scenario testing.

Provides functions to:
- Modify DSS files with load scaling and tap positions
- Execute OpenDSS via OpenDSSDirect.jl
- Extract voltage results in FeederFlow-compatible format
"""

using OpenDSSDirect
using Printf

const DSS_FILE_COMMAND = r"^(\s*)(redirect|compile|include|buscoords)(\s+)(.+?)\s*$"i
const DSS_NUMERIC_LITERAL = "[+-]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][+-]?\\d+)?"
const DSS_SIDE_EFFECT_COMMAND = r"^\s*(show|plot|buscoords|help)\b"i
const DSS_EMBEDDED_FILE_REF = r"(?i)\bfile\s*=\s*(\"[^\"]+\"|'[^']+'|[^\s\)\]]+)"
const REGULATOR_TAP_STEP = 0.00625

"""
    modify_dss_file(input_path::String, output_path::String, scenario::ScenarioConfig)

Create a modified DSS file with load scaling and tap positions applied.
Writes the modified file to output_path.
Handles Redirect/Include statements by preserving relative paths.
"""
function modify_dss_file(input_path::String, output_path::String, scenario::ScenarioConfig)
    # Read original DSS file
    lines = readlines(input_path)
    modified_lines = String[]

    # Normalize scenario dictionaries so name matching is case-insensitive.
    normalized_scenario = ScenarioConfig(
        scenario.id,
        scenario.description,
        scenario.load_scale,
        Dict{String,Float64}(lowercase(strip(name)) => scale for (name, scale) in scenario.load_variations),
        Dict{String,Int}(lowercase(strip(name)) => tap for (name, tap) in scenario.tap_positions),
    )
    
    # Get input directory for resolving relative paths
    input_dir = dirname(input_path)
    temp_dir = dirname(output_path)
    include_cache = Dict{String,String}()
    
    for line in lines
        modified_line = suppress_side_effect_command(line)
        modified_line = apply_scenario_modifiers_to_line(modified_line, normalized_scenario)

        # Keep include chains valid when the scenario file lives in a temp directory.
        modified_line = rewrite_file_command(modified_line, input_dir, temp_dir, include_cache, normalized_scenario)
        
        push!(modified_lines, modified_line)
    end
    
    # Write modified DSS file
    mkpath(dirname(output_path))
    open(output_path, "w") do f
        for line in modified_lines
            println(f, line)
        end
    end
    
    return output_path
end

"""
    suppress_side_effect_command(line::String)

Comment out OpenDSS commands that produce report files or GUI artifacts and are
not required for solving power flow in automated validation runs.
"""
function suppress_side_effect_command(line::String)
    occursin(DSS_SIDE_EFFECT_COMMAND, line) || return line
    return "! validation_runner disabled: " * strip(line)
end

"""
    apply_scenario_modifiers_to_line(line::String, scenario::ScenarioConfig)

Apply load scaling and regulator tap modifications to a DSS command line when
the line declares a supported object (`New Load.*`, `New RegControl.*`).
"""
function apply_scenario_modifiers_to_line(line::String, scenario::ScenarioConfig)
    modified = line

    if occursin(r"^\s*New\s+Load\."i, line)
        m = match(r"Load\.([A-Za-z0-9_.-]+)"i, line)
        if m !== nothing
            load_name = lowercase(strip(m.captures[1]))
            if haskey(scenario.load_variations, load_name)
                modified = apply_load_scale_to_line(modified, scenario.load_variations[load_name])
            elseif scenario.load_scale != 1.0 && isempty(scenario.load_variations)
                modified = apply_load_scale_to_line(modified, scenario.load_scale)
            end
        end
    end

    modified = apply_transformer_tap_modifiers_to_line(modified, scenario.tap_positions)
    modified = apply_regcontrol_tap_modifiers_to_line(modified, scenario.tap_positions)

    return modified
end

function lookup_tap_position(tap_positions::Dict{String,Int}, names::Union{Nothing,AbstractString}...)
    for name in names
        name === nothing && continue
        normalized = lowercase(strip(name))
        haskey(tap_positions, normalized) && return tap_positions[normalized]
    end
    return nothing
end

tap_position_to_ratio(tap::Int) = 1.0 + REGULATOR_TAP_STEP * tap

function upsert_property(line::String, key::String, value::String)
    pattern = Regex("(?i)(\\b$(key)\\s*=\\s*)(\\\"[^\\\"]*\\\"|'[^']*'|[^\\s]+)")
    m = match(pattern, line)
    if m !== nothing
        return replace(line, m.match => m.captures[1] * value; count=1)
    end
    return rstrip(line) * " $(key)=$value"
end

function apply_regcontrol_tap_modifiers_to_line(line::String, tap_positions::Dict{String,Int})
    isempty(tap_positions) && return line
    occursin(r"^\s*New\s+RegControl\."i, line) || return line

    reg_match = match(r"RegControl\.([A-Za-z0-9_.-]+)"i, line)
    tx_match = match(r"(?i)\btransformer\s*=\s*([A-Za-z0-9_.-]+)", line)
    tap = lookup_tap_position(
        tap_positions,
        reg_match === nothing ? nothing : reg_match.captures[1],
        tx_match === nothing ? nothing : tx_match.captures[1],
    )
    tap === nothing && return line

    # Keep OpenDSS controls fixed for tap sweep scenarios so requested TapNum is respected.
    modified = apply_tap_position_to_line(line, tap)
    return upsert_property(modified, "enabled", "no")
end

function rewrite_transformer_taps_rhs(rhs::AbstractString, tap_ratio::Float64)
    return "[$(@sprintf("%.6f", 1.0)) $(@sprintf("%.6f", tap_ratio))]"
end

function apply_transformer_tap_assignment(line::String, tap_ratio::Float64)
    tap_pattern = Regex("(?i)(\\btap\\s*=\\s*)(\\([^\\)]*\\)|$DSS_NUMERIC_LITERAL|[^\\s]+)")
    m = match(tap_pattern, line)
    if m !== nothing
        return replace(line, m.match => m.captures[1] * @sprintf("%.6f", tap_ratio); count=1)
    end
    return rstrip(line) * " Tap=$(@sprintf("%.6f", tap_ratio))"
end

function apply_transformer_tap_modifiers_to_line(line::String, tap_positions::Dict{String,Int})
    isempty(tap_positions) && return line

    taps_match = match(r"^\s*Transformer\.([A-Za-z0-9_.-]+)\.Taps\s*=\s*(.+)$"i, line)
    if taps_match !== nothing
        transformer_name = lowercase(strip(taps_match.captures[1]))
        tap = get(tap_positions, transformer_name, nothing)
        tap === nothing && return line

        tap_ratio = tap_position_to_ratio(tap)
        rhs = rewrite_transformer_taps_rhs(taps_match.captures[2], tap_ratio)
        return replace(line, taps_match.captures[2] => rhs; count=1)
    end

    assignment_match = match(r"^\s*Transformer\.([A-Za-z0-9_.-]+)\.(wdg|winding)\s*=\s*([0-9]+)"i, line)
    if assignment_match !== nothing
        transformer_name = lowercase(strip(assignment_match.captures[1]))
        tap = get(tap_positions, transformer_name, nothing)
        if tap !== nothing && parse(Int, assignment_match.captures[3]) == 2
            return apply_transformer_tap_assignment(line, tap_position_to_ratio(tap))
        end
        return line
    end

    direct_tap_match = match(r"^\s*Transformer\.([A-Za-z0-9_.-]+)\.Tap\s*=\s*"i, line)
    if direct_tap_match !== nothing
        transformer_name = lowercase(strip(direct_tap_match.captures[1]))
        tap = get(tap_positions, transformer_name, nothing)
        tap === nothing && return line
        return apply_transformer_tap_assignment(line, tap_position_to_ratio(tap))
    end

    new_transformer_match = match(r"^\s*New\s+Transformer\.([A-Za-z0-9_.-]+)\b"i, line)
    if new_transformer_match !== nothing
        transformer_name = lowercase(strip(new_transformer_match.captures[1]))
        tap = get(tap_positions, transformer_name, nothing)
        tap === nothing && return line

        tap_ratio = tap_position_to_ratio(tap)
        taps_pattern = r"(?i)(\btaps\s*=\s*)(\[[^\]]*\]|\([^\)]*\)|\"[^\"]*\"|'[^']*'|[^\s]+)"
        taps_match = match(taps_pattern, line)
        if taps_match !== nothing
            rhs = rewrite_transformer_taps_rhs("", tap_ratio)
            return replace(line, taps_match.match => taps_match.captures[1] * rhs; count=1)
        end
        return rstrip(line) * " Taps=[1.000000 " * @sprintf("%.6f", tap_ratio) * "]"
    end

    return line
end

"""
    rewrite_file_command(line::String,
                        input_dir::String,
                        temp_dir::String,
                        include_cache::Dict{String,String},
                        scenario::ScenarioConfig)

Rewrite Redirect/Compile/Include targets to rewritten include copies in the temp
directory. Any embedded `file=` references inside the include file are rewritten
to absolute paths so nested profile files remain resolvable.
"""
function rewrite_file_command(line::String,
                              input_dir::String,
                              temp_dir::String,
                              include_cache::Dict{String,String},
                              scenario::ScenarioConfig)
    m = match(DSS_FILE_COMMAND, line)
    m === nothing && return line

    raw_target = strip(m.captures[4])
    isempty(raw_target) && return line

    target = raw_target
    wrapped_in_parens = false
    if startswith(target, "(") && endswith(target, ")")
        target = strip(target[2:end - 1])
        wrapped_in_parens = true
    end

    unquoted = strip(replace(target, "\"" => "", "'" => ""))
    isempty(unquoted) && return line

    abs_target = isabspath(unquoted) ? unquoted : joinpath(input_dir, unquoted)
    include_target = prepare_include_file(abs_target, input_dir, temp_dir, include_cache, scenario)
    normalized = replace(normpath(include_target), "\\" => "/")
    escaped = replace(normalized, "\"" => "\\\"")

    rendered = wrapped_in_parens ? "(\"$escaped\")" : "\"$escaped\""
    return string(m.captures[1], m.captures[2], m.captures[3], rendered)
end

function resolve_relative_file_path(reference_dir::String, raw_target::AbstractString)
    target = strip(replace(raw_target, '"' => "", '\'' => ""))
    isabspath(target) && return normpath(target)

    current_dir = normpath(reference_dir)
    while true
        candidate = normpath(joinpath(current_dir, target))
        isfile(candidate) && return candidate

        parent_dir = dirname(current_dir)
        parent_dir == current_dir && break
        current_dir = parent_dir
    end

    return normpath(joinpath(reference_dir, target))
end

function rewrite_embedded_file_references(line::String, reference_dir::String)
    modified = line
    for match in eachmatch(DSS_EMBEDDED_FILE_REF, line)
        abs_target = resolve_relative_file_path(reference_dir, match.captures[1])
        normalized = replace(normpath(abs_target), "\\" => "/")
        modified = replace(modified, match.match => "file=\"$normalized\""; count = 1)
    end
    return modified
end

function prepare_include_file(source_path::String,
                              input_dir::String,
                              temp_dir::String,
                              include_cache::Dict{String,String},
                              scenario::ScenarioConfig)
    abs_source = normpath(source_path)
    cached = get(include_cache, abs_source, nothing)
    cached !== nothing && return cached

    relative_source = relpath(abs_source, input_dir)
    startswith(relative_source, "..") && (relative_source = basename(abs_source))
    output_path = joinpath(temp_dir, "_includes", relative_source)
    include_cache[abs_source] = output_path
    mkpath(dirname(output_path))

    open(output_path, "w") do out
        for line in eachline(abs_source)
            processed = suppress_side_effect_command(line)
            processed = apply_scenario_modifiers_to_line(processed, scenario)
            processed = rewrite_file_command(processed, dirname(abs_source), temp_dir, include_cache, scenario)
            processed = rewrite_embedded_file_references(processed, dirname(abs_source))
            println(out, processed)
        end
    end

    return output_path
end

"""
    apply_load_scale_to_line(line::String, scale::Float64)

Apply load scaling to a DSS line containing Load definition.
Scales kW and kvar properties by the given factor.
"""
function apply_load_scale_to_line(line::String, scale::Float64)
    modified = line
    
    try
        # Scale kW - find all matches and replace
        for m in eachmatch(Regex("(?i)(\\bkW\\s*=\\s*)($DSS_NUMERIC_LITERAL)"), modified)
            old_value = parse(Float64, m.captures[2])
            new_value = old_value * scale
            modified = replace(modified, m.match => m.captures[1] * @sprintf("%.12g", new_value); count=1)
        end
        
        # Scale kvar - find all matches and replace
        for m in eachmatch(Regex("(?i)(\\bkvar\\s*=\\s*)($DSS_NUMERIC_LITERAL)"), modified)
            old_value = parse(Float64, m.captures[2])
            new_value = old_value * scale
            modified = replace(modified, m.match => m.captures[1] * @sprintf("%.12g", new_value); count=1)
        end
    catch e
        @warn "Failed to apply load scale to line" line=line scale=scale exception=e
        return line  # Return original line if parsing fails
    end
    
    return modified
end

"""
    apply_tap_position_to_line(line::String, tap::Int)

Apply tap position to a DSS line containing RegControl definition.
Sets the TapNum property (or adds it if not present).
"""
function apply_tap_position_to_line(line::String, tap::Int)
    # Check if TapNum is already present
    if occursin(r"\bTapNum\s*=\s*[+-]?[0-9]+"i, line)
        # Replace existing TapNum
        return replace(line, r"(\bTapNum\s*=\s*)[+-]?[0-9]+"i => 
                      SubstitutionString("\\1$tap"))
    else
        # Add TapNum at the end of the line
        return rstrip(line) * " TapNum=$tap"
    end
end

"""
    execute_opendss(dss_path::String; global_vbase=nothing)

Execute OpenDSS on the given DSS file and return convergence status and voltage results.

When `global_vbase` is provided, voltages are normalized by that shared
line-to-neutral base (Volts). This keeps OpenDSS and FeederFlow on the same
per-unit convention across multi-voltage networks.

Returns:
- converged::Bool - whether the solution converged
- voltages::Dict{String,ComplexF64} - per-unit voltages keyed by "bus.phase"
"""
function execute_opendss(dss_path::String; global_vbase::Union{Nothing,Float64}=nothing)
    try
        # Clear any previous circuit
        dss("clear")
        
        # Normalize path for OpenDSS (forward slashes) and escape quotes
        normalized = replace(normpath(dss_path), "\\" => "/")
        # Escape any quotes in the path itself
        escaped = replace(normalized, "\"" => "\\\"")
        
        # Compile and solve
        dss("""compile "$escaped" """)
        Solution.Solve()
        
        # Check convergence
        converged = Solution.Converged()
        
        # Extract voltages
        voltages = extract_opendss_voltages(; global_vbase=global_vbase)
        
        return converged, voltages
    catch e
        @error "OpenDSS execution failed" path=dss_path exception=(e, catch_backtrace())
        rethrow()
    end
end

"""
    extract_opendss_voltages(; global_vbase=nothing)

Extract per-unit voltage results from current OpenDSS circuit.

Returns Dict{String,ComplexF64} with keys like "bus.phase" and per-unit complex voltages.
"""
function extract_opendss_voltages(; global_vbase::Union{Nothing,Float64}=nothing)
    node_names = Circuit.AllNodeNames()
    node_voltages = Circuit.AllBusVolts()

    if length(node_names) != length(node_voltages)
        error("OpenDSSDirect returned inconsistent node arrays")
    end

    node_mag_pu = nothing
    if global_vbase === nothing
        node_mag_pu = Circuit.AllBusMagPu()
        if length(node_names) != length(node_mag_pu)
            error("OpenDSSDirect returned inconsistent node arrays")
        end
    end

    voltages = Dict{String,ComplexF64}()

    for i in eachindex(node_names)
        name = node_names[i]
        voltage = node_voltages[i]

        # Skip zero voltages
        abs(voltage) > 0 || continue

        # Calculate base voltage
        base_voltage = if global_vbase === nothing
            mag_pu = node_mag_pu[i]
            mag_pu > 0 || continue
            abs(voltage) / mag_pu
        else
            global_vbase
        end
        base_voltage > 0 || continue

        # Normalize name to lowercase
        key = normalize_node_name(name)

        # Store per-unit voltage
        voltages[key] = voltage / base_voltage
    end

    return voltages
end

"""
    normalize_node_name(name::AbstractString)

Normalize node name to standard format (lowercase, trimmed).
"""
function normalize_node_name(name::AbstractString)
    return lowercase(strip(name))
end

"""
    feederflow_voltage_map(phase_voltages::Dict)

Convert FeederFlow phase_voltages to OpenDSS-compatible format.

Takes Dict{BusPhase,ComplexF64} and returns Dict{String,ComplexF64} with keys like "bus.phase".
"""
function feederflow_voltage_map(phase_voltages::Dict)
    voltages = Dict{String,ComplexF64}()
    for (bus_phase, voltage) in phase_voltages
        key = busphase_key(bus_phase)
        voltages[key] = voltage
    end
    return voltages
end

"""
    busphase_key(node)

Convert BusPhase to string key "bus.phase".
"""
function busphase_key(node)
    return string(node.bus, ".", node.phase)
end

"""
    run_scenario_comparison(network_path::String, scenario::ScenarioConfig, temp_dir::String)

Run both FeederFlow and OpenDSS on a scenario and return results.

Returns:
- feederflow_converged::Bool
- feederflow_voltages::Dict{String,ComplexF64}
- opendss_converged::Bool
- opendss_voltages::Dict{String,ComplexF64}
"""
function run_scenario_comparison(network_path::String, scenario::ScenarioConfig, temp_dir::String)
    # Create temporary modified DSS file
    temp_dss = joinpath(temp_dir, "scenario_$(scenario.id).dss")
    modify_dss_file(network_path, temp_dss, scenario)
    
    # Run OpenDSS
    try
        opendss_converged, opendss_voltages = execute_opendss(temp_dss)
    catch e
        @warn "OpenDSS failed for scenario $(scenario.id)" exception=e
        opendss_converged = false
        opendss_voltages = Dict{String,ComplexF64}()
    end
    
    # Run FeederFlow
    # Note: FeederFlow doesn't directly support load scaling or tap modification
    # We need to use the modified DSS file
    try
        # Import FeederFlow module (assuming it's available)
        # This will be filled in when integrated with validation_runner
        feederflow_converged = false
        feederflow_voltages = Dict{String,ComplexF64}()
    catch e
        @warn "FeederFlow failed for scenario $(scenario.id)" exception=e
        feederflow_converged = false
        feederflow_voltages = Dict{String,ComplexF64}()
    end
    
    # Clean up temp file
    rm(temp_dss; force=true)
    
    return (
        feederflow_converged = feederflow_converged,
        feederflow_voltages = feederflow_voltages,
        opendss_converged = opendss_converged,
        opendss_voltages = opendss_voltages
    )
end
