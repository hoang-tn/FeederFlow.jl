using Test
using FeederFlow
using SparseArrays

isdefined(@__MODULE__, :IEEE13_DSS) || include("test_support.jl")
include("test_opendss_helpers.jl")

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

function transformer_with_winding_tap(transformer::FeederFlow.TransformerDevice, winding_idx::Int, tap::Float64)
    windings = FeederFlow.TransformerWinding[
        FeederFlow.TransformerWinding(
            winding.index,
            winding.bus,
            winding.conn,
            winding.kv,
            winding.kva,
            winding.resistance,
            winding.index == winding_idx ? tap : winding.tap,
        ) for winding in transformer.windings
    ]
    return FeederFlow.TransformerDevice(
        transformer.name,
        transformer.phases,
        windings,
        transformer.xhl_percent,
        transformer.xht_percent,
        transformer.xlt_percent,
        transformer.percent_loadloss,
        transformer.percent_noloadloss,
        transformer.percent_imag,
        transformer.is_regulator,
        transformer.regcontrol,
        transformer.provenance,
    )
end

function dss_transformer_winding_taps(name::AbstractString)
    OpenDSSDirect.Transformers.Transformers.Name(lowercase(String(name)))
    nwindings = Int(OpenDSSDirect.Transformers.Transformers.NumWindings())
    taps = Float64[]
    for winding in 1:nwindings
        OpenDSSDirect.Transformers.Transformers.Wdg(Float64(winding))
        push!(taps, OpenDSSDirect.Transformers.Transformers.Tap())
    end
    return taps
end

@testset "IEEE13 reg3 tap-step diagnostics - OpenDSSDirect" begin
    network = parse_file(IEEE13_DSS)
    active_network = FeederFlow.solve_power_flow(network; max_iter = 50, tol = 1e-5).network
    reg3 = active_network.regulators["reg3"]

    dss_clear_compile!(IEEE13_DSS)
    dss_reg3_taps = dss_transformer_winding_taps("reg3")
    ff_reg3_taps = [winding.tap for winding in reg3.windings]

    dss_select_element!("transformer", "reg3")
    dss_reg3 = dss_active_phase_yprim_pu(active_network.base.Ybase)

    ff_current = feederflow_transformer_yprim(reg3, active_network.base)
    current_metrics = matrix_error_metrics(
        reorder_square_matrix(dss_reg3.yprim, dss_reg3.labels, ff_current.labels),
        ff_current.yprim,
    )

    reg3_aligned = transformer_with_winding_tap(reg3, 2, dss_reg3_taps[2])
    ff_aligned = feederflow_transformer_yprim(reg3_aligned, active_network.base)
    aligned_metrics = matrix_error_metrics(
        reorder_square_matrix(dss_reg3.yprim, dss_reg3.labels, ff_aligned.labels),
        ff_aligned.yprim,
    )

    @info(
        "IEEE13 reg3 tap-step diagnostics",
        dss_taps = dss_reg3_taps,
        feederflow_taps = ff_reg3_taps,
        tap_delta = ff_reg3_taps[2] - dss_reg3_taps[2],
        current_metrics = current_metrics,
        aligned_metrics = aligned_metrics,
    )

    @test length(dss_reg3_taps) == length(ff_reg3_taps)
    @test isapprox(ff_reg3_taps[1], dss_reg3_taps[1]; atol = 1e-12)
    @test isapprox(ff_reg3_taps[2] - dss_reg3_taps[2], 0.00625; atol = 1e-12)
    @test current_metrics.rel_fro > 1e-3
    @test aligned_metrics.rel_fro < 1e-8
    @test aligned_metrics.rel_fro < current_metrics.rel_fro * 1e-4
end

