using Test
using FeederFlow
using LinearAlgebra
using SparseArrays

const COMPONENT_LINE_DSS = opendss_fixture_path("component_line_parity.dss")
const COMPONENT_TRANSFORMER_DSS = opendss_fixture_path("component_transformer_parity.dss")
const COMPONENT_CAPACITOR_DSS = opendss_fixture_path("component_capacitor_parity.dss")
const COMPONENT_LOAD_MODEL2_DSS = opendss_fixture_path("component_load_model2_parity.dss")

function parse_busphase_label(label::AbstractString)
    split_idx = findlast(==('.'), label)
    split_idx === nothing && error("Invalid bus-phase label '$label'")
    split_idx == 1 && error("Invalid bus-phase label '$label'")
    bus = label[1:split_idx - 1]
    phase = parse(Int, label[split_idx + 1:end])
    return BusPhase(bus, phase)
end

indexmap_from_labels(labels::Vector{String}) = Dict(parse_busphase_label(label) => idx for (idx, label) in enumerate(labels))

dense_stamp_matrix(rows, cols, vals, n::Int) = Matrix(sparse(rows, cols, vals, n, n))

component_names(table::FeederFlow.ComponentTable) = table.order

function feederflow_line_yprim(line::FeederFlow.LineDevice, base::FeederFlow.BaseQuantities)
    labels = vcat(
        [busphase_key(line.from.bus, phase) for phase in line.phases],
        [busphase_key(line.to.bus, phase) for phase in line.phases],
    )
    rows = Int[]
    cols = Int[]
    vals = ComplexF64[]
    FeederFlow.stamp_line!(rows, cols, vals, indexmap_from_labels(labels), line; include_shunt = true, ybase = base.Ybase)
    return (; yprim = dense_stamp_matrix(rows, cols, vals, length(labels)), labels)
end

function transformer_terminal_labels(transformer::FeederFlow.TransformerDevice)
    w1 = transformer.windings[1]
    w2 = transformer.windings[2]
    return vcat(
        [busphase_key(w1.bus.bus, phase) for phase in sort(w1.bus.phases)],
        [busphase_key(w2.bus.bus, phase) for phase in sort(w2.bus.phases)],
    )
end

function feederflow_transformer_yprim(transformer::FeederFlow.TransformerDevice, base::FeederFlow.BaseQuantities; epsilon::Float64 = 1e-6)
    labels = transformer_terminal_labels(transformer)
    rows = Int[]
    cols = Int[]
    vals = ComplexF64[]
    FeederFlow.stamp_transformer!(
        rows,
        cols,
        vals,
        indexmap_from_labels(labels),
        base;
        regulator_model = :nonideal,
        epsilon = epsilon,
        transformer = transformer,
    )
    return (; yprim = dense_stamp_matrix(rows, cols, vals, length(labels)), labels)
end

function feederflow_capacitor_yprim(capacitor::FeederFlow.CapacitorDevice, base::FeederFlow.BaseQuantities)
    labels = [busphase_key(capacitor.bus.bus, phase) for phase in sort(capacitor.phases)]
    rows = Int[]
    cols = Int[]
    vals = ComplexF64[]
    FeederFlow.stamp_capacitor!(rows, cols, vals, indexmap_from_labels(labels), base, capacitor)
    return (; yprim = dense_stamp_matrix(rows, cols, vals, length(labels)), labels)
end

function feederflow_open_delta_group_yprim(group, base::FeederFlow.BaseQuantities; epsilon::Float64 = 1e-6)
    labels = vcat(
        [busphase_key(group.primary, phase) for phase in 1:3],
        [busphase_key(group.remote, phase) for phase in 1:3],
    )
    rows = Int[]
    cols = Int[]
    vals = ComplexF64[]
    FeederFlow.stamp_open_delta_regulator_group!(
        rows,
        cols,
        vals,
        indexmap_from_labels(labels),
        base,
        :nonideal,
        epsilon,
        group;
        include_shunt = true,
    )
    return (; yprim = dense_stamp_matrix(rows, cols, vals, length(labels)), labels)
end

ybus_network_labels(ybus::FeederFlow.YBusModel) = [busphase_key(node.bus, node.phase) for node in ybus.network_order]

