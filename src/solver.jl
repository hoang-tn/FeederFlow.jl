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
    n = size(ybus.Y, 1)
    used_regularization = false
    regularization = 0.0
    w = try
        -(ybus.Y \ rhs)
    catch err
        err isa LinearAlgebra.SingularException || rethrow(err)
        nothing
    end
    if w === nothing
        # Stiff/large feeders can yield a singular Y; use a modest fixed shift (do not
        # scale by norm(Y, Inf) — IEEE8500 admittances are badly scaled in pu).
        used_regularization = true
        regularization = 1e-6
        w = -((ybus.Y + spdiagm(0 => fill(regularization, n))) \ rhs)
    end
    phase_voltages = Dict{BusPhase,ComplexF64}()
    for (index, node) in enumerate(ybus.network_order)
        phase_voltages[node] = w[index]
    end
    for (index, node) in enumerate(ybus.slack_order)
        phase_voltages[node] = v_slack[index]
    end
    return NoLoadResult(v_slack, w, phase_voltages)
end

"""Concatenate network and slack phase voltages in `ybus.all_order` layout."""
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
    normalize_result_to_local_bases(result, network, all_order) -> PowerFlowResult

Express voltages in each bus's local per-unit base (`BusSpec.vbase` LN volts).

Global Y-bus quantities use `network.base.Vbase`; local pu is
`|V|_local = |V|_global * (Vbase_global / Vbase_bus)`.
"""
function normalize_result_to_local_bases(result::PowerFlowResult,
                                         network::NetworkModel,
                                         all_order::Vector{BusPhase})
    bus_vbase = Dict(bus.name => bus.vbase for bus in network.buses)
    global_vbase = network.base.Vbase
    scaled = Vector{ComplexF64}(undef, length(all_order))
    phase_voltages = Dict{BusPhase,ComplexF64}()
    for (idx, node) in enumerate(all_order)
        local_base = get(bus_vbase, node.bus, global_vbase)
        scale = global_vbase / local_base
        scaled[idx] = result.voltages[idx] * scale
        if haskey(result.phase_voltages, node)
            phase_voltages[node] = result.phase_voltages[node] * scale
        end
    end
    return PowerFlowResult(
        result.iterations,
        result.converged,
        scaled,
        phase_voltages,
        abs.(scaled),
        rad2deg.(angle.(scaled)),
        result.history,
    )
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
    v_slack = source_slack(network.source, network.base)
    noload = compute_no_load(ybus; v_slack)
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
    normalized = normalize_result_to_local_bases(result, network, ybus.all_order)
    return AnalysisBundle(network, ybus, noload, loads, result, normalized)
end

"""
    get_normalized_result(bundle) -> PowerFlowResult

Return the canonical power-flow result.

Returns local-bus-base per-unit voltages when available; otherwise the global-base result.
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
        err = norm(residual, Inf)
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
    solve_case(path; include_neutral=false, randomize_pv_cost=false, pv_cost_seed=12345,
               pv_cost_spread=0.5, apply_benchmark_regulator_taps=false,
               method=:zbus, regulator_model=:nonideal, epsilon=1e-5, max_iter=10, tol=1e-5)

Convenience wrapper for parsing an OpenDSS master file and solving power flow.
"""
function solve_case(path::AbstractString;
                    include_neutral::Bool = false,
                    randomize_pv_cost::Bool = false,
                    pv_cost_seed::Integer = 12345,
                    pv_cost_spread::Real = 0.5,
                    apply_benchmark_regulator_taps::Bool = false,
                    method::Symbol = :zbus,
                    regulator_model::Symbol = :nonideal,
                    epsilon::Float64 = 1e-5,
                    max_iter::Int = 10,
                    tol::Float64 = 1e-5)
    network = parse_file(path;
        include_neutral = include_neutral,
        randomize_pv_cost = randomize_pv_cost,
        pv_cost_seed = pv_cost_seed,
        pv_cost_spread = pv_cost_spread,
        apply_benchmark_regulator_taps = apply_benchmark_regulator_taps,
    )
    return solve_power_flow(network; method, regulator_model, epsilon, max_iter, tol)
end
