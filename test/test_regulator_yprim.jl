using Test
using FeederFlow
using OpenDSSDirect
using LinearAlgebra

const TEST_REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const TEST_IEEE37_DSS = joinpath(TEST_REPO_ROOT, "three-phase-modeling", "IEEE 37-bus feeder", "IEEE37openDSSdata", "ieee37opendss.dss")

function open_dss_transformer_yprim(dss_path::AbstractString, element::AbstractString)
    quoted = replace(normpath(dss_path), "\\" => "/")
    dss("clear")
    dss("compile \"$quoted\"")
    Solution.Solve()
    dss("select transformer.$element")
    return OpenDSSDirect.CktElement.YPrim()
end

function regulator_phase_space_yprim(reg::FeederFlow.TransformerDevice, base::FeederFlow.BaseQuantities; inverse_tap::Bool = true)
    length(reg.windings) >= 2 || error("regulator requires two windings")
    w1 = reg.windings[1]
    w2 = reg.windings[2]

    c1 = FeederFlow.connection_matrix(w1.conn, w1.bus.phases)
    c2 = FeederFlow.connection_matrix(w2.conn, w2.bus.phases)
    a = inverse_tap ? 1 / max(w2.tap, 1e-6) : max(w2.tap, 1e-6)
    z = FeederFlow.regulator_series_impedance(reg, base)
    y = 1 / z
    scale = FeederFlow.transformer_scale(w1.conn, w2.conn, size(c1, 1), size(c2, 1))

    self_1 = scale * (y / (a * conj(a))) .* (c1' * c1) + FeederFlow.transformer_regularization(c1, w1.conn, y, 1e-6)
    self_2 = scale * y .* (c2' * c2) + FeederFlow.transformer_regularization(c2, w2.conn, y, 1e-6)
    cross_12 = scale * (-y / conj(a)) .* (c1' * c2)
    cross_21 = scale * (-y / a) .* (c2' * c1)

    top = [c1 * self_1 * c1'  c1 * cross_12 * c2']
    bottom = [c2 * cross_21 * c1'  c2 * self_2 * c2']
    return [top; bottom]
end

function differential_terminal_matrix(yprim::AbstractMatrix{<:Complex})
    # The reg1a primitive is a 2-terminal delta device; compare it in the
    # phase-difference basis [Va - Vb] at each terminal rather than in the raw
    # conductor basis, which is a more stable regression target.
    t = ComplexF64[
        1 -1 0 0
        0 0 1 -1
    ]
    return t * Matrix{ComplexF64}(yprim) * t'
end

function best_fit_residual(reference::AbstractMatrix{<:Complex}, candidate::AbstractMatrix{<:Complex})
    reference_vec = vec(Matrix{ComplexF64}(reference))
    candidate_vec = vec(Matrix{ComplexF64}(candidate))
    alpha = dot(reference_vec, candidate_vec) / dot(candidate_vec, candidate_vec)
    rel_residual = norm(reference_vec - alpha * candidate_vec) / norm(reference_vec)
    return (; alpha, rel_residual)
end

function expected_bus_names(regname::AbstractString)
    regname == "reg1a" && return ["799.1.2", "799r.1.2"]
    regname == "reg1c" && return ["799.3.2", "799r.3.2"]
    error("unsupported regulator $regname")
end

function expected_node_order(regname::AbstractString)
    busnames = expected_bus_names(regname)
    parse_bus_phases(busname::AbstractString) = begin
        parts = split(busname, ".")
        length(parts) == 3 || error("unexpected bus format: $busname")
        (parse(Int, parts[2]), parse(Int, parts[3]))
    end
    primary_phase, secondary_phase = parse_bus_phases(first(busnames))
    remote_phase = last(parse_bus_phases(last(busnames)))
    return [primary_phase, secondary_phase, primary_phase, remote_phase]
end

function regulator_yprim_diagnostics(network::FeederFlow.NetworkModel, regname::AbstractString)
    reg = network.regulators[regname]
    dss_y = open_dss_transformer_yprim(TEST_IEEE37_DSS, regname)
    dss_diff = differential_terminal_matrix(dss_y)
    swapped_perm = [3, 4, 1, 2]
    dss_diff_swapped = differential_terminal_matrix(dss_y[swapped_perm, swapped_perm])

    local_inverse = regulator_phase_space_yprim(reg, network.base; inverse_tap = true)
    local_direct = regulator_phase_space_yprim(reg, network.base; inverse_tap = false)

    inverse_fit = best_fit_residual(dss_diff, local_inverse)
    direct_fit = best_fit_residual(dss_diff, local_direct)
    swapped_fit = best_fit_residual(dss_diff_swapped, local_inverse)

    return (; regname, dss_y, dss_diff, inverse_fit, direct_fit, swapped_fit)
end

@testset "Regulator YPrim parity - IEEE37" begin
    network = parse_file(TEST_IEEE37_DSS)
    for regname in ("reg1a", "reg1c")
        diag = regulator_yprim_diagnostics(network, regname)

        @test size(diag.dss_y) == (4, 4)
        @test OpenDSSDirect.CktElement.NodeOrder() == expected_node_order(regname)
        @test OpenDSSDirect.CktElement.BusNames() == expected_bus_names(regname)
        @test all(isfinite, real.(diag.dss_diff))
        @test all(isfinite, imag.(diag.dss_diff))

        @info(
            "IEEE37 regulator YPrim diagnostics",
            regulator = diag.regname,
            inverse_tap_rel_residual = diag.inverse_fit.rel_residual,
            direct_tap_rel_residual = diag.direct_fit.rel_residual,
            swapped_terminal_rel_residual = diag.swapped_fit.rel_residual,
            inverse_tap_alpha = diag.inverse_fit.alpha,
            direct_tap_alpha = diag.direct_fit.alpha,
        )

        @test isfinite(diag.inverse_fit.rel_residual)
        @test isfinite(diag.direct_fit.rel_residual)
        @test isfinite(diag.swapped_fit.rel_residual)
        @test diag.inverse_fit.rel_residual < 1e-6
        @test diag.inverse_fit.rel_residual <= diag.direct_fit.rel_residual + 1e-6
        @test diag.inverse_fit.rel_residual <= diag.swapped_fit.rel_residual + 1e-6
    end
end
