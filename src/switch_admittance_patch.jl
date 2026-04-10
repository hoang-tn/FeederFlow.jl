using LinearAlgebra

"""
    scaled_ybus_matrix(ybus, v_scale_full)

Return the dense local-coordinate admittance matrix `D * Y * D`, where
`D = Diagonal(v_scale_full)`.
"""
function scaled_ybus_matrix(ybus::FeederFlow.YBusModel, v_scale_full::AbstractVector{<:Real})
    return Diagonal(v_scale_full) * Matrix(ybus.Ynet) * Diagonal(v_scale_full)
end

function switch_line_admittance(network::FeederFlow.NetworkModel, line::FeederFlow.LineDevice)
    z_series = complex.(line.rmatrix, line.xmatrix) * line.length
    yseries = try
        inv(z_series) / network.base.Ybase
    catch err
        err isa SingularException || rethrow(err)
        return nothing
    end
    yshunt = im * 2pi * line.basefreq * (line.cmatrix * 1e-9) * line.length / network.base.Ybase
    return yseries, yshunt
end

function apply_switch_admittance_stamp!(
    Y_scaled::AbstractMatrix{ComplexF64},
    network::FeederFlow.NetworkModel,
    ybus::FeederFlow.YBusModel,
    line::FeederFlow.LineDevice,
    stamp_sign::Integer,
    v_scale_full::AbstractVector{<:Real},
)
    admittance = switch_line_admittance(network, line)
    admittance === nothing && throw(ArgumentError("Cannot patch switch admittance for $(line.name): series admittance is singular"))
    yseries, yshunt = admittance

    from_indices = Vector{Int}(undef, length(line.phases))
    to_indices = Vector{Int}(undef, length(line.phases))
    for (k, phase) in enumerate(line.phases)
        from_indices[k] = get(ybus.all_index, FeederFlow.BusPhase(line.from.bus, phase), 0)
        to_indices[k] = get(ybus.all_index, FeederFlow.BusPhase(line.to.bus, phase), 0)
    end

    @inbounds for r in eachindex(line.phases)
        i_from = from_indices[r]
        i_to = to_indices[r]
        (i_from == 0 || i_to == 0) && continue

        for c in eachindex(line.phases)
            j_from = from_indices[c]
            j_to = to_indices[c]
            (j_from == 0 || j_to == 0) && continue

            self_val = yseries[r, c] + 0.5 * yshunt[r, c]
            mutual_val = -yseries[r, c]

            scale_ff = v_scale_full[i_from] * v_scale_full[j_from]
            scale_tt = v_scale_full[i_to] * v_scale_full[j_to]
            scale_ft = v_scale_full[i_from] * v_scale_full[j_to]
            scale_tf = v_scale_full[i_to] * v_scale_full[j_from]

            Y_scaled[i_from, j_from] += stamp_sign * self_val * scale_ff
            Y_scaled[i_to, j_to] += stamp_sign * self_val * scale_tt
            Y_scaled[i_from, j_to] += stamp_sign * mutual_val * scale_ft
            Y_scaled[i_to, j_from] += stamp_sign * mutual_val * scale_tf
        end
    end

    return Y_scaled
end

"""
    patch_switch_admittance!(Y_scaled_base, network, ybus, v_scale_full)

Return a fresh scaled Y-matrix seeded from `Y_scaled_base` and patch every
switch whose mutable state differs from its parsed base state.

The input base matrix is left unchanged, so this helper can be called after
multiple switch updates at once.
"""
function patch_switch_admittance!(
    Y_scaled_base::AbstractMatrix{ComplexF64},
    network::FeederFlow.NetworkModel,
    ybus::FeederFlow.YBusModel,
    v_scale_full::AbstractVector{<:Real},
)
    Y_scaled = copy(Y_scaled_base)

    for line in network.lines
        line.is_switch || continue
        line.is_closed == line.is_closed_base && continue
        apply_switch_admittance_stamp!(Y_scaled, network, ybus, line, line.is_closed ? 1 : -1, v_scale_full)
    end

    return Y_scaled
end

function patch_switch_admittance!(
    Y_scaled::AbstractMatrix{ComplexF64},
    network::FeederFlow.NetworkModel,
    ybus::FeederFlow.YBusModel,
    line::FeederFlow.LineDevice,
    new_closed::Bool,
    v_scale_full::AbstractVector{<:Real},
)
    line.is_switch || throw(ArgumentError("patch_switch_admittance! only applies to switch lines"))

    old_closed = line.is_closed
    old_closed == new_closed && return Y_scaled

    apply_switch_admittance_stamp!(Y_scaled, network, ybus, line, new_closed ? 1 : -1, v_scale_full)

    line.is_closed = new_closed
    return Y_scaled
end

