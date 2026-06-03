using Test
using FeederFlow

@testset "Regulator secondary voltage handling - benchmark feeders (general)" begin
    cases = (
        ("IEEE13", IEEE13_DSS),
        ("IEEE37", IEEE37_DSS),
        ("IEEE123", IEEE123_DSS),
        ("IEEE240", IEEE240_DSS),
        ("IEEE906", IEEE906_DSS),
    )

    for (network_name, dss_path) in cases
        @testset "$network_name" begin
            network = FeederFlow.parse_file(dss_path)
            bundle = FeederFlow.solve_power_flow(network; max_iter = 20, tol = 1e-5)
            @test bundle.result.converged

            # In the general Y-bus path, regulator secondary buses are included directly,
            # so no post-filled voltages should be needed.
            secondary = FeederFlow.compute_regulator_secondary_voltages(bundle)
            @test isempty(secondary)

            for regulator in network.regulators
                length(regulator.windings) >= 2 || continue
                sec_winding = regulator.windings[2]
                for phase in sec_winding.bus.phases
                    bp = BusPhase(sec_winding.bus.bus, phase)
                    @test get(bundle.ybus.all_index, bp, 0) > 0
                    @test haskey(bundle.result.phase_voltages, bp)
                    @test isfinite(bundle.result.phase_voltages[bp])
                end
            end
        end
    end
end
