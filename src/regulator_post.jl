"""
    compute_regulator_secondary_voltages(bundle)

Compute secondary-side regulator bus voltages after power flow solution.

In the general Y-bus path, regulator secondary buses are usually included directly,
so this function typically returns an empty dictionary. It remains as a fallback for
cases where a secondary node is intentionally excluded from the assembled system.
"""
function compute_regulator_secondary_voltages(bundle::AnalysisBundle)
    network = bundle.network
    ybus = bundle.ybus
    result = bundle.result

    isempty(network.regulators) && return Dict{BusPhase,ComplexF64}()

    secondary_voltages = Dict{BusPhase,ComplexF64}()

    for group in open_delta_regulator_groups(network)
        secondary_present = all(get(ybus.all_index, BusPhase(group.secondary, phase), 0) > 0 for phase in 1:3)
        secondary_present && continue
        params = open_delta_regulator_parameters(group, network.base)
        params === nothing && continue

        yseries, yshunt = line_admittance(group.line; include_shunt = true, ybase = network.base.Ybase)
        nn_local = yseries + 0.5 .* yshunt
        nm_local = yseries
        nn = lift_phase_block(nn_local, group.line.phases)
        nm = lift_phase_block(nm_local, group.line.phases)

        V_primary = ComplexF64[]
        V_remote = ComplexF64[]
        for phase in 1:3
            bp_primary = BusPhase(group.primary, phase)
            idx_primary = get(ybus.all_index, bp_primary, 0)
            push!(V_primary, idx_primary > 0 ? result.voltages[idx_primary] : bundle.noload.slack[findfirst(==(bp_primary), ybus.slack_order)])

            bp_remote = BusPhase(group.remote, phase)
            idx_remote = get(ybus.all_index, bp_remote, 0)
            push!(V_remote, idx_remote > 0 ? result.voltages[idx_remote] : 0.0 + 0im)
        end

        V_sec = (params.Av + params.Zreg * params.Ai * nn) \ (
            reshape(V_primary, 3, 1) - params.Zreg * params.Ai * nm * reshape(V_remote, 3, 1)
        )
        for phase in 1:3
            secondary_voltages[BusPhase(group.secondary, phase)] = V_sec[phase]
        end
    end

    for regulator in network.regulators
        length(regulator.windings) >= 2 || continue
        any(group -> regulator in group.transformers, open_delta_regulator_groups(network)) && continue

        w1 = regulator.windings[1]  # Primary winding
        w2 = regulator.windings[2]  # Secondary winding

        primary_bus = w1.bus.bus
        secondary_bus = w2.bus.bus

        # Get tap ratio (secondary/primary voltage ratio)
        tap = w2.tap
        iszero(tap) && (tap = 1.0)

        # Compute secondary voltage for each phase
        for phase in w1.bus.phases
            bp_primary = BusPhase(primary_bus, phase)
            bp_secondary = BusPhase(secondary_bus, phase)

            # If the secondary bus was included in the Y-bus, keep the solved value.
            get(ybus.all_index, bp_secondary, 0) > 0 && continue

            # Get primary voltage
            idx = get(ybus.all_index, bp_primary, 0)
            v_primary = if idx > 0
                result.voltages[idx]
            else
                slack_idx = findfirst(==(bp_primary), ybus.slack_order)
                if slack_idx !== nothing
                    bundle.noload.slack[slack_idx]
                else
                    0.0 + 0im
                end
            end

            # Secondary voltage is primary voltage divided by tap ratio
            # V_secondary = V_primary / tap  (for a step-down regulator with tap > 1)
            # But typically regulators step up, so tap < 1 and V_secondary > V_primary
            v_secondary = v_primary * tap

            secondary_voltages[bp_secondary] = v_secondary
        end
    end

    return secondary_voltages
end
