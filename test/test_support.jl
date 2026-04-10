using JSON3
using LinearAlgebra
using SparseArrays

const REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const FIXTURE_ROOT = joinpath(@__DIR__, "fixtures")
const IEEE13_DSS = joinpath(REPO_ROOT, "FeederFlow.jl", "examples", "grids", "13_bus", "IEEE13Nodeckt.dss")
const IEEE37_DSS = joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 37-bus feeder", "IEEE37openDSSdata", "ieee37opendss.dss")
const IEEE123_DSS = joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 123-bus feeder", "IEEE123openDSSdata", "IEEE123Master.dss")
const IEEE906_DSS = joinpath(REPO_ROOT, "three-phase-modeling", "European 906-bus LV feeder", "IEEELVopenDSSdata", "Master.dss")
const IEEE37_DSS_VOLTAGES = joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 37-bus feeder", "IEEE37openDSSdata", "ieee37_EXP_VOLTAGES.CSV")
const IEEE123_DSS_VOLTAGES = joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 123-bus feeder", "IEEE123openDSSdata", "ieee123_EXP_VOLTAGES.CSV")

fixture_path(name::AbstractString) = joinpath(FIXTURE_ROOT, name)

function load_fixture(name::AbstractString)
    JSON3.read(read(fixture_path(name), String))
end

busphase_key(node::FeederFlow.BusPhase) = string(node.bus, ".", node.phase)
busphase_key(bus::AbstractString, phase::Integer) = string(bus, ".", phase)

function json_string_vector(values)
    [String(value) for value in values]
end

function json_int_vector(values)
    Int[value for value in values]
end

function json_float_vector(values)
    Float64[value for value in values]
end

function json_present_float_vector(values)
    Float64[value for value in values if value !== nothing]
end

function json_dict_of_ints(obj)
    dict = Dict{String,Int}()
    for (key, value) in pairs(obj)
        dict[String(key)] = Int(value)
    end
    dict
end

function phase_map(network::FeederFlow.NetworkModel)
    Dict(bus.name => collect(bus.phases) for bus in network.buses)
end

function actual_regulator_fixture(network::FeederFlow.NetworkModel)
    regs = Dict{String,Any}()
    for reg in network.regulators
        regs[reg.name] = Dict(
            "windings" => [
                Dict(
                    "bus" => winding.bus.bus,
                    "phases" => collect(winding.bus.phases),
                    "tap" => winding.tap,
                ) for winding in reg.windings
            ],
            "control" => isnothing(reg.regcontrol) ? nothing : Dict(
                "transformer" => reg.regcontrol.transformer,
                "winding" => reg.regcontrol.winding,
                "vreg" => reg.regcontrol.vreg,
                "band" => reg.regcontrol.band,
                "ptratio" => reg.regcontrol.ptratio,
                "ctprim" => reg.regcontrol.ctprim,
                "r" => reg.regcontrol.r,
                "x" => reg.regcontrol.x,
            ),
        )
    end
    regs
end

function load_model_counts(network::FeederFlow.NetworkModel)
    counts = Dict{String,Int}()
    for load in network.loads
        key = string(load.model)
        counts[key] = get(counts, key, 0) + 1
    end
    counts
end

function load_conn_counts(network::FeederFlow.NetworkModel)
    counts = Dict{String,Int}()
    for load in network.loads
        key = String(load.conn)
        counts[key] = get(counts, key, 0) + 1
    end
    counts
end

function complex_vector_from_fixture(obj)
    re = json_float_vector(obj["re"])
    im = json_float_vector(obj["im"])
    ComplexF64.(re, im)
end

function sparse_from_fixture(obj)
    dims = json_int_vector(obj["size"])
    rows = json_int_vector(obj["row"])
    cols = json_int_vector(obj["col"])
    vals = ComplexF64.(json_float_vector(obj["re"]), json_float_vector(obj["im"]))
    sparse(rows, cols, vals, dims[1], dims[2])