@testset "IEEE13 sub transformer diagnostics - OpenDSSDirect" begin
    network = parse_file(IEEE13_DSS)
    active_network = FeederFlow.solve_power_flow(network; max_iter = 50, tol = 1e-5).network
    sub_parsed = network.transformers["sub"]
    sub_solved = active_network.transformers["sub"]

    dss_clear_compile!(IEEE13_DSS)
    dss_sub_taps = dss_transformer_winding_taps("sub")
    ff_sub_parsed_taps = [winding.tap for winding in sub_parsed.windings]
    ff_sub_solved_taps = [winding.tap for winding in sub_solved.windings]

    dss_select_element!("transformer", "sub")
    dss_sub_phase = dss_active_phase_yprim_pu(active_network.base.Ybase)
    ff_parsed = feederflow_transformer_yprim(sub_parsed, network.base)
    ff_solved = feederflow_transformer_yprim(sub_solved, active_network.base)

    parsed_metrics = matrix_error_metrics(
        reorder_square_matrix(dss_sub_phase.yprim, dss_sub_phase.labels, ff_parsed.labels),
        ff_parsed.yprim,
    )
    solved_metrics = matrix_error_metrics(
        reorder_square_matrix(dss_sub_phase.yprim, dss_sub_phase.labels, ff_solved.labels),
        ff_solved.yprim,
    )

    dss_sub_full = dss_active_element()
    dss_sub_kron = kron_reduce_by_labels(dss_sub_full.yprim ./ active_network.base.Ybase, dss_sub_full.labels, ff_solved.labels)
    kron_metrics = matrix_error_metrics(dss_sub_kron, ff_solved.yprim)

    @info(
        "IEEE13 sub diagnostics",
        dss_taps = dss_sub_taps,
        feederflow_parsed_taps = ff_sub_parsed_taps,
        feederflow_solved_taps = ff_sub_solved_taps,
        parsed_metrics = parsed_metrics,
        solved_metrics = solved_metrics,
        kron_metrics = kron_metrics,
    )

    @test length(dss_sub_taps) == length(ff_sub_solved_taps)
    @test all(isapprox.(ff_sub_solved_taps, dss_sub_taps; atol = 1e-12))
    @test all(isapprox.(ff_sub_parsed_taps, ff_sub_solved_taps; atol = 1e-12))
    @test solved_metrics.rel_fro > 1e-2
    @test isapprox(parsed_metrics.rel_fro, solved_metrics.rel_fro; atol = 1e-14)
    @test kron_metrics.rel_fro > solved_metrics.rel_fro
end

@testset "IEEE13 reg1/reg2 tap-step diagnostics - OpenDSSDirect" begin
    network = parse_file(IEEE13_DSS)
    active_network = FeederFlow.solve_power_flow(network; max_iter = 50, tol = 1e-5).network

    dss_clear_compile!(IEEE13_DSS)

    for regname in ("reg1", "reg2")
        reg = active_network.regulators[regname]

        dss_reg_taps = dss_transformer_winding_taps(regname)
        ff_reg_taps = [winding.tap for winding in reg.windings]

        dss_select_element!("transformer", regname)
        dss_reg = dss_active_phase_yprim_pu(active_network.base.Ybase)

        ff_current = feederflow_transformer_yprim(reg, active_network.base)
        current_metrics = matrix_error_metrics(
            reorder_square_matrix(dss_reg.yprim, dss_reg.labels, ff_current.labels),
            ff_current.yprim,
        )

        reg_aligned = transformer_with_winding_tap(reg, 2, dss_reg_taps[2])
        ff_aligned = feederflow_transformer_yprim(reg_aligned, active_network.base)
        aligned_metrics = matrix_error_metrics(
            reorder_square_matrix(dss_reg.yprim, dss_reg.labels, ff_aligned.labels),
            ff_aligned.yprim,
        )

        @info(
            "IEEE13 $regname tap-step diagnostics",
            dss_taps = dss_reg_taps,
            feederflow_taps = ff_reg_taps,
            tap_delta = ff_reg_taps[2] - dss_reg_taps[2],
            current_metrics = current_metrics,
            aligned_metrics = aligned_metrics,
        )

        @test length(dss_reg_taps) == length(ff_reg_taps)
        @test isapprox(ff_reg_taps[1], dss_reg_taps[1]; atol = 1e-12)
        @test aligned_metrics.rel_fro < 1e-8
        if abs(ff_reg_taps[2] - dss_reg_taps[2]) > 1e-10
            @test aligned_metrics.rel_fro < current_metrics.rel_fro * 1e-4
        else
            @test current_metrics.rel_fro < 1e-8
        end
    end
end

