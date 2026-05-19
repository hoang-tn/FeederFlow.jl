function load_mode(model::Int)
    if model == 1
        return :pq
    elseif model == 2
        return :z
    elseif model == 3
        return :motor
    elseif model == 4
        return :cvr
    elseif model == 5
        return :i
    end
    error("Unsupported OpenDSS load model $model")
end

function branch_pairs(load::LoadDevice)
    if load.conn == :wye
        return [(phase, 0) for phase in load.bus.phases]
    end
    # Delta connection: when only one phase is specified, OpenDSS interprets
    # this as a line-to-line load between the specified phase and the next
    # cyclic phase (1->2, 2->3, 3->1).
    if length(load.bus.phases) == 1
        @warn "Single-phase delta load $(load.name) at bus $(load.bus.bus) -- " *
              "connecting to next cyclic phase (1->2, 2->3, 3->1). " *
              "This is an OpenDSS convention-based inference." maxlog = 1
        p = only(load.bus.phases)
        next_phase = p % 3 + 1
        return [(p, next_phase)]
    end
    return phase_pairs(load.bus.phases)
end

function branch_powers(load::LoadDevice, pair_count::Int, base::BaseQuantities)
    # p_pu and q_pu are already in per-unit, no conversion needed
    total = complex(load.p_pu, load.q_pu)
    return fill(total / pair_count, pair_count)
end

function build_load_reference_vectors(network::NetworkModel, ybus::YBusModel, noload::NoLoadResult)
    n = length(ybus.network_order)
    p_load_ref = zeros(Float64, n)
    q_load_ref = zeros(Float64, n)

    for load in network.loads
        pairs = branch_pairs(load)
        isempty(pairs) && continue
        powers = branch_powers(load, length(pairs), network.base)

        for (pair, sbranch) in zip(pairs, powers)
            p_idx = lookup_node_index(ybus, load.bus.bus, pair[1])
            p_idx == 0 && continue

            vp = get(noload.phase_voltages, BusPhase(load.bus.bus, pair[1]), nothing)
            vp === nothing && continue

            if pair[2] == 0
                iszero(vp) && continue
                current = conj(sbranch / vp)
                terminal_power = vp * conj(current)
                p_load_ref[p_idx] += real(terminal_power)
                q_load_ref[p_idx] += imag(terminal_power)
                continue
            end

            q_idx = lookup_node_index(ybus, load.bus.bus, pair[2])
            q_idx == 0 && continue

            vq = get(noload.phase_voltages, BusPhase(load.bus.bus, pair[2]), nothing)
            vq === nothing && continue

            branch_voltage = vp - vq
            iszero(branch_voltage) && continue

            current = conj(sbranch / branch_voltage)
            terminal_power_p = vp * conj(current)
            terminal_power_q = -vq * conj(current)

            p_load_ref[p_idx] += real(terminal_power_p)
            q_load_ref[p_idx] += imag(terminal_power_p)
            p_load_ref[q_idx] += real(terminal_power_q)
            q_load_ref[q_idx] += imag(terminal_power_q)
        end
    end

    return p_load_ref, q_load_ref
end

function generator_branch_pairs(generator::GeneratorDevice)
    if generator.conn == :wye
        return [(phase, 0) for phase in generator.bus.phases]
    end
    if length(generator.bus.phases) == 1
        @warn "Single-phase delta generator $(generator.name) at bus $(generator.bus.bus) -- " *
              "connecting to next cyclic phase (1->2, 2->3, 3->1). " *
              "This is an OpenDSS convention-based inference." maxlog = 1
        p = only(generator.bus.phases)
        next_phase = p % 3 + 1
        return [(p, next_phase)]
    end
    return phase_pairs(generator.bus.phases)
end

function generator_branch_powers(generator::GeneratorDevice, pair_count::Int)
    p = generator.p_pu
    pf_mag = clamp(abs(generator.pf), 0.0, 1.0)
    q = if pf_mag <= eps(Float64)
        0.0
    else
        p * sqrt(max(1.0 - pf_mag^2, 0.0)) / pf_mag
    end
    generator.pf < 0 && (q = -q)
    q = clamp(q, generator.qmin_pu, generator.qmax_pu)
    # Represent generators as negative constant-power loads for the Z-bus solver.
    total = complex(-p, -q)
    return fill(total / pair_count, pair_count)
end

