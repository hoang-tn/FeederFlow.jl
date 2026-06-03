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
        ("IEEE37", IEEE37_DSS),
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

@testset "Open-delta grouped-equivalent parity - OpenDSSDirect" begin
    network = parse_file(IEEE37_DSS)
    groups = FeederFlow.open_delta_regulator_groups(network)
    @test length(groups) == 1
    group = only(groups)
    ff_group = feederflow_open_delta_group_yprim(group, network.base)

    dss_clear_compile!(IEEE37_DSS)
    elements = NamedTuple[]
    for transformer in group.transformers
        dss_select_element!("transformer", transformer.name)
        dss_data = dss_active_phase_yprim_pu(network.base.Ybase)
        push!(elements, (yprim = dss_data.yprim, labels = dss_data.labels))
    end
    dss_select_element!("line", group.line.name)
    dss_line = dss_active_phase_yprim_pu(network.base.Ybase)
    push!(elements, (yprim = dss_line.yprim, labels = dss_line.labels))

    global_labels = vcat(
        [busphase_key(group.primary, phase) for phase in 1:3],
        [busphase_key(group.secondary, phase) for phase in 1:3],
        [busphase_key(group.remote, phase) for phase in 1:3],
    )
    dss_full = assemble_square_matrix(elements, global_labels)
    dss_equivalent = kron_reduce_by_labels(dss_full, global_labels, ff_group.labels)
    direct = matrix_error_metrics(ff_group.yprim, dss_equivalent)
    fit = best_fit_residual(ff_group.yprim, dss_equivalent)
    @info(
        "Open-delta grouped-equivalent diagnostics",
        direct_rel_fro = direct.rel_fro,
        fit_rel_residual = fit.rel_residual,
        fit_alpha = fit.alpha,
    )
    @test size(ff_group.yprim) == (6, 6)
    @test all(isfinite, real.(ff_group.yprim))
    @test all(isfinite, imag.(ff_group.yprim))
    # Grouped open-delta is a reduced equivalent, not an exact composition match.
    # Keep this strict enough to detect regressions while allowing model-form error.
    @test fit.rel_residual < 1e-4
    @test fit.rel_residual <= direct.rel_fro
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
