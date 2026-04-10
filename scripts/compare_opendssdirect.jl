using FeederFlow
using OpenDSSDirect
using Printf
using Statistics

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

const FEEDER_PATHS = Dict(
    :ieee37 => joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 37-bus feeder", "IEEE37openDSSdata", "ieee37opendss.dss"),
    :ieee123 => joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 123-bus feeder", "IEEE123openDSSdata", "IEEE123Master.dss"),
)

const VOLTAGE_REFERENCE_PATHS = Dict(
    :ieee37 => joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 37-bus feeder", "IEEE37openDSSdata", "ieee37_EXP_VOLTAGES.CSV"),
    :ieee123 => joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 123-bus feeder", "IEEE123openDSSdata", "ieee123_EXP_VOLTAGES.CSV"),
)

busphase_key(node::FeederFlow.BusPhase) = string(node.bus, ".", node.phase)
busphase_key(bus::AbstractString, phase::Integer) = string(bus, ".", phase)

normalize_node_name(name::AbstractString) = lowercase(strip(name))

function actual_voltage_map(phase_voltages)
    return Dict(busphase_key(key) => value for (key, value) in phase_voltages)
end

function wrap_angle_diff_deg(a::ComplexF64, b::ComplexF64)
    diff = rad2deg(angle(a) - angle(b))
    return abs(mod(diff + 180, 360) - 180)
end

function opendssdirect_voltage_map(path::AbstractString; global_vbase::Union{Nothing,Float64}=nothing)
    quoted = replace(normpath(path), "\\" => "/")
    dss("""
        clear
        compile "$quoted"
    """)
    Solution.Solve()
    converged = Solution.Converged()
    node_names = Circuit.AllNodeNames()
    node_voltages = Circuit.AllBusVolts()
    length(node_names) == length(node_voltages) ||
        error("OpenDSSDirect returned inconsistent node arrays")
    node_mag_pu = global_vbase === nothing ? Circuit.AllBusMagPu() : nothing
    if global_vbase === nothing
        length(node_names) == length(node_mag_pu) ||
            error("OpenDSSDirect returned inconsistent node arrays")
    end

    voltages = Dict{String,ComplexF64}()
    for i in eachindex(node_names)
        name = node_names[i]
        voltage = node_voltages[i]
        abs(voltage) > 0 || continue
        base_voltage = if global_vbase === nothing
            mag_pu = node_mag_pu[i]
            mag_pu > 0 || continue
            abs(voltage) / mag_pu
        else
            global_vbase
        end
        base_voltage > 0 || continue
        key = normalize_node_name(name)
        voltages[key] = voltage / base_voltage
    end
    return converged, voltages
end

function voltage_csv_map(path::AbstractString; normalize_to_vbase::Union{Nothing,Float64}=nothing)
    voltages = Dict{String,ComplexF64}()
    for (line_no, line) in enumerate(readlines(path))
        line_no == 1 && continue
        fields = split(line, ',')
        length(fields) < 14 && continue
        bus = lowercase(strip(replace(fields[1], "\"" => "")))
        node_fields = ((3, 4, 5), (7, 8, 9), (11, 12, 13))
        for (node_col, mag_col, angle_col) in node_fields
            node = tryparse(Int, strip(fields[node_col]))
            magnitude = tryparse(Float64, strip(fields[mag_col]))
            angle_deg = tryparse(Float64, strip(fields[angle_col]))
            node === nothing && continue
            magnitude === nothing && continue
            angle_deg === nothing && continue
            node == 0 && continue
            value = magnitude * cis(deg2rad(angle_deg))
            normalize_to_vbase === nothing || (value /= normalize_to_vbase)
            voltages[busphase_key(bus, node)] = value
        end
    end
    return voltages
end

function voltage_diff_table(actual::Dict{String,ComplexF64}, reference::Dict{String,ComplexF64})
    shared = sort!(collect(intersect(keys(actual), keys(reference))))
    rows = NamedTuple[]
    for key in shared
        a = actual[key]
        b = reference[key]
        push!(rows, (
            key = key,
            abs_diff = abs(a - b),
            mag_diff = abs(abs(a) - abs(b)),
            angle_diff_deg = wrap_angle_diff_deg(a, b),
            actual = a,
            reference = b,
        ))
    end
    sort!(rows; by = row -> row.abs_diff, rev = true)
    return rows
end