function branch_voltage_base_pu(load::LoadDevice, base::BaseQuantities)
    actual_voltage = kv_to_vbase(load.kv, load.bus.phases, load.conn)
    return actual_voltage / base.Vbase
end

function branch_voltage_base_pu(generator::GeneratorDevice, base::BaseQuantities)
    actual_voltage = kv_to_vbase(generator.kv, generator.bus.phases, generator.conn)
    return actual_voltage / base.Vbase
end

function nominal_branch_voltage(load::LoadDevice, pair::NTuple{2,Int}, noload::NoLoadResult, nominal_base_pu::Float64)
    vp = get(noload.phase_voltages, BusPhase(load.bus.bus, pair[1]), noload.slack[pair[1]])
    base = if pair[2] == 0
        vp
    else
        vq = get(noload.phase_voltages, BusPhase(load.bus.bus, pair[2]), noload.slack[pair[2]])
        vp - vq
    end
    mag = abs(base)
    mag > 0 || return ComplexF64(nominal_base_pu)
    return nominal_base_pu * base / mag
end

function add_branch_stamp!(rows, cols, vals, p::Int, q::Int, y::ComplexF64)
    push!(rows, p)
    push!(cols, p)
    push!(vals, y)
    if q != 0
        push!(rows, q)
        push!(cols, q)
        push!(vals, y)
        push!(rows, p)
        push!(cols, q)
        push!(vals, -y)
        push!(rows, q)
        push!(cols, p)
        push!(vals, -y)
    end
end

"""
    build_load_model(network, ybus, noload)

Construct ZIP load operators for the active network nodes and return a
`LoadModel` containing:
1. nonlinear current-injection contributions (PQ and I models), and
2. linear admittance stamps (`YL`) for Z-model loads.
"""
function build_load_model(network::NetworkModel, ybus::YBusModel, noload::NoLoadResult)
    rows = Int[]
    cols = Int[]
    vals = ComplexF64[]
    contributions = LoadContribution[]
    summary = Dict{Symbol,Int}(:pq => 0, :i => 0, :z => 0, :motor => 0, :cvr => 0)

    for load in network.loads
        pairs = branch_pairs(load)
        powers = branch_powers(load, length(pairs), network.base)
        mode = load_mode(load.model)
        summary[mode] = get(summary, mode, 0) + 1
        node_pairs = NTuple{2,Int}[]
        values = ComplexF64[]
        nominal_magnitudes = Float64[]
        vminpu = Float64[]
        vmaxpu = Float64[]
        cvrwatts = Float64[]
        cvrvars = Float64[]
        nominal_base_pu = branch_voltage_base_pu(load, network.base)
        for (pair, sbranch) in zip(pairs, powers)
            p_idx = lookup_node_index(ybus, load.bus.bus, pair[1])
            q_idx = pair[2] == 0 ? 0 : lookup_node_index(ybus, load.bus.bus, pair[2])
            p_idx == 0 && continue
            if pair[2] != 0 && q_idx == 0
                continue
            end
            push!(node_pairs, (p_idx, q_idx))
            push!(nominal_magnitudes, nominal_base_pu)
            push!(vminpu, load.vminpu)
            push!(vmaxpu, load.vmaxpu)
            if mode == :motor
                # OpenDSS model=3: constant-P, quadratic-Q.
                push!(cvrwatts, 0.0)
                push!(cvrvars, 2.0)
            else
                push!(cvrwatts, load.cvrwatts)
                push!(cvrvars, load.cvrvars)
            end
            if mode == :z
                ybranch = conj(sbranch / nominal_base_pu^2)
                add_branch_stamp!(rows, cols, vals, p_idx, q_idx, ybranch)
            elseif mode == :i
                # Store nominal branch power for OpenDSS model=5; current is
                # reconstructed each iteration from the instantaneous branch
                # voltage angle and nominal current magnitude.
                push!(values, sbranch)
            else
                push!(values, sbranch)
            end
        end
        mode == :z || push!(contributions, LoadContribution(load.conn, mode, node_pairs, values, nominal_magnitudes, vminpu, vmaxpu, cvrwatts, cvrvars))
    end

    for generator in network.generators
        pairs = generator_branch_pairs(generator)
        isempty(pairs) && continue
        powers = generator_branch_powers(generator, length(pairs))
        node_pairs = NTuple{2,Int}[]
        values = ComplexF64[]
        nominal_magnitudes = Float64[]
        vminpu = Float64[]
        vmaxpu = Float64[]
        cvrwatts = Float64[]
        cvrvars = Float64[]
        nominal_base_pu = branch_voltage_base_pu(generator, network.base)

        for (pair, sbranch) in zip(pairs, powers)
            p_idx = lookup_node_index(ybus, generator.bus.bus, pair[1])
            q_idx = pair[2] == 0 ? 0 : lookup_node_index(ybus, generator.bus.bus, pair[2])
            p_idx == 0 && continue
            if pair[2] != 0 && q_idx == 0
                continue
            end
            push!(node_pairs, (p_idx, q_idx))
            push!(values, sbranch)
            push!(nominal_magnitudes, nominal_base_pu)
            push!(vminpu, generator.vminpu)
            push!(vmaxpu, generator.vmaxpu)
            push!(cvrwatts, 0.0)
            push!(cvrvars, 0.0)
        end

        isempty(node_pairs) || push!(contributions, LoadContribution(generator.conn, :pq, node_pairs, values, nominal_magnitudes, vminpu, vmaxpu, cvrwatts, cvrvars))
    end

    YL = sparse(rows, cols, vals, length(ybus.network_order), length(ybus.network_order))
    return LoadModel(contributions, YL, summary)
