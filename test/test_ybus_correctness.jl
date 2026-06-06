using Test
using FeederFlow
using LinearAlgebra

function assert_ybus_indexing_consistency(ybus::FeederFlow.YBusModel, network::FeederFlow.NetworkModel)
    n = length(ybus.network_order)
    s = length(ybus.slack_order)
    @test length(ybus.all_order) == n + s
    @test ybus.all_order == vcat(ybus.network_order, ybus.slack_order)
    @test length(unique(ybus.network_order)) == n
    @test length(unique(ybus.slack_order)) == s
    @test length(unique(ybus.all_order)) == n + s
    @test length(ybus.network_index) == n
    @test length(ybus.all_index) == n + s

    for (idx, node) in enumerate(ybus.network_order)
        @test get(ybus.network_index, node, 0) == idx
        @test get(ybus.all_index, node, 0) == idx
        @test haskey(ybus.available_phases, node.bus)
        @test node.phase in ybus.available_phases[node.bus]
    end
    for (offset, node) in enumerate(ybus.slack_order)
        @test !haskey(ybus.network_index, node)
        @test get(ybus.all_index, node, 0) == n + offset
        @test haskey(ybus.available_phases, node.bus)
        @test node.phase in ybus.available_phases[node.bus]
    end

    for bus in network.buses
        if haskey(ybus.available_phases, bus.name)
            @test sort(ybus.available_phases[bus.name]) == sort(bus.phases)
        end
    end
end

function assert_ybus_partition_consistency(ybus::FeederFlow.YBusModel; symmetry_tol::Float64 = 1e-8)
    n = length(ybus.network_order)
    s = length(ybus.slack_order)
    @test size(ybus.Ynet) == (n + s, n + s)
    @test size(ybus.Y) == (n, n)
    @test size(ybus.Y_NS) == (n, s)
    @test size(ybus.Y_SS) == (s, s)
    @test ybus.Y == ybus.Ynet[1:n, 1:n]
    @test ybus.Y_NS == ybus.Ynet[1:n, n + 1:end]
    @test ybus.Y_SS == ybus.Ynet[n + 1:end, n + 1:end]
    @test maximum(abs.(Matrix(ybus.Ynet - transpose(ybus.Ynet)))) <= symmetry_tol
end

function assert_open_switch_exclusions(ybus::FeederFlow.YBusModel, network::FeederFlow.NetworkModel)
    # Open switches should not be stamped in Y-bus
    for line in network.lines
        if line.is_switch && !line.is_closed
            from_idx = [get(ybus.all_index, FeederFlow.BusPhase(line.from.bus, p), 0) for p in line.phases]
            to_idx = [get(ybus.all_index, FeederFlow.BusPhase(line.to.bus, p), 0) for p in line.phases]
            indices = filter(>(0), [from_idx; to_idx])
            for idx in indices
                @test all(iszero, ybus.Ynet[idx, :])
                @test iszero(ybus.Ynet[idx, idx])
            end
        end
    end
end

function assert_regulator_secondary_inclusion(ybus::FeederFlow.YBusModel, network::FeederFlow.NetworkModel)
    buses_in_order = Set(node.bus for node in ybus.network_order)
    regulator_secondary = Set(
        regulator.windings[2].bus.bus for regulator in network.regulators if length(regulator.windings) >= 2
    )

    for bus in regulator_secondary
        @test haskey(ybus.available_phases, bus)
        @test bus in buses_in_order
    end
end

@testset "Y-bus correctness - IEEE13 (general)" begin
    network = parse_file(IEEE13_DSS)
    ybus = build_y(network)
    noload = compute_no_load(ybus)
    loads = build_load_model(network, ybus, noload)

    @test size(ybus.Y, 1) == length(ybus.network_order)
    @test size(ybus.Y, 2) == length(ybus.network_order)
    @test size(ybus.Y_NS, 2) == 3
    @test size(ybus.Y_SS) == (3, 3)
    @test !isempty(network.capacitors)
    assert_ybus_indexing_consistency(ybus, network)
    assert_ybus_partition_consistency(ybus)
    # IEEE13 has open-switch endpoints that still couple through other stamped devices,
    # so zero-row checks are not expected here.
    assert_regulator_secondary_inclusion(ybus, network)

    @test size(loads.YL) == size(ybus.Y)
    @test all(isfinite, loads.YL.nzval)
end

@testset "Y-bus correctness - IEEE123 (general)" begin
    network = parse_file(IEEE123_DSS)
    ybus = build_y(network)
    noload = compute_no_load(ybus)
    loads = build_load_model(network, ybus, noload)

    @test size(ybus.Y, 1) == length(ybus.network_order)
    @test size(ybus.Y, 2) == length(ybus.network_order)
    @test size(ybus.Y_NS, 2) == 3
    @test size(ybus.Y_SS) == (3, 3)
    @test !isempty(network.capacitors)
    assert_ybus_indexing_consistency(ybus, network)
    assert_ybus_partition_consistency(ybus)
    assert_open_switch_exclusions(ybus, network)
    assert_regulator_secondary_inclusion(ybus, network)

    @test size(loads.YL) == size(ybus.Y)
    @test all(isfinite, loads.YL.nzval)
end

@testset "Y-bus correctness - IEEE240 (general)" begin
    network = parse_file(IEEE240_DSS)
    ybus = build_y(network)
    noload = compute_no_load(ybus)
    loads = build_load_model(network, ybus, noload)

    @test size(ybus.Y, 1) == length(ybus.network_order)
    @test size(ybus.Y, 2) == length(ybus.network_order)
    @test size(ybus.Y_NS, 2) == 3
    @test size(ybus.Y_SS) == (3, 3)
    @test !isempty(network.capacitors)
    assert_ybus_indexing_consistency(ybus, network)
    assert_ybus_partition_consistency(ybus; symmetry_tol = 5e-8)
    assert_open_switch_exclusions(ybus, network)
    assert_regulator_secondary_inclusion(ybus, network)

    @test size(loads.YL) == size(ybus.Y)
    @test all(isfinite, loads.YL.nzval)
end

@testset "Y-bus correctness - IEEE906 (general)" begin
    network = parse_file(IEEE906_DSS)
    ybus = build_y(network)
    noload = compute_no_load(ybus)
    loads = build_load_model(network, ybus, noload)

    @test size(ybus.Y, 1) == length(ybus.network_order)
    @test size(ybus.Y, 2) == length(ybus.network_order)
    @test size(ybus.Y_NS, 2) == 3
    @test size(ybus.Y_SS) == (3, 3)
    @test isempty(network.capacitors)
    @test isempty(network.regulators)
    assert_ybus_indexing_consistency(ybus, network)
    assert_ybus_partition_consistency(ybus)
    assert_open_switch_exclusions(ybus, network)
    assert_regulator_secondary_inclusion(ybus, network)

    @test size(loads.YL) == size(ybus.Y)
    @test all(isfinite, loads.YL.nzval)
end
