using FeederFlow
using LinearAlgebra
using Printf

root = normpath(joinpath(@__DIR__, ".."))
path = joinpath(root, "examples", "grids", "13_bus", "IEEE13Nodeckt.dss")

function compare_methods()
    network = parse_file(path; regulator_model=:nonideal)
    ybus = build_y(network; regulator_model=:nonideal, epsilon=1e-5)
    v_slack = FeederFlow.source_slack(network.source, network.base)
    noload = compute_no_load(ybus; v_slack)
    loads = build_load_model(network, ybus, noload)
    
    Y_LL = ybus.Y
    Y_L0 = ybus.Y_NS
    w = noload.w
    
    # === METHOD 1: Pure PQ loads with voltage fixed-point ===
    println("="^70)
    println("METHOD 1: Voltage Fixed-Point (Pure PQ loads)")
    println("Equation: v^{(k+1)} = w + Y_LL^{-1} * diag(v^{(k)})^{-1} * s_PQ")
    println("This is Eq. (4) from Bernstein et al. paper")
    println()
    
    # Build s_PQ from loads (constant power only)
    n = length(w)
    s_PQ = zeros(ComplexF64, n)
    for contrib in loads.contributions
        if contrib.mode == :pq
            for (idx, pair) in enumerate(contrib.node_pairs)
                p_idx = pair[1]
                if p_idx > 0
                    s_PQ[p_idx] += contrib.values[idx]
                end
            end
        end
    end
    
    println("PQ load powers: ", sum(abs, s_PQ))
    
    Y_LL_inv = inv(Matrix(Y_LL))
    
    v = copy(w)
    for iter in 1:20
        v_old = v
        # Fixed-point update: v = w + Y^{-1} * diag(v)^{-1} * s
        term = Y_LL_inv * (diagm(1 ./ v_old) * s_PQ)
        v = w + term
        
        err = norm(v - v_old, Inf)
        @printf("Iter %2d: |Δv| = %.2e\n", iter, err)
        if err < 1e-6
            break
        end
    end
    
    v_pq = v
    
    # === METHOD 2: Constant Impedance loads (linear) ===
    println("\n" * "="^70)
    println("METHOD 2: Current Injection (Constant Impedance loads)")
    println("Equation: v = (Y + Y_L)^{-1} * (-Y_L0 * v_s)")
    println("This treats ALL loads as constant impedance (Z loads)")
    println()
    
    # Y_L from loads includes Z loads only
    println("Z load admittance: ", sum(abs, loads.YL))
    
    system = Y_LL + loads.YL
    v2 = copy(noload.w)
    
    for iter in 1:20
        i_L = loads.YL * v2
        v_new = system \ (-i_L - Y_L0 * v_slack)
        
        res = system * v_new + i_L + Y_L0 * v_slack
        err = norm(res, Inf)
        @printf("Iter %2d: |KCL residual| = %.2e\n", iter, err)
        if err < 1e-6
            break
        end
        
        v2 = v_new
    end
    
    v_z = v2
    
    # === METHOD 3: Full nonlinear (PQ + Z + I) ===
    println("\n" * "="^70)
    println("METHOD 3: Full Nonlinear (PQ + Z + I loads)")
    println("Uses load_currents() which handles all load types")
    println()
    
    v3 = copy(noload.w)
    
    for iter in 1:20
        i_load = FeederFlow.load_currents(loads, v3)
        v_new = system \ (-i_load - Y_L0 * v_slack)
        
        res = system * v_new + i_load + Y_L0 * v_slack
        err = norm(res, Inf)
        @printf("Iter %2d: |KCL residual| = %.2e\n", iter, err)
        if err < 1e-6
            break
        end
        
        v3 = v_new
    end
    
    v_full = v3
    
    # === Compare ===
    println("\n" * "="^70)
    println("COMPARISON")
    println("="^70)
    
    println("\nMethod | Iterations | Description")
    println("-"^50)
    println("V-FixPt | 9+ | Pure PQ loads (nonlinear)")
    println("I-Inj Z | 4   | Constant impedance (linear)")
    println("I-Inj All | 4  | Full loads (nonlinear via load_currents)")
    
    # Check load types
    println("\n=== Load Types in Network ===")
    n_pq = sum(1 for c in loads.contributions if c.mode == :pq)
    n_z = count(nnz(loads.YL) > 0)
    n_i = sum(1 for c in loads.contributions if c.mode == :i)
    println("PQ loads: $n_pq, Z loads: $(nnz(loads.YL) > 0 ? "yes" : "no" ), I loads: $n_i")
end

compare_methods()