function assert_matrix_parity(observed::AbstractMatrix{<:Complex}, expected::AbstractMatrix{<:Complex}; component::AbstractString, atol::Float64, reltol::Float64)
    metrics = matrix_error_metrics(observed, expected)
    @info(
        "OpenDSS component admittance parity",
        component = component,
        max_abs = metrics.max_abs,
        rel_fro = metrics.rel_fro,
        worst_entry = metrics.worst,
        observed = metrics.observed,
        expected = metrics.expected,
    )
    @test metrics.max_abs <= atol
    @test metrics.rel_fro <= reltol
end

function should_skip_benchmark_transformer_parity(network::FeederFlow.NetworkModel, device::FeederFlow.TransformerDevice)
    # OpenDSS may fold the circuit source Thevenin model into a source-coupled
    # service transformer YPrim, including when source impedance is specified by
    # MVAsc fields rather than explicit r1/x1 values.
    source_bus = network.source.bus
    return any(winding.bus.bus == source_bus for winding in device.windings)
end

function best_fit_residual(reference::AbstractMatrix{<:Complex}, candidate::AbstractMatrix{<:Complex})
    reference_vec = vec(Matrix{ComplexF64}(reference))
    candidate_vec = vec(Matrix{ComplexF64}(candidate))
    alpha = dot(candidate_vec, reference_vec) / dot(candidate_vec, candidate_vec)
    rel_residual = norm(reference_vec - alpha * candidate_vec) / max(norm(reference_vec), eps(Float64))
    return (; alpha, rel_residual)
end

@testset "Line admittance parity - OpenDSSDirect" begin
    network = parse_file(COMPONENT_LINE_DSS)
    line = network.lines["l1"]
    ff = feederflow_line_yprim(line, network.base)

    dss_clear_compile!(COMPONENT_LINE_DSS)
    dss_select_element!("line", "l1")
    dss = dss_active_phase_yprim_pu(network.base.Ybase)
    dss_ordered = reorder_square_matrix(dss.yprim, dss.labels, ff.labels)

    assert_matrix_parity(dss_ordered, ff.yprim; component = "line.l1", atol = 1e-10, reltol = 1e-10)
end

@testset "Transformer/regulator admittance parity - OpenDSSDirect" begin
    network = parse_file(COMPONENT_TRANSFORMER_DSS)

    dss_clear_compile!(COMPONENT_TRANSFORMER_DSS)
    cases = (
        ("transformer", "tx1", network.transformers["tx1"]),
        ("transformer", "reg1", network.regulators["reg1"]),
    )
    for (kind, name, device) in cases
        ff = feederflow_transformer_yprim(device, network.base)
        dss_select_element!(kind, name)
        dss = dss_active_phase_yprim_pu(network.base.Ybase)
        dss_ordered = reorder_square_matrix(dss.yprim, dss.labels, ff.labels)
        @info(
            "OpenDSS transformer parity diagnostics",
            component = "$kind.$name",
            metrics = matrix_error_metrics(dss_ordered, ff.yprim),
        )
        assert_matrix_parity(dss_ordered, ff.yprim; component = "$kind.$name", atol = 5e-7, reltol = 5e-7)
    end
end

