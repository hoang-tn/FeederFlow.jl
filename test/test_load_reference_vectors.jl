using Test
using FeederFlow

function manual_load_reference_vectors(network, ybus, noload)
    p_load_ref = zeros(Float64, length(ybus.network_order))
    q_load_ref = zeros(Float64, length(ybus.network_order))

    for load in network.loads
        pairs = FeederFlow.branch_pairs(load)
        powers = FeederFlow.branch_powers(load, length(pairs), network.base)

        for (pair, sbranch) in zip(pairs, powers)
            p_idx = FeederFlow.lookup_node_index(ybus, load.bus.bus, pair[1])
            p_idx == 0 && continue

            vp = get(noload.phase_voltages, FeederFlow.BusPhase(load.bus.bus, pair[1]), nothing)
            vp === nothing && continue

            if pair[2] == 0
                iszero(vp) && continue
                current = conj(sbranch / vp)
                terminal_power = vp * conj(current)
                p_load_ref[p_idx] += real(terminal_power)
                q_load_ref[p_idx] += imag(terminal_power)
                continue
            end

            q_idx = FeederFlow.lookup_node_index(ybus, load.bus.bus, pair[2])
            q_idx == 0 && continue

            vq = get(noload.phase_voltages, FeederFlow.BusPhase(load.bus.bus, pair[2]), nothing)
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

@testset "build_load_reference_vectors - delta loads" begin
    mktempdir() do dir
        dss = joinpath(dir, "delta_load.dss")
        write(dss, join([
            "Clear",
            "New Circuit.test bus1=sourcebus basekv=12.47 pu=1.0",
            "New Line.line bus1=sourcebus.1.2.3 bus2=loadbus.1.2.3 phases=3 length=1 units=mi",
            "New Linecode.lc nphases=3 r1=0.01 x1=0.02",
            "Edit Line.line linecode=lc",
            "New Load.ld phases=2 bus1=loadbus.1.3 conn=delta model=1 kv=4.16 kw=100 kvar=50",
        ], "\n"))

        network = FeederFlow.parse_file(dss)
        ybus = FeederFlow.build_y(network; regulator_model = :nonideal, epsilon = 1e-5)
        v_slack = FeederFlow.source_slack(network.source, network.base)
        noload = FeederFlow.compute_no_load(ybus; v_slack = v_slack)

        @test any(load.conn == :delta for load in network.loads)

        helper_p, helper_q = FeederFlow.build_load_reference_vectors(network, ybus, noload)
        expected_p, expected_q = manual_load_reference_vectors(network, ybus, noload)

        @test helper_p ≈ expected_p atol = 1e-12 rtol = 0.0
        @test helper_q ≈ expected_q atol = 1e-12 rtol = 0.0
        @test isapprox(sum(helper_p), sum(load.p_pu for load in network.loads); atol = 1e-12, rtol = 0.0)
        @test isapprox(sum(helper_q), sum(load.q_pu for load in network.loads); atol = 1e-12, rtol = 0.0)
    end
end
