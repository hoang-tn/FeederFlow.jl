"""
    build_y(network; regulator_model=:nonideal, epsilon=1e-6)

Assemble the feeder nodal admittance partitions (`Y`, `Y_NS`, `Y_SS`) and node
order/index maps as a `YBusModel`.
"""
function build_y(network::NetworkModel; regulator_model::Symbol = :nonideal, epsilon::Float64 = 1e-6)
    excluded = excluded_buses(network)
    include_shunt = true  # General DSS behavior includes shunt capacitance
    include_source_series_impedance = source_has_series_impedance(network.source)
    slack_bus_name = include_source_series_impedance ? source_internal_slack_bus(network.source) : network.slack_bus
    slack_phases = sort(network.source.phases)

    slack_order = BusPhase[BusPhase(slack_bus_name, phase) for phase in slack_phases]
    network_order = BusPhase[]
    available_phases = Dict{String,Vector{Int}}()
    for bus in network.buses
        bus.name in excluded && continue
        available_phases[bus.name] = copy(bus.phases)
        !include_source_series_impedance && bus.name == network.slack_bus && continue
        for phase in sort(bus.phases)
            push!(network_order, BusPhase(bus.name, phase))
        end
    end
    if include_source_series_impedance
        available_phases[slack_bus_name] = copy(slack_phases)
    end
    all_order = vcat(network_order, slack_order)
    network_index = Dict(node => idx for (idx, node) in enumerate(network_order))
    all_index = Dict(node => idx for (idx, node) in enumerate(all_order))

    rows = Int[]
    cols = Int[]
    vals = ComplexF64[]

    for line in network.lines
        line.is_switch && !line.is_closed && continue  # skip open switches
        (line.from.bus in excluded || line.to.bus in excluded) && continue
        stamp_line!(rows, cols, vals, all_index, line; include_shunt, ybase = network.base.Ybase)
    end

    for transformer in network.transformers
        stamp_transformer!(rows, cols, vals, all_index, network.base; regulator_model, epsilon, transformer)
    end
    for transformer in network.regulators
        stamp_transformer!(rows, cols, vals, all_index, network.base; regulator_model, epsilon, transformer)
    end

    for capacitor in network.capacitors
        capacitor.bus.bus in excluded && continue
        stamp_capacitor!(rows, cols, vals, all_index, network.base, capacitor)
    end

    if include_source_series_impedance
        stamp_source_impedance!(rows, cols, vals, all_index, network; epsilon)
    end

    total = length(all_order)
    Ynet = sparse(rows, cols, vals, total, total)
    n = length(network_order)
    Y = Ynet[1:n, 1:n]
    Y_NS = Ynet[1:n, n + 1:end]
    Y_SS = Ynet[n + 1:end, n + 1:end]
    return YBusModel(
        Ynet,
        Y,
        Y_NS,
        Y_SS,
        network_order,
        slack_order,
        all_order,
        network_index,
        all_index,
        available_phases,
        spzeros(ComplexF64, n, n),
    )
end

"""
    excluded_buses(network)

Return set of buses to exclude from Y-bus assembly.
For the main DSS path, only open switch buses are excluded to avoid singular
isolated nodes. Regulator secondary buses remain in the network and are stamped
through the generic transformer model.
"""
function excluded_buses(network::NetworkModel)
    excluded = Set{String}()
    for bus in network.buses
        endswith(bus.name, "_open") && push!(excluded, bus.name)
    end
    return excluded
end

function terminal_indices(indexmap::Dict{BusPhase,Int}, term::TerminalSpec)
    return [get(indexmap, BusPhase(term.bus, phase), 0) for phase in 1:3]
end

function stamp_selected_block!(rows, cols, vals, indices_a::Vector{Int}, indices_b::Vector{Int}, block::Matrix{ComplexF64})
    for i_local in 1:3
        i_global = indices_a[i_local]
        i_global == 0 && continue
        for j_local in 1:3
            j_global = indices_b[j_local]
            j_global == 0 && continue
            value = block[i_local, j_local]
            iszero(value) && continue
            push!(rows, i_global)
            push!(cols, j_global)
            push!(vals, value)
        end
    end
end

