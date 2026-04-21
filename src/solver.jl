"""
    compute_no_load(ybus; v_slack=balanced_slack())

Solve the no-load linear system `Y * w = -Y_NS * v_slack` to find network
node voltages when all load currents are zero.

The slack bus voltages are fixed by `v_slack` (default: balanced three-phase
at 1.0 pu). Returns both the network voltages `w` and the combined phase
voltage dictionary.
"""
function compute_no_load(ybus::YBusModel; v_slack::Vector{ComplexF64} = balanced_slack())
    rhs = ybus.Y_NS * v_slack
    try
        w = -(ybus.Y \ rhs)
        phase_voltages = Dict{BusPhase,ComplexF64}()
        for (index, node) in enumerate(ybus.network_order)
            phase_voltages[node] = w[index]
        end
        for (index, node) in enumerate(ybus.slack_order)
            phase_voltages[node] = v_slack[index]
        end
        return NoLoadResult(v_slack, w, phase_voltages)
    catch err
        err isa LinearAlgebra.SingularException || rethrow(err)
    end

    regularization = 1e-9
    w = -((ybus.Y + spdiagm(0 => fill(regularization, size(ybus.Y, 1)))) \ rhs)
    phase_voltages = Dict{BusPhase,ComplexF64}()
    for (index, node) in enumerate(ybus.network_order)
        phase_voltages[node] = w[index]
    end
    for (index, node) in enumerate(ybus.slack_order)
        phase_voltages[node] = v_slack[index]
    end
    return NoLoadResult(v_slack, w, phase_voltages)
end

function full_voltage_vector(ybus::YBusModel, v_network::Vector{ComplexF64}, v_slack::Vector{ComplexF64})
    return vcat(v_network, v_slack)
end

"""
    normalize_voltage_to_bus_base(v, bp, base)

Compatibility helper for legacy callers.

FeederFlow now uses one global system base (MATLAB-style), so this returns the
input voltage unchanged.
"""
function normalize_voltage_to_bus_base(v::ComplexF64, bp::BusPhase, base::BaseQuantities)
    return v
end

"""
    normalize_result_to_local_bases(result, base) -> PowerFlowResult

Compatibility helper for legacy callers.

Under single global-base operation, this returns `result` unchanged.
"""
function normalize_result_to_local_bases(result::PowerFlowResult, base::BaseQuantities, all_order::Vector{BusPhase})
    return result
end

"""
    analyze_network_once(network; method=:zbus, max_iter=10, tol=1e-5)

Assemble Y-bus, solve no-load voltages, build load models, run power flow,
and compute regulator secondary voltages. Returns an `AnalysisBundle`.

# Arguments
- `network`: parsed distribution network model
- `method`: power flow method (only `:zbus` supported in v1)
- `regulator_model`: `:nonideal` (with series impedance) or `:ideal` (zero impedance)
- `epsilon`: small numerical regularization parameter
- `max_iter`, `tol`: Z-bus solver convergence parameters
"""
function analyze_network_once(network::NetworkModel; method::Symbol = :zbus, regulator_model::Symbol = :nonideal, epsilon::Float64 = 1e-5, max_iter::Int = 10, tol::Float64 = 1e-5)
    ybus = build_y(network; regulator_model, epsilon)
    noload = compute_no_load(ybus; v_slack = source_slack(network.source, network.base))
    loads = build_load_model(network, ybus, noload)
    ybus = YBusModel(ybus.Ynet, ybus.Y, ybus.Y_NS, ybus.Y_SS, ybus.network_order, ybus.slack_order, ybus.all_order, ybus.network_index, ybus.all_index, ybus.available_phases, loads.YL)
    bundle = AnalysisBundle(network, ybus, noload, loads, PowerFlowResult(0, false, ComplexF64[], Dict{BusPhase,ComplexF64}(), Float64[], Float64[], Float64[]))
    result = solve_power_flow(bundle; method, max_iter, tol)
    bundle = AnalysisBundle(network, ybus, noload, loads, result)
    secondary_voltages = compute_regulator_secondary_voltages(bundle)
    if !isempty(secondary_voltages)
        phase_voltages = merge(result.phase_voltages, secondary_voltages)
        result = PowerFlowResult(
            result.iterations,
            result.converged,
            result.voltages,
            phase_voltages,
            result.magnitudes,
            result.angles_deg,
            result.history,
        )
        bundle = AnalysisBundle(network, ybus, noload, loads, result)
    end
    # Single-base policy: keep one canonical system-base result.
    bundle = AnalysisBundle(network, ybus, noload, loads, result)
    return bundle
