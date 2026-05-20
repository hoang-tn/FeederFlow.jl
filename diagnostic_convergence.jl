using Logging
global_logger(Logging.ConsoleLogger(stderr, Logging.Warn))

using Pkg
Pkg.activate(@__DIR__)
using FeederFlow
using Statistics
using SparseArrays
using LinearAlgebra

grids = [
    ("13_bus", joinpath("examples", "grids", "13_bus", "IEEE13Nodeckt.dss")),
    ("37_bus", joinpath("examples", "grids", "37_bus", "ieee37.dss")),
    ("123_bus", joinpath("examples", "grids", "123_bus", "IEEE123Master.dss")),
    ("240_bus", joinpath("examples", "grids", "240_bus", "Master.dss")),
    ("906_bus", joinpath("examples", "grids", "906_bus", "Master.dss")),
    ("IEEE8500 balanced", joinpath("examples", "grids", "IEEE8500", "Master.dss")),
    ("IEEE8500 unbalanced", joinpath("examples", "grids", "IEEE8500", "Master-unbal.dss"))
]

println("\n" * "="^80)
println("CONVERGENCE ANALYSIS: Network Characteristics & Load Models")
println("="^80)

for (name, filepath) in grids
    full_path = joinpath(@__DIR__, filepath)
    if isfile(full_path)
        println("\n" * "-"^80)
        println("Network: $name")
        println("-"^80)
        try
            network = FeederFlow.parse_file(full_path)
            
            # Network size metrics
            println("\n1. Network Size:")
            println("   Buses: $(length(network.buses))")
            println("   Lines/Cables: $(length(network.lines))")
            println("   Loads: $(length(network.loads))")
            println("   Generators: $(length(network.generators))")
            println("   Regulators: $(length(network.regulators))")
            
            # Build Y-bus for admittance statistics
            ybus = FeederFlow.build_y(network; regulator_model=:nonideal)
            v_slack = FeederFlow.source_slack(network.source, network.base)
            noload = FeederFlow.compute_no_load(ybus; v_slack)
            loads = FeederFlow.build_load_model(network, ybus, noload)
            
            println("\n2. System Matrix Properties:")
            println("   Network nodes: $(length(ybus.network_order))")
            println("   Total DOF: $(length(ybus.all_order))")
            println("   Y-matrix nnz: $(nnz(ybus.Y))")
            println("   YL (load admittance) nnz: $(nnz(loads.YL))")
            y_sys = ybus.Y + loads.YL
            println("   System matrix nnz: $(nnz(y_sys))")
            
            println("\n3. Load Model Distribution:")
            println("   PQ loads: $(loads.summary[:pq])")
            println("   Z loads: $(loads.summary[:z])")
            println("   I loads: $(loads.summary[:i])")
            println("   Motor loads: $(loads.summary[:motor])")
            println("   CVR loads: $(loads.summary[:cvr])")
            total_loads = sum(values(loads.summary))
            if total_loads > 0
                println("   % Nonlinear (PQ/I/Motor/CVR): $(round(100.0 * (total_loads - loads.summary[:z]) / total_loads; digits=1))%")
            end
            
            # Check for voltage-dependent load modes
            has_voltage_dep = (loads.summary[:motor] > 0 || loads.summary[:cvr] > 0 || loads.summary[:i] > 0)
            println("   Voltage-dependent loads: $(has_voltage_dep ? "YES" : "NO")")
            
            # Solve and capture convergence history
            bundle = FeederFlow.analyze_network_once(network; max_iter=100, tol=1e-5)
            r = bundle.result
            mags = [abs(v) for v in values(r.phase_voltages)]
            
            println("\n4. Power Flow Convergence:")
            println("   Converged: $(r.converged)")
            println("   Iterations: $(r.iterations)")
            println("   Final residual: $(r.history[end])")
            println("   |V| min: $(minimum(mags)) pu")
            println("   |V| max: $(maximum(mags)) pu")
            
            # Convergence rate analysis
            if length(r.history) > 1
                ratios = [r.history[i+1] / r.history[i] for i in 1:min(5, length(r.history)-1)]
                avg_ratio = mean(ratios)
                println("   Early convergence rate (avg ratio iter i+1/i): $(round(avg_ratio; digits=3))")
                
                if length(r.history) > 10
                    late_ratios = [r.history[i+1] / r.history[i] for i in max(6, length(r.history)-5):length(r.history)-1]
                    late_avg = mean(late_ratios)
                    println("   Late convergence rate (avg ratio): $(round(late_avg; digits=3))")
                end
            end
            
            # Estimate convergence time constant from residual decay
            if length(r.history) > 3 && r.history[1] > 0
                # Fit to exponential decay: log(residual) ≈ -k*iter + C
                iter_range = min(10, length(r.history))
                log_residuals = log.(r.history[1:iter_range] .+ 1e-15)
                slopes = [log_residuals[i] - log_residuals[i+1] for i in 1:iter_range-1]
                avg_slope = mean(slopes)
                println("   Estimated decay constant (log scale): $(round(avg_slope; digits=4))")
            end
            
        catch e
            println("  Error: ", e)
            import Base.showerror
            showerror(stderr, e)
        end
    else
        println("File not found for $name: $full_path")
    end
end

println("\n" * "="^80)
println("INTERPRETATION:")
println("="^80)
println("""
Convergence speed depends on:
1. Network size: Larger networks → more iterations
2. Nonlinearity: Voltage-dependent loads (CVR, motor, I-models) slow convergence
3. Voltage disparity: Wide voltage range (high V_max/V_min) indicates weak coupling
4. Condition number: Poorly conditioned Y-matrix → slow fixed-point iteration
5. Fixed-point iteration itself: Z-bus method inherently slower than Newton-Raphson

IEEE8500 likely has:
- Much larger network (8500 buses vs ~250)
- Higher proportion of voltage-dependent loads
- Weaker voltage regulation (wider voltage band)
- Poorer system conditioning
""")