function compare_switch_patch_to_rebuild(
    network::FeederFlow.NetworkModel,
    ybus::FeederFlow.YBusModel,
    Y_scaled_base::AbstractMatrix{ComplexF64},
    line_names::AbstractVector{<:AbstractString},
    v_scale_full::AbstractVector{<:Real};
    regulator_model::Symbol = :nonideal,
    epsilon::Float64 = 1e-5,
)
    patch_network = deepcopy(network)
    rebuild_network = deepcopy(network)

    target_names = String[line_names...]
    old_closed = Bool[]
    new_closed = Bool[]
    for name in target_names
        patch_line = patch_network.lines[name]
        rebuild_line = rebuild_network.lines[name]
        push!(old_closed, patch_line.is_closed_base)
        push!(new_closed, !patch_line.is_closed_base)
        patch_line.is_closed = new_closed[end]
        rebuild_line.is_closed = new_closed[end]
    end

    patched = patch_switch_admittance!(Y_scaled_base, patch_network, ybus, v_scale_full)

    rebuilt_ybus = FeederFlow.build_y(rebuild_network; regulator_model, epsilon)
    rebuilt = scaled_ybus_matrix(rebuilt_ybus, v_scale_full)

    max_diff = maximum(abs.(patched .- rebuilt))
    return (
        line_name = join(target_names, ", "),
        line_names = target_names,
        old_closed = old_closed,
        new_closed = new_closed,
        max_diff = max_diff,
        patched = patched,
        rebuilt = rebuilt,
    )
end

function compare_switch_patch_to_rebuild(
    network::FeederFlow.NetworkModel,
    ybus::FeederFlow.YBusModel,
    line_name::AbstractString,
    v_scale_full::AbstractVector{<:Real};
    regulator_model::Symbol = :nonideal,
    epsilon::Float64 = 1e-5,
)
    Y_scaled_base = scaled_ybus_matrix(ybus, v_scale_full)
    return compare_switch_patch_to_rebuild(
        network,
        ybus,
        Y_scaled_base,
        [String(line_name)],
        v_scale_full;
        regulator_model = regulator_model,
        epsilon = epsilon,
    )
end

function synthetic_switch_names(network::FeederFlow.NetworkModel; limit::Int = 3)
    names = String[]
    for line in network.lines
        switch_line_admittance(network, line) === nothing && continue
        push!(names, line.name)
        length(names) >= limit && break
    end
    return names
end

function promote_switch_lines(network::FeederFlow.NetworkModel, names::AbstractVector{<:AbstractString})
    scenario = deepcopy(network)
    for name in names
        line = scenario.lines[name]
        line.is_switch = true
        line.is_closed_base = true
        line.is_closed = true
    end
    return scenario
end

function verify_switch_admittance_patch(
    network::FeederFlow.NetworkModel,
    ybus::FeederFlow.YBusModel,
    v_scale_full::AbstractVector{<:Real};
    regulator_model::Symbol = :nonideal,
    epsilon::Float64 = 1e-5,
    max_switches::Int = 3,
    atol::Float64 = 1e-8,
    verbose::Bool = true,
    allow_synthetic::Bool = true,
)
    switch_lines = [line for line in network.lines if line.is_switch]
    compare_network = network
    compare_ybus = ybus
    compare_scales = v_scale_full
    selected_names = String[]

    if isempty(switch_lines)
        allow_synthetic || error("No switch lines found for patch verification")
        selected_names = synthetic_switch_names(network; limit = max_switches)
        isempty(selected_names) && error("No patchable lines found for synthetic switch verification")
        compare_network = promote_switch_lines(network, selected_names)
        compare_ybus = FeederFlow.build_y(compare_network; regulator_model, epsilon)
        compare_scales = [compare_network.buses[node.bus].vbase / compare_network.base.Vbase for node in compare_ybus.all_order]
    else
        selected_names = String[line.name for line in first(switch_lines, min(length(switch_lines), max_switches))]
    end

    isempty(selected_names) && error("No switch lines available for patch verification")
    selected_batches = [selected_names[1:count] for count in 1:length(selected_names)]
    Y_scaled_base = scaled_ybus_matrix(compare_ybus, compare_scales)

    results = NamedTuple[]
    max_diff = 0.0

    for batch_names in selected_batches
        result = compare_switch_patch_to_rebuild(
            compare_network,
            compare_ybus,
            Y_scaled_base,
            batch_names,
            compare_scales;
            regulator_model = regulator_model,
            epsilon = epsilon,
        )
        push!(results, result)
        max_diff = max(max_diff, result.max_diff)
        if verbose
            println("  ", result.line_name, " | max |ΔY| = ", result.max_diff)
            for (name, old_closed_state, new_closed_state) in zip(result.line_names, result.old_closed, result.new_closed)
                println("    ", name, ": ", old_closed_state, " -> ", new_closed_state)
            end
        end
        result.max_diff <= atol || error("Switch patch mismatch for $(result.line_name): $(result.max_diff) > $(atol)")
    end

    return (max_diff = max_diff, results = results)
end
