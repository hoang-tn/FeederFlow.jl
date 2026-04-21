function dss_string(value::Any)
    if value isa Integer
        return string(value)
    elseif value isa AbstractFloat && isfinite(value) && value == round(value)
        return string(round(Int, value))
    end
    return string(value)
end

"""
    balanced_slack()

Return the canonical balanced three-phase slack phasors
`[1∠0°, 1∠-120°, 1∠120°]`.
"""
balanced_slack() = ComplexF64[1.0 + 0im, cis(-2pi / 3), cis(2pi / 3)]

function source_slack(source::SourceSpec, base::BaseQuantities)
    scale = source.pu * kv_to_vbase(source.basekv, source.phases) / base.Vbase
    return scale .* balanced_slack() .* cis(deg2rad(source.angle_deg))
end

const SOURCE_INTERNAL_SLACK_PREFIX = "__ff_source_internal__"

source_internal_slack_bus(source::SourceSpec) = string(SOURCE_INTERNAL_SLACK_PREFIX, source.bus)
is_source_internal_slack_bus(bus::AbstractString) = startswith(bus, SOURCE_INTERNAL_SLACK_PREFIX)

function source_has_series_impedance(source::SourceSpec; atol::Float64 = 0.0)
    return abs(source.r1) > atol || abs(source.x1) > atol || abs(source.r0) > atol || abs(source.x0) > atol
end

normalize_name(value) = lowercase(strip(replace(dss_string(value), "\"" => "", "'" => "")))

const DSS_RPN_BINARY_OPERATORS = Dict(
    "+" => +,
    "-" => -,
    "*" => *,
    "/" => /,
    "^" => ^,
)

function parse_dss_rpn_tokens(tokens::AbstractVector)
    stack = Float64[]
    saw_operator = false

    for token in tokens
        text = strip(dss_string(token))
        isempty(text) && continue

        if haskey(DSS_RPN_BINARY_OPERATORS, text)
            saw_operator = true
            length(stack) >= 2 || return nothing
            rhs = pop!(stack)
            lhs = pop!(stack)
            push!(stack, DSS_RPN_BINARY_OPERATORS[text](lhs, rhs))
            continue
        end

        numeric = tryparse(Float64, replace(text, "," => ""))
        numeric === nothing && return nothing
        push!(stack, numeric)
    end

    saw_operator || return nothing
    length(stack) == 1 || return nothing
    return only(stack)
end

function parse_dss_rpn_text(text::AbstractString)
    stripped = strip(replace(text, ['(', ')', '[', ']'] => ""))
    isempty(stripped) && return nothing
    tokens = split(replace(stripped, "," => " "))
    isempty(tokens) && return nothing
    return parse_dss_rpn_tokens(tokens)
end

function parse_float(value::Any, default::Float64 = 0.0)
    value === nothing && return default
    value isa Number && return Float64(value)

    if value isa AbstractVector
        if length(value) == 1 && first(value) isa AbstractVector
            return parse_float(first(value), default)
        end

        rpn_value = parse_dss_rpn_tokens(value)
        rpn_value !== nothing && return rpn_value

        if length(value) == 1
            return parse_float(first(value), default)
        end

        text = strip(dss_string(value))
        isempty(text) && return default
        numeric = tryparse(Float64, replace(text, "," => ""))
        numeric !== nothing && return numeric
        rpn_value = parse_dss_rpn_text(text)
        rpn_value !== nothing && return rpn_value
        return parse(Float64, replace(text, "," => ""))
    end

    text = strip(dss_string(value))
    isempty(text) && return default
    numeric = tryparse(Float64, replace(text, "," => ""))
    numeric !== nothing && return numeric

    rpn_value = parse_dss_rpn_text(text)
    rpn_value !== nothing && return rpn_value
    return parse(Float64, replace(text, "," => ""))
end

parse_int(value::Any, default::Int = 0) = value === nothing ? default : round(Int, parse_float(value, float(default)))

function ensure_vector(value::Any)
    value isa AbstractVector && return collect(value)
    value === nothing && return Any[]
    return [value]
end

function parse_conn(value::Any)
    text = normalize_name(value)
    if text in ("wye", "ln", "y")
        return :wye
    elseif text in ("delta", "ll", "d")
        return :delta
    end
    error("Unsupported connection type: $value")
end

function ordered_unique_phases(phases::Vector{Int})
    seen = Set{Int}()
    ordered = Int[]
    for phase in phases
        phase in seen && continue
        push!(seen, phase)
        push!(ordered, phase)
    end
    return ordered
end

is_modeled_phase(phase::Int) = 1 <= phase <= 3

function modeled_phases(phases::Vector{Int}; preserve_order::Bool = false)
    active = [phase for phase in phases if is_modeled_phase(phase)]
    return preserve_order ? ordered_unique_phases(active) : sort!(unique(active))
end

modeled_phase_count(phases::Vector{Int}) = length(modeled_phases(phases))

function terminal(bus::AbstractString, phases::Vector{Int}; preserve_order::Bool = false)
    cleaned = preserve_order ? ordered_unique_phases(phases) : sort!(unique(phases))
    TerminalSpec(normalize_name(bus), cleaned)
end

function parse_bus_terminal(value::Any; nphases::Union{Nothing,Int} = nothing, preserve_order::Bool = false)
    raw = strip(dss_string(value))
    parts = split(replace(raw, ['[', ']', '(', ')'] => ""), '.')
    bus = normalize_name(first(parts))
    suffix = parts[2:end]
    phases = if isempty(suffix)
        nphases === nothing ? Int[] : collect(1:nphases)
    else
        [parse(Int, item) for item in suffix if !isempty(strip(item))]
    end
    return terminal(bus, phases; preserve_order)
