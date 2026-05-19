# Line-geometry impedance engine (overhead WireData + LineGeometry).
# Formulas follow PowerModelsDistribution / OpenDSS Carson-Deri line constants:
# Kersting, Tleis, Deri earth-return model.

using LinearAlgebra
using SpecialFunctions

const μ₀ = 4π * 1e-7
const ε₀ = 8.8541878176e-12

function _kron_reduce_matrix(Z::Matrix{ComplexF64}, nphases::Int)
    Zout = deepcopy(Z)
    N = size(Zout, 1)
    while N > nphases
        _Z = zeros(ComplexF64, N - 1, N - 1)
        for i in 1:N - 1, j in 1:N - 1
            _Z[i, j] = Zout[i, j] - Zout[i, N] * Zout[j, N] / Zout[N, N]
        end
        Zout = _Z
        N -= 1
    end
    return Zout
end

function _kron_reduce_pair(Z::Matrix{ComplexF64}, Y::Matrix{ComplexF64}, nphases::Int)
    Zout = deepcopy(Z)
    Yout = deepcopy(Y)
    N = size(Zout, 1)
    while N > nphases
        _Z = zeros(ComplexF64, N - 1, N - 1)
        _Y = zeros(ComplexF64, N - 1, N - 1)
        for i in 1:N - 1, j in 1:N - 1
            _Z[i, j] = Zout[i, j] - Zout[i, N] * Zout[j, N] / Zout[N, N]
            _Y[i, j] = Yout[i, j]
        end
        Zout = _Z
        Yout = _Y
        N -= 1
    end
    return Zout, Yout
end

function calc_internal_impedance(R_ac::Real, R_dc::Real, earth_model::String, ω::Real)::ComplexF64
    if occursin("carson", lowercase(earth_model))
        L_i = μ₀ / 8π
        return ComplexF64(R_ac, ω * L_i)
    elseif lowercase(earth_model) == "deri"
        δ = sqrt(R_dc * (ω / 2π) * μ₀)
        m = (1 + im) * sqrt(ω / 2π * μ₀ / R_dc)
        ratio = abs(m) > 35 ? (1 + 0im) : SpecialFunctions.besseli(0, m) / SpecialFunctions.besseli(1, m)
        return (1 + im) * ratio * δ / 2
    else
        error("earth model $(earth_model) not recognized")
    end
end

function calc_earth_return_path_impedance(i::Int, j::Int, x::Vector{<:Real}, y::Vector{<:Real}, ρₑ::Real, earth_model::String, ω::Real, ω₀::Real)::ComplexF64
    δ = 503.292 * sqrt(ρₑ / (ω₀ / 2π))
    D_erc = 1.309125 * δ
    em = lowercase(earth_model)

    if em ∈ ("simplecarson", "carson")
        return ComplexF64(0, (μ₀ * ω / 2π) * (π / 4 + log(D_erc)))
    elseif em == "fullcarson"
        b1 = 1 / (3 * sqrt(2))
        b2 = 1 / 16
        b3 = b1 / (3 * 5)
        b4 = b2 / (4 * 6)
        b5 = -b3 / (5 * 7)
        c2 = 1.3659315
        c4 = c2 + 1 / 4 + 1 / 6
        d2 = π / 4 * b2
        d4 = π / 4 * b4

        if i == j
            D_ij = 2 * y[i]
            θ_ij = 0.0
        else
            D_ij = sqrt((x[i] - x[j])^2 + (y[i] + y[j])^2)
            θ_ij = acos((y[i] + y[j]) / D_ij)
        end
        m_ij = sqrt(2) * D_ij / δ
        R_ije = (π / 8 - b1 * m_ij * cos(θ_ij) + b2 * m_ij^2 * (log(exp(c2) / m_ij) * cos(2 * θ_ij) + θ_ij * sin(2 * θ_ij)) +
                 b3 * m_ij^3 * cos(3 * θ_ij) - d4 * m_ij^4 * cos(4 * θ_ij) - b5 * m_ij^5 * cos(5 * θ_ij))
        X_ije = (1 / 2 * log(1.85138 / m_ij) + b1 * m_ij * cos(θ_ij) - d2 * m_ij^2 * cos(2 * θ_ij) + b3 * m_ij^3 * cos(3 * θ_ij) -
                 b4 * m_ij^4 * (log(exp(c4) / m_ij) * cos(4 * θ_ij) + θ_ij * sin(4 * θ_ij)) + b5 * m_ij^5 * cos(5 * θ_ij))
        X_ije += 1 / 2 * log(D_ij)
        return ComplexF64(ω / 2π * μ₀ * 2 * R_ije, ω / 2π * μ₀ * 2 * X_ije)
    elseif em == "deri"
        p = 1 / sqrt(im * ω * μ₀ / ρₑ)
        if i == j
            return im * ω * μ₀ / 2π * log(2 * (y[i] + p))
        else
            return im * ω * μ₀ / 2π * log(sqrt((y[i] + y[j] + 2 * p)^2 + (x[i] - x[j])^2))
        end
    else
        error("earth model $(earth_model) not recognized")
    end