function lift_phase_block(local_block::Matrix{ComplexF64}, phases::Vector{Int})
    block = zeros(ComplexF64, 3, 3)
    active = modeled_phases(phases; preserve_order = true)
    for (i_local, i_global) in enumerate(active)
        i_local > size(local_block, 1) && continue
        for (j_local, j_global) in enumerate(active)
            j_local > size(local_block, 2) && continue
            block[i_global, j_global] = local_block[i_local, j_local]
        end
    end
    return block
end

function source_bus_vbase(network::NetworkModel)
    if haskey(network.buses, network.source.bus)
        vbase = network.buses[network.source.bus].vbase
        if isfinite(vbase) && vbase > 0
            return vbase
        end
    end
    return kv_to_vbase(network.source.basekv, network.source.phases)
end

function source_impedance_local_matrix_pu(network::NetworkModel)
    active = modeled_phases(network.source.phases; preserve_order = true)
    isempty(active) && return active, zeros(ComplexF64, 0, 0)

    # Single-global-base policy: source sequence impedances are stamped on the
    # same system impedance base used by lines/transformers.
    zbase_source = network.base.Zbase
    z1 = complex(network.source.r1, network.source.x1) / zbase_source
    z0 = complex(network.source.r0, network.source.x0) / zbase_source

    local_z = if length(active) == 3
        sequence_to_phase_matrix(z1, z0)
    else
        Matrix{ComplexF64}(Diagonal(fill(z1, length(active))))
    end
    return active, local_z
end

function stamp_source_impedance!(rows, cols, vals, indexmap::Dict{BusPhase,Int}, network::NetworkModel; epsilon::Float64 = 1e-9)
    source_has_series_impedance(network.source) || return
    active, local_z = source_impedance_local_matrix_pu(network)
    isempty(active) && return
    maximum(abs.(local_z)) <= eps(Float64) && return

    regularized = local_z + Matrix{ComplexF64}(Diagonal(fill(ComplexF64(epsilon, 0.0), size(local_z, 1))))
    local_y = try
        rcond(local_z) < 1e-12 ? pinv(regularized) : inv(local_z)
    catch
        pinv(regularized)
    end

    source_term = terminal(network.source.bus, active; preserve_order = true)
    slack_term = terminal(source_internal_slack_bus(network.source), active; preserve_order = true)
    idx_source = terminal_indices(indexmap, source_term)
    idx_slack = terminal_indices(indexmap, slack_term)
    y_block = lift_phase_block(local_y, active)

    stamp_selected_block!(rows, cols, vals, idx_source, idx_source, y_block)
    stamp_selected_block!(rows, cols, vals, idx_slack, idx_slack, y_block)
    stamp_selected_block!(rows, cols, vals, idx_source, idx_slack, -y_block)
    stamp_selected_block!(rows, cols, vals, idx_slack, idx_source, -y_block)
end

"""
    unit_to_kft(units::String) -> Float64

Convert OpenDSS length unit to equivalent kft (1000 feet) multiplier.
This normalizes all length units to a common basis for impedance calculations.

OpenDSS linecode units: mi, kft, km, m, ft, in, cm, none
- "none" means values are already per-unit-length (multiplier = 1.0)
- Other units convert to kft basis
"""
function unit_to_kft(units::String)
    u = lowercase(units)
    u == "none" && return 1.0
    u == "kft" && return 1.0
    u == "mi" && return 5.28  # 1 mile = 5.28 kft (5280 ft / 1000)
    u == "km" && return 3.28084  # 1 km = 3280.84 ft / 1000 = 3.28084 kft
    u == "m" && return 0.00328084  # 1 m = 3.28084 ft / 1000 = 0.00328084 kft
    u == "ft" && return 0.001  # 1 ft = 0.001 kft
    u == "in" && return 0.001 / 12  # 1 inch = 1/12 ft = 0.001/12 kft
    u == "cm" && return 0.0000328084  # 1 cm = 0.0328084 ft / 1000 kft
    @warn "Unknown DSS length unit: '$units'. Treating as 'none' (multiplier = 1.0)."
    return 1.0
end

function _invert_series_impedance(z::Matrix{ComplexF64})
    n = size(z, 1)
    if norm(z) < 1e-12
        # BUSBAR/fuse/ELB geometry entries can be all-zero; use a stiff tie impedance.
        z = z + Matrix{ComplexF64}(Diagonal(fill(ComplexF64(1e-6, 0.0), n)))
    end
    return inv(z)