end

"""
    add_bus_phases!(acc, term; include_neutral=false)

Collect modeled phase conductors from a terminal into a bus phase set dictionary.
Neutral/ground conductors such as OpenDSS node 0, and unsupported conductor
numbers outside 1:3, are not represented as independent Y-bus nodes.
"""
function add_bus_phases!(acc::Dict{String,Set{Int}}, term::TerminalSpec; include_neutral::Bool = false)
    include_neutral && @warn "Explicit neutral nodes are not modeled in the 3-phase Y-bus; retaining phases 1:3 only." maxlog = 1
    set = get!(acc, term.bus) do
        Set{Int}()
    end
    for phase in modeled_phases(term.phases; preserve_order = true)
        push!(set, phase)
    end
    return acc
end

function lower_triangle_to_matrix(rows::Vector{Vector{Float64}}, n::Int)
    if length(rows) == 1 && length(rows[1]) == n^2
        return reshape(copy(rows[1]), n, n)
    end
    if length(rows) == n && all(length(row) == n for row in rows)
        return reduce(vcat, permutedims.(rows))
    end
    matrix = zeros(Float64, n, n)
    for i in 1:min(n, length(rows))
        row = rows[i]
        for j in 1:min(i, length(row))
            matrix[i, j] = row[j]
            matrix[j, i] = row[j]
        end
    end
    return matrix
end

function sequence_to_phase_matrix(z1::ComplexF64, z0::ComplexF64)
    a = cis(2pi / 3)
    A = ComplexF64[1 1 1; 1 a^2 a; 1 a a^2]
    return A * Diagonal(ComplexF64[z0, z1, z1]) * inv(A)
end

phase_unit(phase::Int) = SVector{3,Float64}(phase == 1 ? 1.0 : 0.0, phase == 2 ? 1.0 : 0.0, phase == 3 ? 1.0 : 0.0)

function delta_incidence(phases::Vector{Int})
    phases = modeled_phases(phases; preserve_order = true)
    isempty(phases) && error("Unsupported delta phase set: $phases")
    if length(phases) == 3
        return ComplexF64[
            1 -1 0
            0 1 -1
            -1 0 1
        ]
    elseif length(phases) == 2
        p, q = phases
        row = zeros(ComplexF64, 1, 3)
        row[1, p] = 1
        row[1, q] = -1
        return row
    elseif length(phases) == 1
        p = only(phases)
        row = zeros(ComplexF64, 1, 3)
        row[1, p] = 1
        return row
    end
    error("Unsupported delta phase set: $phases")
end

function wye_incidence(phases::Vector{Int})
    active = modeled_phases(phases; preserve_order = true)
    isempty(active) && error("Unsupported wye phase set: $phases")

    # A single-phase terminal may be written as `.phase.0` or `.0.phase`.
    # The latter reverses winding polarity, which matters for center-tapped
    # secondary transformers.
    if length(active) == 1 && length(phases) == 2 && any(==(0), phases)
        phase = only(active)
        sign = first(phases) == phase ? 1.0 : -1.0
        mat = zeros(ComplexF64, 1, 3)
        mat[1, phase] = sign
        return mat
    end

    mat = zeros(ComplexF64, length(active), 3)
    for (row, phase) in enumerate(active)
        mat[row, phase] = 1
    end
    return mat
end

function kv_to_vbase(kv::Float64, phases::Vector{Int}, conn::Symbol=:wye)
    # For delta connections, kv is line-to-line voltage - use directly
    if conn == :delta
        return kv * 1000
    end
    # For wye connections: 3-phase uses LL kv (divide by sqrt(3)), single-phase uses LN kv directly
    return modeled_phase_count(phases) == 3 ? kv * 1000 / sqrt(3) : kv * 1000
end

"""
    transformer_winding_voltage(winding)

Return the winding voltage in volts used by transformer ratio calculations.

OpenDSS transformer nameplate kV semantics are connection/phase dependent:
- 3-phase wye windings are specified as line-line kV, so convert to LN.
- Delta windings use winding (line-line) voltage directly.
- Single-phase windings use winding voltage directly.
"""
function transformer_winding_voltage(winding)
    voltage = winding.kv * 1000
    if winding.conn == :delta
        return voltage
    end
    return modeled_phase_count(winding.bus.phases) == 3 ? voltage / sqrt(3) : voltage
end

function phase_pairs(phases::Vector{Int})
    phases = modeled_phases(phases; preserve_order = true)
    if length(phases) == 3
        return [(1, 2), (2, 3), (3, 1)]
    elseif length(phases) == 2
        return [(phases[1], phases[2])]
    elseif length(phases) == 1
        # Single phase: connect to ground.
        # Note: callers with delta connection should handle this case
        # explicitly (single-phase delta connects to the next cyclic phase).
        return [(only(phases), 0)]
    end
    error("Unsupported phase configuration $phases")
end

function lookup_node_index(ybus::YBusModel, bus::String, phase::Int)
    get(ybus.network_index, BusPhase(bus, phase), 0)
end

function stamp_triplet!(rows::Vector{Int}, cols::Vector{Int}, vals::Vector{ComplexF64}, indices_a::Vector{Int}, indices_b::Vector{Int}, block::AbstractMatrix{ComplexF64})
    for (i_local, i_global) in enumerate(indices_a), (j_local, j_global) in enumerate(indices_b)
        value = block[i_local, j_local]
        iszero(value) && continue
        push!(rows, i_global)
        push!(cols, j_global)
        push!(vals, value)
    end
end
