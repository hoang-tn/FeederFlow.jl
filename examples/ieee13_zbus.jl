using FeederFlow
using LinearAlgebra
using Printf
using SparseArrays

root = normpath(joinpath(@__DIR__, ".."))
path = joinpath(root, "examples", "grids", "13_bus", "IEEE13Nodeckt.dss")

function run_comparison()
    println("="^70)
    println("IEEE 13-BUS POWER FLOW - VOLTAGE FIXED-POINT METHOD")
    println("Based on: Bernstein et al., IEEE TPS 2018, Eq. (4)")
    println("="^70)

    network = parse_file(path; regulator_model=:nonideal)
    ybus = build_y(network; regulator_model=:nonideal, epsilon=1e-5)

    println("\n--- Network Structure ---")
    println("Number of network buses: ", length(ybus.network_order))
    println("Number of slack buses: ", length(ybus.slack_order))
    println("Total phases: ", length(ybus.all_order))

    v_slack = FeederFlow.source_slack(network.source, network.base)
    noload = compute_no_load(ybus; v_slack)

    Y_LL = ybus.Y
    Y_L0 = ybus.Y_NS

    w = noload.w

    println("\n--- Zero-Load Voltage (w) ---")
    println("w = -Y_LL^{-1} * Y_L0 * v_0")

    loads = build_load_model(network, ybus, noload)

    function extract_pq_values(loads::FeederFlow.LoadModel, ybus::FeederFlow.YBusModel)
        n = length(ybus.network_order)
        s = zeros(ComplexF64, n)
        
        for contrib in loads.contributions
            for (idx, pair) in enumerate(contrib.node_pairs)
                p_idx = pair[1]
                if p_idx > 0
                    s[p_idx] += contrib.values[idx]
                end
            end
        end
        
        return s
    end

    s_Y = extract_pq_values(loads, ybus)

    println("\n--- Load Power Summary ---")
    println("Total P: ", round(sum(real(s_Y)), digits=2), " pu")
    println("Total Q: ", round(sum(imag(s_Y)), digits=2), " pu")

    Y_LL_inv = inv(Matrix(Y_LL))

    println("\n" * "="^70)
    println("METHOD 1: VOLTAGE FIXED-POINT (Paper Eq. 4)")
    println("="^70)
    println("v^{(k+1)} = w + Y_LL^{-1} * diag(v^{(k)})^{-1} * s_Y")
    println()

    max_iter = 100
    tol = 1e-6
    v_iter = copy(w)
    history1 = Float64[]

    for iter in 1:max_iter
        v_prev = v_iter
        
        inv_diag_v = sparse(diagm(1 ./ v_prev))
        term1 = Y_LL_inv * (inv_diag_v * s_Y)
        v_next = w + term1
        
        residual = v_next - v_prev
        err = norm(residual, 1)
        push!(history1, err)
        
        if mod(iter, 20) == 1 || err <= tol
            @printf("  Iter %3d: residual = %.2e\n", iter, err)
        end
        
        if err <= tol
            println("\n  ==> VOLTAGE FIXED-POINT CONVERGED in $iter iterations!")
            break
        end
        
        v_iter = v_next
    end

    v_vfp = v_iter

    combined1 = vcat(v_vfp, v_slack)
    phase_voltages1 = Dict(node => combined1[idx] for (idx, node) in enumerate(ybus.all_order))

    println("\n--- Voltage Fixed-Point Results ---")
    println("Bus      | Phase | Mag (pu) | Angle (°)")
    println("-"^50)

    unique_buses = unique([bp.bus for bp in ybus.all_order if bp.bus != "sourcebus" && bp.bus != "rg60"])
    unique_buses = sort(unique_buses, by = x -> try parse(Int, x) catch; 999 end)

    count = 0
    for bus in unique_buses
        for phase in [1, 2, 3]
            bp = FeederFlow.BusPhase(bus, phase)
            if haskey(phase_voltages1, bp)
                V = phase_voltages1[bp]
                @printf("  %-6s | %-6s | %.4f   | %7.2f\n", bus, phase, abs(V), rad2deg(angle(V)))
                count += 1
                if count >= 15
                    break
                end
            end
        end
        count >= 15 && break
    end

    println("\n" * "="^70)
    println("METHOD 2: CURRENT INJECTION (Current FeederFlow.jl)")
    println("="^70)
    println("v^{(k+1)} = Y_LL^{-1} * (-I_load - Y_L0*v_0)")
    println()

    system = ybus.Y + loads.YL
    v_iter2 = copy(noload.w)
    history2 = Float64[]

    for iter in 1:max_iter
        v_prev2 = v_iter2
        
        injections = loads.YL * v_prev2
        v_next2 = system \ (-injections - ybus.Y_NS * v_slack)
        
        residual = system * v_next2 + loads.YL * v_next2 + ybus.Y_NS * v_slack
        err = norm(residual, 1)
        push!(history2, err)
        
        if mod(iter, 20) == 1 || err <= tol
            @printf("  Iter %3d: residual = %.2e\n", iter, err)
        end
        
        if err <= tol
            println("\n  ==> CURRENT INJECTION CONVERGED in $iter iterations!")
            break
        end
        
        v_iter2 = v_next2
    end

    v_curr_inj = v_iter2

    combined2 = vcat(v_curr_inj, v_slack)
    phase_voltages2 = Dict(node => combined2[idx] for (idx, node) in enumerate(ybus.all_order))

    println("\n--- Current Injection Results ---")
    println("Bus      | Phase | Mag (pu) | Angle (°)")
    println("-"^50)

    count = 0
    for bus in unique_buses
        for phase in [1, 2, 3]
            bp = FeederFlow.BusPhase(bus, phase)
            if haskey(phase_voltages2, bp)
                V = phase_voltages2[bp]
                @printf("  %-6s | %-6s | %.4f   | %7.2f\n", bus, phase, abs(V), rad2deg(angle(V)))
                count += 1
                if count >= 15
                    break
                end
            end
        end
        count >= 15 && break
    end

    println("\n" * "="^70)
    println("COMPARISON")
    println("="^70)

    max_diff = 0.0
    for node in ybus.all_order
        if haskey(phase_voltages1, node) && haskey(phase_voltages2, node)
            diff = abs(phase_voltages1[node] - phase_voltages2[node])
            max_diff = max(max_diff, diff)
        end
    end

    println("Max voltage difference: ", round(max_diff, digits=6))
    println("Voltage Fixed-Point iterations: ", length(history1))
    println("Current Injection iterations: ", length(history2))

    if max_diff < 1e-4
        println("\n✓ Results match closely")
    else
        println("\n⚠ Results differ - check load model equivalence")
    end
end

run_comparison()
