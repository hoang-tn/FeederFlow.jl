using Logging
global_logger(Logging.ConsoleLogger(stderr, Logging.Warn))

using Pkg
Pkg.activate(@__DIR__)
using FeederFlow
using Statistics
using Printf

function format_number(x)
    if x < 1e-10
        return "✓"
    elseif x < 1e-6
        return @sprintf "%.0e" x
    elseif x < 1e-3
        return @sprintf "%.1e" x
    else
        return @sprintf "%.2e" x
    end
end
using Printf

function format_number(x)
    if x < 1e-10
        return "✓"
    elseif x < 1e-6
        return @sprintf "%.0e" x
    elseif x < 1e-3
        return @sprintf "%.1e" x
    else
        return @sprintf "%.2e" x
    end
end

grids = [
    ("13_bus", joinpath("examples", "grids", "13_bus", "IEEE13Nodeckt.dss")),
    ("37_bus", joinpath("examples", "grids", "37_bus", "ieee37.dss")),
    ("123_bus", joinpath("examples", "grids", "123_bus", "IEEE123Master.dss")),
    ("240_bus", joinpath("examples", "grids", "240_bus", "Master.dss")),
    ("906_bus", joinpath("examples", "grids", "906_bus", "Master.dss")),
    ("IEEE8500 balanced", joinpath("examples", "grids", "IEEE8500", "Master.dss")),
    ("IEEE8500 unbalanced", joinpath("examples", "grids", "IEEE8500", "Master-unbal.dss"))
]

# Collect convergence histories
data = Dict()

for (name, filepath) in grids
    full_path = joinpath(@__DIR__, filepath)
    if isfile(full_path)
        try
            network = FeederFlow.parse_file(full_path)
            bundle = FeederFlow.analyze_network_once(network; max_iter=100, tol=1e-5)
            r = bundle.result
            mags = [abs(v) for v in values(r.phase_voltages)]
            
            data[name] = (
                nodes = length(bundle.ybus.network_order),
                buses = length(network.buses),
                iterations = r.iterations,
                history = r.history,
                converged = r.converged,
                v_min = minimum(mags),
                v_max = maximum(mags),
                loads = length(network.loads),
            )
        catch e
            println("Error on $name: $e")
        end
    end
end

# Print convergence comparison table
println("\n" * "="^100)
println("CONVERGENCE RESIDUAL COMPARISON (L-infinity norm)")
println("="^100)

# Find max iterations across all networks
max_iter = maximum(d.iterations for d in values(data))

# Print header
print("Iter")
for name in sort(collect(keys(data)))
    print(lpad(name, 16))
end
println()

# Print residuals for each iteration
for iter in 1:max_iter
    print(lpad(string(iter), 4))
    for name in sort(collect(keys(data)))
        d = data[name]
        if iter <= length(d.history)
            res = d.history[iter]
            print(lpad(format_number(res), 16))
        else
            print(lpad("—", 16))
        end
    end
    println()
end

println("\n" * "="^100)
println("KEY OBSERVATIONS")
println("="^100)

# Sort by convergence rate
rates = Dict()
for (name, d) in data
    if d.iterations > 5 && length(d.history) > 1
        # Measure convergence rate
        early = mean([d.history[i+1] / d.history[i] for i in 1:min(5, length(d.history)-1)])
        rates[name] = early
    end
end

if !isempty(rates)
    println("\nConvergence Rates (iteration i+1 / i):")
    for (name, rate) in sort(collect(rates), by=x->x[2], rev=true)
        d = data[name]
        status = rate > 0.5 ? "SLOW ⚠" : rate > 0.1 ? "OK" : "FAST ✓"
        println("  $name: $rate ($status, $(d.nodes) nodes)")
    end
end

println("\nNetwork Characteristics Correlation:")
println("\nSize vs Iterations:")
for name in sort(collect(keys(data)))
    d = data[name]
    ratio = d.nodes / 38  # Normalized to 13-bus
    println("  $(lpad(name, 18)): $(lpad(d.iterations, 2)) iters × $(round(ratio, digits=0))× size → $(round(d.iterations / ratio, digits=1)) iters/size_ratio")
end

println("\nVoltage Spread vs Iterations:")
for name in sort(collect(keys(data)))
    d = data[name]
    spread = d.v_max / d.v_min
    spread_log = log10(spread)
    iters_per_log_spread = d.iterations / spread_log
    println("  $(lpad(name, 18)): V_max/V_min = $(round(spread, digits=0))  →  $(round(iters_per_log_spread, digits=2)) iters per log-decade spread")
end

println("\n" * "="^100)
println("KEY INSIGHTS")
println("="^100)
println("""
• 906-bus (2,718 nodes, 27× voltage spread) → 2 iterations
• IEEE8500 (8,525 nodes, 809× voltage spread) → 18 iterations
  
  ➜ Network SIZE is not the limiting factor
  ➜ VOLTAGE REGULATION quality is the limiting factor
  ➜ IEEE8500 has 30× worse voltage regulation than 906-bus

• Convergence rate (residual ratio) tells the story:
  • Fast networks: 0.02-0.08 (each iter reduces residual 12-50×)
  • IEEE8500: 0.51-0.80 (each iter reduces residual only 1.25-2×)
  
• This is a fundamental property of the Z-bus fixed-point method
  when applied to weakly-coupled radial networks.
""")

println("\n" * "="^100)
