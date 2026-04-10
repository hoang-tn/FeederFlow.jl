using OpenDSSDirect
using LinearAlgebra

const OPENDSS_FIXTURE_ROOT = joinpath(@__DIR__, "fixtures", "opendss")

opendss_fixture_path(name::AbstractString) = joinpath(OPENDSS_FIXTURE_ROOT, name)

function dss_clear_compile!(dss_path::AbstractString)
    quoted = replace(normpath(dss_path), "\\" => "/")
    OpenDSSDirect.dss("clear")
    OpenDSSDirect.dss("compile \"$quoted\"")
    OpenDSSDirect.Solution.Solve()
    return nothing
end

function dss_select_element!(kind::AbstractString, name::AbstractString)
    OpenDSSDirect.dss("select $(lowercase(kind)).$(lowercase(name))")
    return nothing
end

function stable_yprim_matrix(raw)
    if raw isa AbstractMatrix
        return Matrix{ComplexF64}(raw)
    elseif raw isa AbstractVector
        values = collect(raw)
        isempty(values) && return zeros(ComplexF64, 0, 0)
        if eltype(values) <: Complex
            n = isqrt(length(values))
            n * n == length(values) || error("Cannot reshape complex YPrim vector of length $(length(values)) into square matrix")
            return reshape(ComplexF64.(values), n, n)
        end
        length(values) % 2 == 0 || error("Expected real/imag interleaved YPrim vector, got odd length $(length(values))")
        complex_values = ComplexF64.(values[1:2:end], values[2:2:end])
        n = isqrt(length(complex_values))
        n * n == length(complex_values) || error("Cannot reshape interleaved YPrim vector of length $(length(values)) into square matrix")
        return reshape(complex_values, n, n)
    end
    error("Unsupported YPrim payload type $(typeof(raw))")
end

canonical_bus_name(bus_name::AbstractString) = lowercase(strip(first(split(bus_name, "."))))

function active_element_node_labels(bus_names::Vector{String}, node_order::Vector{Int})
    nterm = length(bus_names)
    nterm == 0 && return String[]
    length(node_order) % nterm == 0 || error("NodeOrder length $(length(node_order)) not divisible by terminal count $nterm")
    ncond = div(length(node_order), nterm)
    labels = String[]
    for (terminal_idx, bus_name) in enumerate(bus_names)
        base_bus = canonical_bus_name(bus_name)
        offset = (terminal_idx - 1) * ncond
        for cond_idx in 1:ncond
            push!(labels, string(base_bus, ".", node_order[offset + cond_idx]))
        end
    end
    return labels
end

function dss_active_element()
    yprim = stable_yprim_matrix(OpenDSSDirect.CktElement.YPrim())
    bus_names = String.(OpenDSSDirect.CktElement.BusNames())
    node_order = Int.(OpenDSSDirect.CktElement.NodeOrder())
    labels = active_element_node_labels(bus_names, node_order)
    size(yprim, 1) == length(labels) || error("YPrim dimension $(size(yprim)) inconsistent with labels $(length(labels))")
    size(yprim, 2) == length(labels) || error("YPrim dimension $(size(yprim)) inconsistent with labels $(length(labels))")
    return (; yprim, bus_names, node_order, labels)
end

function nth_label_index(labels::Vector{String}, target::String, occurrence::Int)
    seen = 0
    for (idx, label) in enumerate(labels)
        if label == target
            seen += 1
            seen == occurrence && return idx
        end
    end
    error("Missing label '$target' occurrence $occurrence in $(labels)")
end

function label_permutation(labels::Vector{String}, target_labels::Vector{String})
    seen = Dict{String,Int}()
    perm = Int[]
    for target in target_labels
        occurrence = get(seen, target, 0) + 1
        seen[target] = occurrence
        push!(perm, nth_label_index(labels, target, occurrence))
    end
    return perm
end

function reorder_square_matrix(matrix::AbstractMatrix{<:Complex}, labels::Vector{String}, target_labels::Vector{String})
    perm = label_permutation(labels, target_labels)
    return Matrix{ComplexF64}(matrix[perm, perm])
end

function project_phase_matrix(matrix::AbstractMatrix{<:Complex}, labels::Vector{String})
    keep_labels = [label for label in labels if !endswith(label, ".0")]
    projected = reorder_square_matrix(matrix, labels, keep_labels)
    return (; matrix = projected, labels = keep_labels)
end

function dss_active_phase_yprim_pu(ybase::Float64)
    data = dss_active_element()
    phase = project_phase_matrix(data.yprim ./ ybase, data.labels)
    return (; yprim = phase.matrix, labels = phase.labels, bus_names = data.bus_names, node_order = data.node_order)
end

function matrix_error_metrics(observed::AbstractMatrix{<:Complex}, expected::AbstractMatrix{<:Complex})
    size(observed) == size(expected) || error("Matrix size mismatch: observed $(size(observed)) vs expected $(size(expected))")
    obs = Matrix{ComplexF64}(observed)
    ref = Matrix{ComplexF64}(expected)
    diff = obs - ref
    isempty(diff) && return (; max_abs = 0.0, rel_fro = 0.0, worst = (1, 1), observed = 0.0 + 0im, expected = 0.0 + 0im, delta = 0.0 + 0im)
    absdiff = abs.(diff)
    worst = argmax(absdiff)
    denom = max(norm(ref), eps(Float64))
    return (
        max_abs = maximum(absdiff),
        rel_fro = norm(diff) / denom,
        worst = Tuple(worst),
        observed = obs[worst],
        expected = ref[worst],
        delta = diff[worst],
    )
end

function assemble_square_matrix(elements, global_labels::Vector{String})
    lookup = Dict(label => idx for (idx, label) in enumerate(global_labels))
    Y = zeros(ComplexF64, length(global_labels), length(global_labels))
    for element in elements
        local_y = Matrix{ComplexF64}(element.yprim)
        local_labels = Vector{String}(element.labels)
        size(local_y, 1) == size(local_y, 2) || error("Element YPrim must be square, got $(size(local_y))")
        size(local_y, 1) == length(local_labels) || error("Element labels do not match YPrim size")
        for i in eachindex(local_labels), j in eachindex(local_labels)
            global_i = get(lookup, local_labels[i], nothing)
            global_j = get(lookup, local_labels[j], nothing)
            global_i === nothing && error("Label $(local_labels[i]) missing from global label set")
            global_j === nothing && error("Label $(local_labels[j]) missing from global label set")
            Y[global_i, global_j] += local_y[i, j]
        end
    end
    return Y
end

function kron_reduce_by_labels(matrix::AbstractMatrix{<:Complex}, labels::Vector{String}, keep_labels::Vector{String}; singular_tol::Float64 = 1e-11)
    keep_perm = label_permutation(labels, keep_labels)
    keep_set = Set(keep_perm)
    eliminate = [idx for idx in eachindex(labels) if !(idx in keep_set)]
    Y = Matrix{ComplexF64}(matrix)
    isempty(eliminate) && return Matrix{ComplexF64}(Y[keep_perm, keep_perm])
    Ykk = Y[keep_perm, keep_perm]
    Yke = Y[keep_perm, eliminate]
    Yek = Y[eliminate, keep_perm]
    Yee = Y[eliminate, eliminate]
    projector = try
        rcond(Yee) < singular_tol ? pinv(Yee) * Yek : Yee \ Yek
    catch
        pinv(Yee) * Yek
    end
    return Matrix{ComplexF64}(Ykk - Yke * projector)
end