end

function pair_voltage(v::AbstractVector{ComplexF64}, pair::NTuple{2,Int})
    p, q = pair
    q == 0 && return v[p]
    return v[p] - v[q]
end

function accumulate_pair_current!(currents::Vector{ComplexF64}, pair::NTuple{2,Int}, current::ComplexF64)
    p, q = pair
    currents[p] += current
    q == 0 || (currents[q] -= current)
    return currents
end

"""
    load_injection_current(value, voltage, voltage_pu, vminpu, vmaxpu) -> ComplexF64

Constant-power load current. Outside the OpenDSS voltage band, keep constant P/Q
rather than a ZIP surrogate `conj(S/V_nom^2)*V`, which is unstable when |V| grows.
"""
function load_injection_current(value::ComplexF64, voltage::ComplexF64, ::Float64,
                                ::Float64, ::Float64)
    abs(voltage) > 0 || return 0.0 + 0im
    return conj(value / voltage)
end

function load_currents(loads::LoadModel, v::Vector{ComplexF64})
    currents = zeros(ComplexF64, length(v))
    for contribution in loads.contributions
        for (idx, (pair, value)) in enumerate(zip(contribution.node_pairs, contribution.values))
            current = if contribution.mode == :pq
                voltage = pair_voltage(v, pair)
                nominal = contribution.nominal_magnitudes[idx]
                if abs(voltage) > 0 && nominal > 0
                    voltage_pu = abs(voltage) / nominal
                    load_injection_current(value, voltage, voltage_pu,
                        contribution.vminpu[idx], contribution.vmaxpu[idx])
                else
                    0.0 + 0im
                end
            elseif contribution.mode == :i
                voltage = pair_voltage(v, pair)
                nominal = contribution.nominal_magnitudes[idx]
                if nominal > 0 && abs(voltage) > 0
                    voltage_pu = abs(voltage) / nominal
                    if voltage_pu < contribution.vminpu[idx] || voltage_pu > contribution.vmaxpu[idx]
                        conj(value / nominal^2) * voltage
                    else
                        # OpenDSS model=5: constant current magnitude with fixed
                        # power factor relative to the present branch voltage.
                        (conj(value) / nominal) * (voltage / abs(voltage))
                    end
                else
                    0.0 + 0im
                end
            elseif contribution.mode == :cvr || contribution.mode == :motor
                voltage = pair_voltage(v, pair)
                nominal = contribution.nominal_magnitudes[idx]
                if abs(voltage) > 0 && nominal > 0
                    voltage_pu = abs(voltage) / nominal
                    if voltage_pu < contribution.vminpu[idx] || voltage_pu > contribution.vmaxpu[idx]
                        load_injection_current(value, voltage, voltage_pu,
                            contribution.vminpu[idx], contribution.vmaxpu[idx])
                    else
                        s = complex(
                            real(value) * voltage_pu^contribution.cvrwatts[idx],
                            imag(value) * voltage_pu^contribution.cvrvars[idx],
                        )
                        conj(s / voltage)
                    end
                else
                    0.0 + 0im
                end
            else
                value
            end
            accumulate_pair_current!(currents, pair, current)
        end
    end
    return currents
end