end

function overhead_line_constants(
    x::Vector{Float64},
    y::Vector{Float64},
    gmr::Vector{Float64},
    capradius::Vector{Float64},
    rac::Vector{Float64},
    rdc::Vector{Float64},
    nconds::Int,
    earth_model::String,
    ω::Real,
    ω₀::Real,
    ρₑ::Real,
)
    Z = zeros(ComplexF64, nconds, nconds)
    P = zeros(ComplexF64, nconds, nconds)

    for i in 1:nconds
        for j in 1:i
            if i == j
                Z_ic = real(calc_internal_impedance(rac[i], rdc[i], earth_model, ω))
                Z_ig = im * ω * μ₀ / 2π * log(1 / gmr[i])
                Z_ie = calc_earth_return_path_impedance(i, j, x, y, ρₑ, earth_model, ω, ω₀)
                Z[i, i] = Z_ic + Z_ig + Z_ie
                P[i, i] = im * -1 / (2π * ε₀ * ω) * log(2 * y[i] / capradius[i])
            else
                d_ij = sqrt((x[i] - x[j])^2 + (y[i] - y[j])^2)
                X_ijg = (μ₀ * ω / 2π) * log(1 / d_ij)
                Z[i, j] = Z[j, i] = im * X_ijg + calc_earth_return_path_impedance(i, j, x, y, ρₑ, earth_model, ω, ω₀)
                S_ij = sqrt((x[i] - x[j])^2 + (y[i] + y[j])^2)
                P[i, j] = P[j, i] = im * -1 / (2π * ε₀ * ω) * log(S_ij / d_ij)
            end
        end
    end

    C = pinv(P) .* 1e9 ./ ω
    return Z, C
end

"""
    geometry_line_matrices(geometry, wiredata, line_props; basefreq, earthmodel, rho) -> (rmatrix, xmatrix, cmatrix, normamps, emergamps)

Compute phase-domain R/X/C matrices for a line referencing `geometry` and `WireData` catalog entries.
Matrices are returned in the requested `length_units` (default km for EPRI feeders).
"""
function geometry_line_matrices(
    geometry::LineGeometry,
    wiredata::Dict{String,WireData};
    basefreq::Float64 = 60.0,
    earthmodel::String = "deri",
    rho::Float64 = 100.0,
    length_units::String = "km",
)
    nconds = geometry.nconds
    nphases = geometry.nphases

    gmr = Float64[]
    capradius = Float64[]
    rac = Float64[]
    rdc = Float64[]
    normamps = Float64[]
    emergamps = Float64[]

    for i in 1:nconds
        wire_name = geometry.wires[i]
        isempty(wire_name) && error("LineGeometry.$(geometry.name) conductor $i is missing wire data")
        key = normalize_name(wire_name)
        haskey(wiredata, key) || error("WireData '$wire_name' referenced by LineGeometry.$(geometry.name) is not defined")
        wd = wiredata[key]
        push!(gmr, wd.gmrac)
        push!(capradius, wd.capradius)
        push!(rac, wd.rac)
        push!(rdc, wd.rdc)
        push!(normamps, wd.normamps)
        push!(emergamps, wd.emergamps)
    end

    length(gmr) == nconds || error("LineGeometry.$(geometry.name) has $(nconds) conductors but only $(length(gmr)) wire entries")

    ω = 2π * basefreq
    ω₀ = 2π * basefreq

    Z, C = overhead_line_constants(geometry.xs, geometry.hs, gmr, capradius, rac, rdc, nconds, earthmodel, ω, ω₀, rho)

    if geometry.reduce
        Z, C = _kron_reduce_pair(Z, ComplexF64.(C), nphases)
    end

    scale = convert_to_meters(length_units)
    rmatrix = real(Z) .* scale
    xmatrix = imag(Z) .* scale
    # Imag(C) from `overhead_line_constants` is nF/m; scale to requested length units (e.g. km).
    cmatrix = imag.(C) .* scale

    line_normamps = minimum(normamps)
    line_emergamps = minimum(emergamps)

    return rmatrix, xmatrix, cmatrix, line_normamps, line_emergamps
end