end

function line_admittance(line::LineDevice; include_shunt::Bool = true, ybase::Float64 = 1.0)
    # Total impedance = per-unit-length * effective length.
    # line.length has already been normalized to match the linecode's units
    # (see unit conversion logic in parse_line). No further conversion needed here.
    z = complex.(line.rmatrix, line.xmatrix) * line.length
    yseries = _invert_series_impedance(z) / ybase
    yshunt = include_shunt ? (im * 2pi * line.basefreq * (line.cmatrix * 1e-9) * line.length) / ybase : zeros(ComplexF64, size(z))
    return yseries, yshunt
end

function stamp_line!(rows, cols, vals, indexmap, line::LineDevice; include_shunt::Bool = true, ybase::Float64 = 1.0)
    yseries, yshunt = line_admittance(line; include_shunt, ybase)
    self = yseries + 0.5 .* yshunt
    mutual = -yseries
    from_indices = terminal_indices(indexmap, line.from)
    to_indices = terminal_indices(indexmap, line.to)
    self_block = lift_phase_block(self, line.phases)
    mutual_block = lift_phase_block(mutual, line.phases)
    stamp_selected_block!(rows, cols, vals, from_indices, from_indices, self_block)
    stamp_selected_block!(rows, cols, vals, to_indices, to_indices, self_block)
    stamp_selected_block!(rows, cols, vals, from_indices, to_indices, mutual_block)
    stamp_selected_block!(rows, cols, vals, to_indices, from_indices, mutual_block)
end

"""
    transformer_series_impedance(transformer, base; epsilon=1e-5)

Compute the per-unit series impedance of a two-winding transformer,
normalized to the system base.

The formula converts the nameplate `zpercent` (resistance + reactance) to
per-unit on the system base:
  `z = zpercent / 100 * (Sbase / S_rated) * (V_secondary_tapped / Vbase)^2`

When the total impedance magnitude is below `epsilon`, a small imaginary
term is injected to avoid singularity in the admittance.
"""
function transformer_series_impedance(transformer::TransformerDevice, base::BaseQuantities; epsilon::Float64 = 1e-5)
    winding = first(transformer.windings)
    downstream = length(transformer.windings) >= 2 ? transformer.windings[end] : winding
    resistance = winding.resistance + downstream.resistance
    zpercent = complex(resistance, transformer.xhl_percent) / 100
    rated = winding_rated_va(winding)
    # Use transformer_winding_voltage to correctly handle line-line vs line-neutral
    # for 3-phase wye vs single-phase windings
    voltage_factor = (transformer_winding_voltage(downstream) * max(downstream.tap, epsilon) / base.Vbase)^2
    z = zpercent * (base.Sbase / rated) * voltage_factor
    abs(z) < epsilon && (z += im * epsilon)
    return z
end

"""
    regulator_series_impedance(transformer, base; epsilon=1e-5)

Compute the per-unit series impedance for a regulator, using the standard
nameplate impedance scaling (same formula as `transformer_series_impedance`).

For open-delta regulator groups, see `open_delta_regulator_series_impedance`
which applies a 3x multiplier to match the MATLAB benchmark conventions.
"""
function regulator_series_impedance(transformer::TransformerDevice, base::BaseQuantities; epsilon::Float64 = 1e-5)
    winding = first(transformer.windings)
    downstream = length(transformer.windings) >= 2 ? transformer.windings[end] : winding
    resistance = winding.resistance + downstream.resistance
    zpercent = complex(resistance, transformer.xhl_percent) / 100
    rated = winding_rated_va(winding)
    # Use transformer_winding_voltage to correctly handle line-line vs line-neutral
    voltage_factor = (transformer_winding_voltage(downstream) * max(downstream.tap, epsilon) / base.Vbase)^2
    z = zpercent * (base.Sbase / rated) * voltage_factor
    abs(z) < epsilon && (z += im * epsilon)
    return z
end