@testset "Benchmark transformer/regulator admittance parity - OpenDSSDirect" begin
    cases = (
        ("IEEE13", IEEE13_DSS),
        ("IEEE123", IEEE123_DSS),
    )

    for (network_name, dss_path) in cases
        network = parse_file(dss_path)
        active_network = network

        quoted = replace(normpath(dss_path), "\\" => "/")
        OpenDSSDirect.dss("clear")
        OpenDSSDirect.dss("compile \"$quoted\"")
        OpenDSSDirect.dss("set controlmode=off")
        for regulator in active_network.regulators
            for winding in regulator.windings
                OpenDSSDirect.dss("transformer.$(lowercase(regulator.name)).wdg=$(winding.index) tap=$(winding.tap)")
            end
        end
        OpenDSSDirect.Solution.Solve()

        for (kind, table) in (("transformer", active_network.transformers), ("transformer", active_network.regulators))
            for name in component_names(table)
                device = table[name]
                if kind == "transformer" && should_skip_benchmark_transformer_parity(active_network, device)
                    @info(
                        "Skipping source-coupled transformer YPrim parity",
                        network = network_name,
                        component = "transformer.$name",
                        reason = "OpenDSS element YPrim can include source Thevenin admittance; FeederFlow stamps source coupling separately",
                        source_bus = active_network.source.bus,
                        winding_buses = [winding.bus.bus for winding in device.windings],
                    )
                    continue
                end
                ff = feederflow_transformer_yprim(device, active_network.base)
                dss_select_element!(kind, name)
                dss = dss_active_phase_yprim_pu(active_network.base.Ybase)
                dss_ordered = reorder_square_matrix(dss.yprim, dss.labels, ff.labels)
                @info(
                    "Benchmark transformer parity diagnostics",
                    network = network_name,
                    component = "$kind.$name",
                    metrics = matrix_error_metrics(dss_ordered, ff.yprim),
                )
                assert_matrix_parity(
                    dss_ordered,
                    ff.yprim;
                    component = "$network_name.$kind.$name",
                    atol = 5e-5,
                    reltol = 1e-6,
                )
            end
        end
    end
end

@testset "Capacitor admittance parity - OpenDSSDirect" begin
    network = parse_file(COMPONENT_CAPACITOR_DSS)
    capacitor = network.capacitors["cap1"]
    ff = feederflow_capacitor_yprim(capacitor, network.base)

    dss_clear_compile!(COMPONENT_CAPACITOR_DSS)
    dss_select_element!("capacitor", "cap1")
    dss = dss_active_phase_yprim_pu(network.base.Ybase)
    dss_ordered = reorder_square_matrix(dss.yprim, dss.labels, ff.labels)

    assert_matrix_parity(dss_ordered, ff.yprim; component = "capacitor.cap1", atol = 1e-12, reltol = 1e-12)
end

@testset "Capacitor admittance scales with capacitor kV rating" begin
    system_vbase = 4.16 * 1000 / sqrt(3)
    sbase = 1e6
    base = FeederFlow.BaseQuantities(sbase, system_vbase, system_vbase^2 / sbase, sbase / system_vbase^2)

    capacitor = FeederFlow.CapacitorDevice(
        "cap_scaled",
        FeederFlow.terminal("capbus", [1, 2, 3]),
        [1, 2, 3],
        fill(300.0, 3),
        0.48,
        :wye,
        FeederFlow.Provenance("unit", "capacitor.cap_scaled", Dict{String,Any}(), "unit"),
    )
    indexmap = Dict(BusPhase("capbus", phase) => phase for phase in 1:3)
    rows = Int[]
    cols = Int[]
    vals = ComplexF64[]
    FeederFlow.stamp_capacitor!(rows, cols, vals, indexmap, base, capacitor)

    @test rows == [1, 2, 3]
    @test cols == [1, 2, 3]

    vcap = capacitor.kv * 1000 / sqrt(3)
    expected = im * 300.0 * 1000 / sbase * (system_vbase / vcap)^2
    @test all(isapprox(value, expected; atol = 1e-12, rtol = 1e-12) for value in vals)
end

@testset "Load model=2 admittance parity behavior - OpenDSSDirect" begin
    network = parse_file(COMPONENT_LOAD_MODEL2_DSS)
    ybus = build_y(network)
    noload = compute_no_load(ybus)
    loads = build_load_model(network, ybus, noload)
    labels = ybus_network_labels(ybus)

    @test get(loads.summary, :z, 0) == 3
    @test nnz(loads.YL) > 0

    dss_clear_compile!(COMPONENT_LOAD_MODEL2_DSS)
    for load_name in ("zwye", "zdelta", "zdelta1")
        dss_select_element!("load", load_name)
        dss = dss_active_phase_yprim_pu(network.base.Ybase)
        ff_block = reorder_square_matrix(Matrix(loads.YL), labels, dss.labels)
        assert_matrix_parity(
            ff_block,
            dss.yprim;
            component = "load.$load_name",
            atol = 1e-8,
            reltol = 1e-8,
        )
    end
end
