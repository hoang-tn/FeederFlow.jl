using FeederFlow
using LinearAlgebra
using Printf

root = normpath(joinpath(@__DIR__, ".."))
path = joinpath(root, "examples", "grids", "13_bus", "IEEE13Nodeckt.dss")

# Load and solve power flow to get baseline
network = FeederFlow.parse_file(path; regulator_model=:nonideal)
bundle = FeederFlow.solve_power_flow(network)

ybus = bundle.ybus
loads = bundle.loads

n = length(ybus.network_order)
println("=== NETWORK DEBUG ===")
println("Nodes: $n")
println("Network order:")
for (i, node) in enumerate(ybus.network_order)
    println("  $i: $node")
end

# Slack info
v_slack = FeederFlow.source_slack(network.source, network.base)
slack_node = findfirst(x -> x.bus == "rg60", ybus.network_order)
slack_node === nothing && (slack_node = 1)
println("\nSlack node: $slack_node")
println("Slack V: $(v_slack[1])")

# Get loads
Pd = zeros(n)
Qd = zeros(n)
for c in loads.contributions
    for (idx, pair) in enumerate(c.node_pairs)
        p = pair[1]
        if p > 0
            s = c.values[idx]
            Pd[p] += real(s)
            Qd[p] += imag(s)
        end
    end
end

println("\n=== LOAD AT EACH NODE ===")
for i in 1:n
    if Pd[i] != 0 || Qd[i] != 0
        println("  Node $i ($(ybus.network_order[i])): P=$(Pd[i]), Q=$(Qd[i])")
    end
end

# Check Y matrix
Y = Matrix(ybus.Y)
println("\n=== Y MATRIX ===")
println("Size: $(size(Y))")
println("Sample Y[1,:]: ", Y[1,1:5])

# Get voltage result
result = bundle.result
V = result.voltages
println("\n=== POWER FLOW SOLUTION ===")
println("Converged: $(result.converged)")
println("Iterations: $(result.iterations)")

# Calculate actual power injection at each bus from solution
# P = sum_j(V_i * conj(Y_ij) * conj(V_j))
# But easier: compute from V and Y

# Just show key voltages
println("\nKey bus voltages:")
for (idx, node) in enumerate(ybus.network_order)
    if node.bus in ["632", "650", "670", "671", "675", "680", "684", "rg60"]
        @printf("  %s.%s: %.4f ∠%.1f°\n", node.bus, node.phase, abs(V[idx]), rad2deg(angle(V[idx])))
    end
end

# Total load
println("\nTotal load: P=$(sum(Pd)), Q=$(sum(Qd))")

# What does the solver say about generation needed?
# If slack is at ~27V, it's in actual volts, not pu
# We need to check units
println("\n=== UNIT CHECK ===")
println("v_slack[1]: ", v_slack[1], " (should this be per-unit?)")
println("base.Vbase: ", network.base.Vbase)
println("base.Sbase: ", network.base.Sbase)