function open_delta_regulator_series_impedance(transformer::TransformerDevice, base::BaseQuantities; epsilon::Float64 = 1e-5)
    winding = first(transformer.windings)
    downstream = length(transformer.windings) >= 2 ? transformer.windings[end] : winding
    resistance = winding.resistance + downstream.resistance

    # IEEE 37/123 open-delta regulators are benchmarked as a two-unit equivalent
    # where the series leakage term is three times the per-unit nameplate leakage.
    # This matches the MATLAB benchmark's ztReg construction and keeps the
    # reduced Y-bus and secondary-voltage reconstruction aligned with OpenDSS.
    zpercent = complex(resistance, transformer.xhl_percent) / 100
    rated = winding_rated_va(winding)
    # Use transformer_winding_voltage to correctly handle connection type
    voltage_factor = (transformer_winding_voltage(downstream) * max(downstream.tap, epsilon) / base.Vbase)^2
    z = 3 * zpercent * (base.Sbase / rated) * voltage_factor
    abs(z) < epsilon && (z += im * epsilon)
    return z
end

function transformer_ratio(w1::TransformerWinding, w2::TransformerWinding; epsilon::Float64 = 1e-6)
    v1 = max(transformer_winding_voltage(w1), epsilon)
    v2 = max(transformer_winding_voltage(w2), epsilon)
    t1 = max(w1.tap, epsilon)
    t2 = max(w2.tap, epsilon)
    ratio = (v1 * t1) / (v2 * t2)
    return ComplexF64(ratio)
end

function delta_wye_coupling_matrix()
    # OpenDSS 3-phase delta-wye coupling aligns the delta branch equations
    # with a cyclic phase map and sign inversion on the wye-side coupling terms.
    return ComplexF64[
        0 -1 0
        0 0 -1
        -1 0 0
    ]
end

function connection_matrix(conn::Symbol, phases::Vector{Int})
    conn == :wye && return wye_incidence(phases)
    return delta_incidence(phases)
end

"""
    transformer_scale(conn_a, conn_b, rows_a, rows_b)

Compute the connection-type scaling factor for transformer admittance stamping.

For 3-phase transformers with delta-wye connections, the delta_wye_coupling_matrix
handles phase relationships, so this returns 1.0. For single-phase transformers
with different connection types, special handling may be needed based on matrix
dimensions.

Standard cases:
- wye-wye: 1.0 (no additional scaling)
- delta-delta: 1.0 (no additional scaling)  
- delta-wye (3-phase): 1.0 (coupling matrix handles phase shift)
- wye-delta (3-phase): 1.0 (coupling matrix handles phase shift)
- single-phase delta: handled via connection matrix dimensions
"""
function transformer_scale(conn_a::Symbol, conn_b::Symbol, rows_a::Int, rows_b::Int)
    return 1.0
end

function winding_rated_va(winding::TransformerWinding)
    phase_factor = modeled_phase_count(winding.bus.phases) == 3 ? 3.0 : 1.0
    return max(winding.kva * 1000 / phase_factor, 1.0)
end

function transformer_regularization(C::AbstractMatrix{ComplexF64}, conn::Symbol, y::ComplexF64, epsilon::Float64)
    conn == :delta || return zeros(ComplexF64, 3, 3)
    active = vec(sum(abs2, C; dims = 1))
    mask = Diagonal(ComplexF64[(value > 0 ? 1.0 : 0.0) for value in active])

    # Keep a tiny diagonal only for fully active closed-delta blocks to
    # improve global Y-bus conditioning without materially affecting parity.
    if count(value -> value > 0, active) == 3
        return abs(y) * (epsilon^2) .* mask
    end

    return abs(y) * epsilon .* mask
end

function transformer_pair_series_impedance(wi::TransformerWinding, wj::TransformerWinding, xpercent::Float64, reference::TransformerWinding, base::BaseQuantities; epsilon::Float64)
    zpercent = complex(wi.resistance + wj.resistance, xpercent) / 100
    rated = winding_rated_va(wi)
    voltage_factor = (transformer_winding_voltage(reference) * max(reference.tap, epsilon) / base.Vbase)^2
    z = zpercent * (base.Sbase / rated) * voltage_factor
    abs(z) < epsilon && (z += im * epsilon)
    return z
end

function transformer_pair_xpercent(transformer::TransformerDevice, i::Int, j::Int)
    a, b = minmax(i, j)
    a == 1 && b == 2 && return transformer.xhl_percent
    a == 1 && b == 3 && return transformer.xht_percent
    a == 2 && b == 3 && return transformer.xlt_percent
    error("Unsupported transformer winding pair ($i, $j) in $(transformer.name)")
end