function compare_maps(label::AbstractString, actual::Dict{String,ComplexF64}, reference::Dict{String,ComplexF64}; top_n::Int = 10)
    shared = intersect(keys(actual), keys(reference))
    missing = sort!(collect(setdiff(keys(reference), keys(actual))))
    extra = sort!(collect(setdiff(keys(actual), keys(reference))))
    rows = voltage_diff_table(actual, reference)

    max_abs_diff = isempty(rows) ? NaN : rows[1].abs_diff
    mean_abs_diff = isempty(rows) ? NaN : mean(row.abs_diff for row in rows)
    max_mag_diff = isempty(rows) ? NaN : maximum(row.mag_diff for row in rows)
    max_angle_diff = isempty(rows) ? NaN : maximum(row.angle_diff_deg for row in rows)

    println(label)
    @printf("  shared=%d actual=%d reference=%d missing=%d extra=%d\n", length(shared), length(actual), length(reference), length(missing), length(extra))
    @printf("  max|ΔV|=%.8f pu, mean|ΔV|=%.8f pu, max|Δ|mag=%.8f pu, max|Δ|angle=%.6f deg\n",
        max_abs_diff, mean_abs_diff, max_mag_diff, max_angle_diff)

    if !isempty(missing)
        println("  missing keys: ", join(first(missing, min(length(missing), 12)), ", "))
    end
    if !isempty(extra)
        println("  extra keys: ", join(first(extra, min(length(extra), 12)), ", "))
    end

    println("  top mismatches:")
    if isempty(rows)
        println("    <none>")
    else
        for row in rows[1:min(top_n, length(rows))]
            @printf(
                "    %-10s | |ΔV|=%.8f pu | Δ|V|=%.8f pu | Δθ=%.6f deg\n",
                row.key,
                row.abs_diff,
                row.mag_diff,
                row.angle_diff_deg,
            )
        end
    end
    println()

    return (
        label = String(label),
        shared = length(shared),
        actual = length(actual),
        reference = length(reference),
        missing = missing,
        extra = extra,
        max_abs_diff = max_abs_diff,
        mean_abs_diff = mean_abs_diff,
        max_mag_diff = max_mag_diff,
        max_angle_diff = max_angle_diff,
        top = rows[1:min(top_n, length(rows))],
    )
end

function solve_feederflow_maps(path::AbstractString)
    network = FeederFlow.parse_file(path)
    general_bundle = FeederFlow.solve_power_flow(network)
    return (
        network = network,
        general = actual_voltage_map(general_bundle.result.phase_voltages),
    )
end

function run_case(feeder::Symbol, path::AbstractString)
    println("=== $(uppercase(String(feeder))) ===")
    feederflow = solve_feederflow_maps(path)
    vbase = feederflow.network.base.Vbase

    reference_path = VOLTAGE_REFERENCE_PATHS[feeder]
    reference_map = voltage_csv_map(reference_path; normalize_to_vbase=vbase)
    println("Reference nodes: ", length(reference_map))

    # Get OpenDSSDirect voltages
    converged, dss_map = opendssdirect_voltage_map(path; global_vbase=vbase)
    println("OpenDSSDirect converged: ", converged, ", nodes: ", length(dss_map))

    println("FeederFlow nodes: ", length(feederflow.general))
    
    # Compare both solvers on the same shared base as FeederFlow.
    reference_summary = compare_maps("FeederFlow vs reference CSV", feederflow.general, reference_map)
    dss_summary = compare_maps("OpenDSSDirect vs reference CSV", dss_map, reference_map)
    cross_summary = compare_maps("FeederFlow vs OpenDSSDirect", feederflow.general, dss_map)

    return (
        feeder = feeder,
        opendss_converged = converged,
        reference = reference_summary,
        opendss = dss_summary,
        cross = cross_summary,
    )
end

function main()
    println("FeederFlow comparison against shared-base OpenDSS references")
    println("Note: on Julia 1.12, run this script with `--compiled-modules=no` because OpenDSSDirect.jl v0.9.9 fails precompilation in this environment.")
    println()

    results = [run_case(feeder, path) for (feeder, path) in sort!(collect(FEEDER_PATHS); by = first)]

    println("=== Summary ===")
    for result in results
        @printf(
            "%-8s FeederFlow vs reference max|ΔV|=%.8f pu | OpenDSS vs reference max|ΔV|=%.8f pu | FeederFlow vs OpenDSS max|ΔV|=%.8f pu\n",
            uppercase(String(result.feeder)),
            result.reference.max_abs_diff,
            result.opendss.max_abs_diff,
            result.cross.max_abs_diff,
        )
    end
end

main()