@testset "IEEE13 XFM1 transformer diagnostics - OpenDSSDirect" begin
    network = parse_file(IEEE13_DSS)
    active_network = FeederFlow.solve_power_flow(network; max_iter = 50, tol = 1e-5).network

    dss_clear_compile!(IEEE13_DSS)

    xfm1 = active_network.transformers["xfm1"]

    dss_xfm_taps = dss_transformer_winding_taps("xfm1")
    ff_xfm_taps = [winding.tap for winding in xfm1.windings]

    dss_select_element!("transformer", "xfm1")
    dss_xfm = dss_active_phase_yprim_pu(active_network.base.Ybase)

    ff_xfm = feederflow_transformer_yprim(xfm1, active_network.base)
    xfm_metrics = matrix_error_metrics(
        reorder_square_matrix(dss_xfm.yprim, dss_xfm.labels, ff_xfm.labels),
        ff_xfm.yprim,
    )

    @info(
        "IEEE13 XFM1 diagnostics",
        dss_taps = dss_xfm_taps,
        feederflow_taps = ff_xfm_taps,
        metrics = xfm_metrics,
    )

    @test length(dss_xfm_taps) == length(ff_xfm_taps)
    @test all(isapprox.(ff_xfm_taps, dss_xfm_taps; atol = 1e-12))
    @test xfm_metrics.rel_fro < 1e-6
end

@testset "IEEE13 line Y-bus element diagnostics - OpenDSSDirect" begin
    network = parse_file(IEEE13_DSS)
    active_network = FeederFlow.solve_power_flow(network; max_iter = 50, tol = 1e-5).network

    dss_clear_compile!(IEEE13_DSS)

    for linename in ("632633", "671680", "671692")
        line = active_network.lines[linename]

        labels = vcat(
            [busphase_key(line.from.bus, phase) for phase in sort(line.from.phases)],
            [busphase_key(line.to.bus, phase) for phase in sort(line.to.phases)],
        )
        imap = indexmap_from_labels(labels)
        rows = Int[]
        cols = Int[]
        vals = ComplexF64[]

        FeederFlow.stamp_line_admittance!(rows, cols, vals, imap, line)
        ff_yprim = dense_stamp_matrix(rows, cols, vals, length(labels))

        dss_select_element!("line", linename)
        dss_line = dss_active_element()
        dss_yprim_pu = dss_line.yprim ./ active_network.base.Ybase
        dss_labels = active_element_node_labels(
            String.(OpenDSSDirect.CktElement.BusNames()),
            Int.(OpenDSSDirect.CktElement.NodeOrder()),
        )

        line_metrics = matrix_error_metrics(
            reorder_square_matrix(dss_yprim_pu, dss_labels, labels),
            ff_yprim,
        )

        @info(
            "IEEE13 line $linename diagnostics",
            metrics = line_metrics,
            ff_size = size(ff_yprim),
            dss_size = size(dss_yprim_pu),
        )

        @test isapprox(norm(ff_yprim), norm(dss_yprim_pu); rtol = 1e-6)
    end
end

@testset "IEEE13 voltage magnitude comparison - OpenDSSDirect" begin
    network = parse_file(IEEE13_DSS)
    result = FeederFlow.solve_power_flow(network; max_iter = 50, tol = 1e-5)
    active_network = result.network

    dss_clear_compile!(IEEE13_DSS)

    dss_voltages = Dict{String,ComplexF64}()
    for busphase in OpenDSSDirect.CktElement.AllBusVolts()
        parts = split(busphase, '.')
        length(parts) == 3 || continue
        bus = lowercase(parts[1])
        node = tryparse(Int, parts[2])
        node === nothing && continue
        node == 0 && continue
        mag = tryparse(Float64, parts[3])
        mag === nothing && continue
        key = busphase_key(bus, node)
        haskey(dss_voltages, key) || (dss_voltages[key] = mag)
    end

    ff_voltages = Dict{String,Float64}()
    for (bp, v) in result.voltage_magnitude
        ff_voltages[bp] = abs(v)
    end

    shared_keys = intersect(keys(dss_voltages), keys(ff_voltages))
    @assert !isempty(shared_keys) "No shared voltage keys"

    max_mag_error = maximum(abs(ff_voltages[k] - dss_voltages[k]) for k in shared_keys)
    max_rel_error = maximum(
        abs(ff_voltages[k] - dss_voltages[k]) / max(dss_voltages[k], eps(Float64)) for k in shared_keys
    )

    @info(
        "IEEE13 voltage comparison",
        dss_count = length(dss_voltages),
        ff_count = length(ff_voltages),
        shared_count = length(shared_keys),
        max_mag_error = max_mag_error,
        max_rel_error = max_rel_error,
    )

    @test max_mag_error < 5.0
    @test max_rel_error < 0.05
end