function transformer_winding_ratio(winding::TransformerWinding, reference::TransformerWinding; epsilon::Float64)
    numerator = transformer_winding_voltage(winding) * max(winding.tap, epsilon)
    denominator = transformer_winding_voltage(reference) * max(reference.tap, epsilon)
    return ComplexF64(numerator / max(denominator, epsilon))
end

function stamp_winding_admittance_matrix!(rows, cols, vals, indexmap, windings::Vector{TransformerWinding}, yprimitive::Matrix{ComplexF64}, reference::TransformerWinding; epsilon::Float64)
    matrices = [connection_matrix(w.conn, w.bus.phases) for w in windings]
    ratios = [transformer_winding_ratio(w, reference; epsilon) for w in windings]
    indices = [terminal_indices(indexmap, w.bus) for w in windings]

    for i in eachindex(windings), j in eachindex(windings)
        yij = yprimitive[i, j]
        iszero(yij) && continue
        block = (yij / (conj(ratios[i]) * ratios[j])) .* (matrices[i]' * matrices[j])
        stamp_selected_block!(rows, cols, vals, indices[i], indices[j], block)
    end
end

function three_winding_primitive_admittance(transformer::TransformerDevice, base::BaseQuantities; epsilon::Float64)
    length(transformer.windings) == 3 || error("Only three-winding primitive admittance is supported")
    w = transformer.windings
    reference = w[2]
    z12 = transformer_pair_series_impedance(w[1], w[2], transformer_pair_xpercent(transformer, 1, 2), reference, base; epsilon)
    z13 = transformer_pair_series_impedance(w[1], w[3], transformer_pair_xpercent(transformer, 1, 3), reference, base; epsilon)
    z23 = transformer_pair_series_impedance(w[2], w[3], transformer_pair_xpercent(transformer, 2, 3), reference, base; epsilon)

    zleak = ComplexF64[
        (z12 + z13 - z23) / 2,
        (z12 + z23 - z13) / 2,
        (z13 + z23 - z12) / 2,
    ]
    for idx in eachindex(zleak)
        abs(zleak[idx]) < epsilon && (zleak[idx] += im * epsilon)
    end

    y = 1 ./ zleak
    ysum = sum(y)
    abs(ysum) < epsilon && (ysum += im * epsilon)
    return Diagonal(y) - (y * transpose(y)) / ysum
end

function stamp_three_winding_transformer!(rows, cols, vals, indexmap, base; epsilon::Float64, transformer::TransformerDevice)
    yprimitive = three_winding_primitive_admittance(transformer, base; epsilon)
    stamp_winding_admittance_matrix!(rows, cols, vals, indexmap, transformer.windings, yprimitive, transformer.windings[2]; epsilon)
end

function stamp_transformer!(rows, cols, vals, indexmap, base; regulator_model::Symbol, epsilon::Float64, transformer::TransformerDevice)
    length(transformer.windings) >= 2 || return
    if length(transformer.windings) == 3
        stamp_three_winding_transformer!(rows, cols, vals, indexmap, base; epsilon, transformer)
        return
    elseif length(transformer.windings) > 3
        error("Transformer $(transformer.name) has $(length(transformer.windings)) windings; only two- and three-winding transformers are supported")
    end

    w1 = transformer.windings[1]
    w2 = transformer.windings[2]
    z = transformer.is_regulator ? regulator_series_impedance(transformer, base; epsilon) :
        transformer_series_impedance(transformer, base; epsilon)
    transformer.is_regulator && regulator_model == :ideal && (z = im * epsilon)
    y = 1 / z
    C1 = connection_matrix(w1.conn, w1.bus.phases)
    C2 = connection_matrix(w2.conn, w2.bus.phases)
    if size(C1, 1) == 3 && size(C2, 1) == 3
        if w1.conn == :delta && w2.conn == :wye
            C2 = C2 * delta_wye_coupling_matrix()
        elseif w1.conn == :wye && w2.conn == :delta
            C1 = C1 * adjoint(delta_wye_coupling_matrix())
        end
    end
    scale = transformer_scale(w1.conn, w2.conn, size(C1, 1), size(C2, 1))
    a = transformer_ratio(w1, w2; epsilon)
    self_1 = scale * (y / (a * conj(a))) .* (C1' * C1)
    self_2 = scale * y .* (C2' * C2)
    self_1 += transformer_regularization(C1, w1.conn, y, epsilon)
    self_2 += transformer_regularization(C2, w2.conn, y, epsilon)
    cross_12 = scale * (-y / conj(a)) .* (C1' * C2)
    cross_21 = scale * (-y / a) .* (C2' * C1)
    idx1 = terminal_indices(indexmap, w1.bus)
    idx2 = terminal_indices(indexmap, w2.bus)
    stamp_selected_block!(rows, cols, vals, idx1, idx1, self_1)
    stamp_selected_block!(rows, cols, vals, idx2, idx2, self_2)
    stamp_selected_block!(rows, cols, vals, idx1, idx2, cross_12)
    stamp_selected_block!(rows, cols, vals, idx2, idx1, cross_21)
end

function capacitor_branch_voltage(capacitor::CapacitorDevice)
    # For delta connections, kv is already line-to-line voltage
    if capacitor.conn == :delta
        return capacitor.kv * 1000
    end
    # For single-phase wye or line-to-neutral, kv is the phase voltage
    if length(capacitor.phases) == 1
        return capacitor.kv * 1000
    end
    # For 3-phase wye, kv is line-to-line, convert to line-to-neutral
    return capacitor.kv * 1000 / sqrt(3)
end

function stamp_capacitor!(rows, cols, vals, indexmap, base::BaseQuantities, capacitor::CapacitorDevice)
    vcap = max(capacitor_branch_voltage(capacitor), eps(Float64))
    scale = (base.Vbase / vcap)^2
    for (offset, phase) in enumerate(capacitor.phases)
        idx = get(indexmap, BusPhase(capacitor.bus.bus, phase), 0)
        idx == 0 && continue
        y = im * capacitor.kvar[offset] * 1000 / base.Sbase * scale
        push!(rows, idx)
        push!(cols, idx)
        push!(vals, y)
    end
end

"""
    open_delta_regulator_groups(network)

Identify open-delta regulator groups in the network topology.

An open-delta group consists of two single-phase regulators (one on phases
AB, one on phases BC) sharing the same primary bus, with a single downstream
line from the secondary bus. Returns an array of `NamedTuple`s with
`primary`, `secondary`, `remote`, `line`, `bridge_lines`, and `transformers`.

Returns empty array if no matching topology is found.
"""
function open_delta_regulator_groups(network::NetworkModel)
    groups = Dict{String,Vector{TransformerDevice}}()
    for regulator in network.regulators
        length(regulator.windings) >= 2 || continue
        secondary = regulator.windings[2].bus.bus
        push!(get!(groups, secondary, TransformerDevice[]), regulator)
    end

    result = NamedTuple[]
    for (secondary, transformers) in groups
        length(transformers) >= 2 || continue
        all(all(w.conn == :delta for w in reg.windings[1:2]) for reg in transformers) || continue

        primary_buses = unique(reg.windings[1].bus.bus for reg in transformers)
        length(primary_buses) == 1 || continue
        primary = only(primary_buses)

        phase_sets = sort([Tuple(sort(reg.windings[1].bus.phases)) for reg in transformers])
        phase_sets == [(1, 2), (2, 3)] || continue

        downstream = filter(line ->
            (line.from.bus == secondary && line.to.bus != primary) ||
            (line.to.bus == secondary && line.from.bus != primary),
            network.lines,
        )
        length(downstream) == 1 || continue
        line = only(downstream)
        remote = line.from.bus == secondary ? line.to.bus : line.from.bus
        bridge_lines = filter(local_line ->
            (local_line.from.bus == secondary && local_line.to.bus == primary) ||
            (local_line.to.bus == secondary && local_line.from.bus == primary),
            network.lines,
        )
        push!(result, (
            primary = primary,
            secondary = secondary,
            remote = remote,
            line = line,
            bridge_lines = bridge_lines,
            transformers = transformers,
        ))
    end
    return result
end

three_phase_indices(indexmap, bus::String) = [get(indexmap, BusPhase(bus, phase), 0) for phase in 1:3]

# Helper for stamping 4 admittance blocks between two buses.
# Currently used only by `stamp_open_delta_regulator_group!` via individual
# `stamp_selected_block!` calls; this convenience wrapper is kept for readability.
function stamp_four_blocks!(rows, cols, vals, idx_n, idx_m, nn, nm, mn, mm)
    stamp_selected_block!(rows, cols, vals, idx_n, idx_n, nn)
    stamp_selected_block!(rows, cols, vals, idx_n, idx_m, -nm)
    stamp_selected_block!(rows, cols, vals, idx_m, idx_n, -mn)
    stamp_selected_block!(rows, cols, vals, idx_m, idx_m, mm)
end

function kron_reduce_partition(matrix::AbstractMatrix{<:Complex}, keep::Vector{Int}, eliminate::Vector{Int}; singular_tol::Float64 = 1e-11)
    Y = Matrix{ComplexF64}(matrix)
    isempty(eliminate) && return Matrix{ComplexF64}(Y[keep, keep])
    Ykk = Y[keep, keep]
    Yke = Y[keep, eliminate]
    Yek = Y[eliminate, keep]
    Yee = Y[eliminate, eliminate]
    projector = try
        rcond(Yee) < singular_tol ? pinv(Yee) * Yek : Yee \ Yek
    catch
        pinv(Yee) * Yek
    end
    return Matrix{ComplexF64}(Ykk - Yke * projector)
end

function open_delta_regulator_parameters(group, base::BaseQuantities; epsilon::Float64 = 1e-6)
    reg_ab = findfirst(reg -> sort(reg.windings[1].bus.phases) == [1, 2], group.transformers)
    reg_bc = findfirst(reg -> sort(reg.windings[1].bus.phases) == [2, 3], group.transformers)
    (reg_ab === nothing || reg_bc === nothing) && return nothing

    transformer_ab = group.transformers[reg_ab]
    transformer_bc = group.transformers[reg_bc]
    ar_ab = 1 / max(transformer_ab.windings[2].tap, epsilon)
    ar_bc = 1 / max(transformer_bc.windings[2].tap, epsilon)

    Av = ComplexF64[
        ar_ab (1 - ar_ab) 0
        0 1 0
        0 (1 - ar_bc) ar_bc
    ]
    Ai = ComplexF64[
        1 / ar_ab 0 0
        1 - 1 / ar_ab 1 1 - 1 / ar_bc
        0 0 1 / ar_bc
    ]
    Zreg = zeros(ComplexF64, 3, 3)
    Zreg[1, 1] = open_delta_regulator_series_impedance(transformer_ab, base; epsilon)
    Zreg[3, 3] = open_delta_regulator_series_impedance(transformer_bc, base; epsilon)
    return (; Av, Ai, invAv = inv(Av), Zreg)
end

function stamp_open_delta_regulator_group!(rows, cols, vals, indexmap, base::BaseQuantities, regulator_model::Symbol, epsilon::Float64, group; include_shunt::Bool = true)
    open_delta_regulator_parameters(group, base; epsilon) === nothing && return

    local_nodes = BusPhase[]
    for bus in (group.primary, group.secondary, group.remote)
        for phase in 1:3
            push!(local_nodes, BusPhase(bus, phase))
        end
    end
    local_index = Dict(node => idx for (idx, node) in enumerate(local_nodes))

    local_rows = Int[]
    local_cols = Int[]
    local_vals = ComplexF64[]

    for transformer in group.transformers
        stamp_transformer!(local_rows, local_cols, local_vals, local_index, base; regulator_model, epsilon, transformer)
    end
    stamp_line!(local_rows, local_cols, local_vals, local_index, group.line; include_shunt, ybase = base.Ybase)

    Yfull = Matrix(sparse(local_rows, local_cols, local_vals, length(local_nodes), length(local_nodes)))
    Yeq = kron_reduce_partition(Yfull, Int[1, 2, 3, 7, 8, 9], Int[4, 5, 6])

    idx_n = three_phase_indices(indexmap, group.primary)
    idx_m = three_phase_indices(indexmap, group.remote)
    stamp_selected_block!(rows, cols, vals, idx_n, idx_n, Yeq[1:3, 1:3])
    stamp_selected_block!(rows, cols, vals, idx_n, idx_m, Yeq[1:3, 4:6])
    stamp_selected_block!(rows, cols, vals, idx_m, idx_n, Yeq[4:6, 1:3])
    stamp_selected_block!(rows, cols, vals, idx_m, idx_m, Yeq[4:6, 4:6])
end
