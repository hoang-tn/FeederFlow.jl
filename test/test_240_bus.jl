using Test
using FeederFlow
using LinearAlgebra
using SparseArrays

@testset "240-bus feeder regression" begin
    network = parse_file(IEEE240_DSS)

    @test network.slack_bus == "eq_source_bus"
    @test length(network.buses) == 436
    @test length(network.lines) == 239
    @test length(network.transformers) == 195
    @test length(network.regulators) == 3
    @test length(network.capacitors) == 2
    @test length(network.loads) == 194
    @test length(network.linecodes) == 8

    ybus = build_y(network; regulator_model = :nonideal, epsilon = 1e-5)
    # The 240-bus source has nonzero sequence impedance. FeederFlow models that
    # as a physical source-bus network node connected to an internal ideal slack.
    @test size(ybus.Y) == (906, 906)
    @test size(ybus.Y_NS) == (906, 3)
    @test size(ybus.Y_SS) == (3, 3)
    @test length(ybus.network_order) == 906
    @test length(ybus.slack_order) == 3
    @test isempty([
        node for (idx, node) in enumerate(ybus.network_order)
        if nnz(ybus.Ynet[idx, :]) + nnz(ybus.Ynet[:, idx]) == 0
    ])

    scales = [voltage_scale(network, node) for node in ybus.all_order]
    source_scale = FeederFlow.kv_to_vbase(network.source.basekv, network.source.phases) / network.base.Vbase
    @test length(scales) == size(ybus.Ynet, 1)
    @test all(isfinite, scales)
    @test all(>(0), scales)
    @test source_scale ≈ 5.0
    @test [voltage_scale(network, node) for node in ybus.slack_order] == fill(source_scale, 3)

    Y_scaled = FeederFlow.scaled_ybus_matrix(ybus, scales)
    D = spdiagm(0 => scales)
    @test Y_scaled == Matrix(D * ybus.Ynet * D)

    u = ComplexF64[complex(sin(i), cos(i)) for i in eachindex(scales)]
    v_system = scales .* u
    s_system = v_system .* conj.(ybus.Ynet * v_system)
    s_local = u .* conj.(Y_scaled * u)
    @test s_local ≈ s_system

    v_slack = FeederFlow.source_slack(network.source, network.base)
    noload = compute_no_load(ybus; v_slack = v_slack)
    @test length(noload.w) == 906
    @test isfinite(maximum(abs.(noload.w)))
    @test maximum(abs.(noload.w)) > 0

    bundle = solve_power_flow(network; regulator_model = :nonideal, epsilon = 1e-5, max_iter = 20, tol = 1e-5)
    @test bundle.result.converged
    @test bundle.result.iterations <= 20
    @test length(bundle.result.phase_voltages) == 906
    @test all(isfinite, bundle.result.voltages)
end