end

function parse_opendss_voltages(path::AbstractString)
    voltages = Dict{String,ComplexF64}()
    for (line_no, line) in enumerate(readlines(path))
        line_no == 1 && continue
        fields = split(line, ',')
        length(fields) < 14 && continue
        bus = lowercase(strip(replace(fields[1], "\"" => "")))
        node_fields = ((3, 6, 5), (7, 10, 9), (11, 14, 13))
        for (node_col, pu_col, angle_col) in node_fields
            node = tryparse(Int, strip(fields[node_col]))
            pu = tryparse(Float64, strip(fields[pu_col]))
            angle_deg = tryparse(Float64, strip(fields[angle_col]))
            node === nothing && continue
            pu === nothing && continue
            angle_deg === nothing && continue
            node == 0 && continue
            pu <= 0 && continue
            voltages[busphase_key(bus, node)] = pu * cis(deg2rad(angle_deg))
        end
    end
    voltages
end

function actual_voltage_map(phase_voltages)
    Dict(busphase_key(key) => value for (key, value) in phase_voltages)
end

function actual_noload_map(ybus::FeederFlow.YBusModel, noload::FeederFlow.NoLoadResult)
    dict = Dict{String,ComplexF64}()
    for (idx, node) in enumerate(ybus.network_order)
        dict[busphase_key(node)] = noload.w[idx]
    end
    for (idx, node) in enumerate(ybus.slack_order)
        dict[busphase_key(node)] = noload.slack[idx]
    end
    dict
end

function fixture_voltage_map(obj)
    dict = Dict{String,ComplexF64}()
    for (_, value) in pairs(obj)
        value === nothing && continue
        dict[String(value["original_key"])] = ComplexF64(Float64(value["re"]), Float64(value["im"]))
    end
    dict
end

function reordered_actual_rect(actual::SparseMatrixCSC{ComplexF64,Int}, actual_rows::Vector{String}, actual_cols::Vector{String}, expected_rows::Vector{String}, expected_cols::Vector{String})
    row_lookup = Dict(key => idx for (idx, key) in enumerate(actual_rows))
    col_lookup = Dict(key => idx for (idx, key) in enumerate(actual_cols))
    row_perm = [row_lookup[key] for key in expected_rows]
    col_perm = [col_lookup[key] for key in expected_cols]
    actual[row_perm, col_perm]
end

function matrix_max_abs_diff(actual, expected)
    size(actual) == size(expected) || return Inf
    maximum(abs.(actual .- expected))
end

function mismatch_report(actual::Dict{String,ComplexF64}, expected::Dict{String,ComplexF64}; limit::Int = 8)
    shared = sort!(collect(intersect(keys(actual), keys(expected))))
    missing = sort!(collect(setdiff(keys(expected), keys(actual))))
    extra = sort!(collect(setdiff(keys(actual), keys(expected))))
    rows = Vector{Tuple{String,Float64,Float64,Float64}}()
    for key in shared
        a = actual[key]
        e = expected[key]
        push!(rows, (key, abs(a - e), abs(abs(a) - abs(e)), abs(rad2deg(angle(a / e)))))
    end
    sort!(rows, by = row -> row[2], rev = true)
    lines = String[]
    !isempty(missing) && push!(lines, "missing: " * join(first(missing, min(length(missing), limit)), ", "))
    !isempty(extra) && push!(lines, "extra: " * join(first(extra, min(length(extra), limit)), ", "))
    for row in first(rows, min(length(rows), limit))
        push!(lines, string(row[1], " | phasor=", row[2], " mag=", row[3], " angle_deg=", row[4]))
    end
    join(lines, "\n")
end

function max_voltage_diff(actual::Dict{String,ComplexF64}, expected::Dict{String,ComplexF64})
    shared = intersect(keys(actual), keys(expected))
    isempty(shared) && return Inf
    maximum(abs(actual[key] - expected[key]) for key in shared)
end