end

"""
    get_normalized_result(bundle) -> PowerFlowResult

Return the canonical power-flow result.

Under single global-base operation, this is identical to `bundle.result`.
"""
function get_normalized_result(bundle::AnalysisBundle)
    bundle.normalized_result === nothing ? bundle.result : bundle.normalized_result
end

"""
    get_voltages_local_base(bundle)

Deprecated alias for `get_normalized_result`.
"""
get_voltages_local_base(bundle::AnalysisBundle) = get_normalized_result(bundle)

"""
    solve_power_flow(bundle; method=:zbus, max_iter=10, tol=1e-5)

Run fixed-point Z-bus iterations using the preassembled analysis bundle and
return a `PowerFlowResult`.
"""
function solve_power_flow(bundle::AnalysisBundle; method::Symbol = :zbus, max_iter::Int = 10, tol::Float64 = 1e-5)
    return solve_power_flow(bundle, method, max_iter, tol)
end

function solve_power_flow(bundle::AnalysisBundle, method::Symbol, max_iter::Int, tol::Float64)
    method == :zbus || error("Only :zbus is supported in v1")
    ybus = bundle.ybus
    loads = bundle.loads
    slack = bundle.noload.slack
    system = ybus.Y + loads.YL
    v = copy(bundle.noload.w)
    history = Float64[]
    converged = false
    iterations = 0
    regularization = 1e-9
    for iter in 1:max_iter
        injections = load_currents(loads, v)
        rhs = -injections - ybus.Y_NS * slack
        try
            v = system \ rhs
        catch err
            err isa LinearAlgebra.SingularException || rethrow(err)
            v = (system + spdiagm(0 => fill(regularization, size(system, 1)))) \ rhs
        end
        residual = system * v + load_currents(loads, v) + ybus.Y_NS * slack
        err = norm(residual, 1)
        push!(history, err)
        iterations = iter
        if err <= tol
            converged = true
            break
        end
    end
    combined = full_voltage_vector(ybus, v, slack)
    phase_voltages = Dict{BusPhase,ComplexF64}()
    for (idx, node) in enumerate(ybus.all_order)
        is_source_internal_slack_bus(node.bus) && continue
        phase_voltages[node] = combined[idx]
    end
    return PowerFlowResult(
        iterations,
        converged,
        combined,
        phase_voltages,
        abs.(combined),
        rad2deg.(angle.(combined)),
        history,
    )
end

"""
    solve_power_flow(network; method=:zbus, regulator_model=:nonideal, epsilon=1e-5, max_iter=10, tol=1e-5)

Build Y-bus and load operators from a parsed `NetworkModel`, solve power flow,
and return an `AnalysisBundle`.
"""
function solve_power_flow(network::NetworkModel; method::Symbol = :zbus, regulator_model::Symbol = :nonideal, epsilon::Float64 = 1e-5, max_iter::Int = 10, tol::Float64 = 1e-5)
    return analyze_network_once(network; method, regulator_model, epsilon, max_iter, tol)
end

"""
    solve_case(path; kwargs...)

Convenience wrapper for `parse_file(path; kwargs...) |> solve_power_flow`.
"""
function solve_case(path::AbstractString; kwargs...)
    network = parse_file(path; kwargs...)
    return solve_power_flow(network; kwargs...)
end
