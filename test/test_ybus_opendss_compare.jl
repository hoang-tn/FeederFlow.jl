using FeederFlow
using LinearAlgebra
using SparseArrays
using OpenDSSDirect
using Statistics

const REPO_ROOT = "C:/Users/hoang/OneDrive - Massachusetts Institute of Technology/1. MIT/2. Projects/4. Dist OPF/multiphase_modelling"
const IEEE37_DSS = joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 37-bus feeder", "IEEE37openDSSdata", "ieee37opendss.dss")

function get_opendss_ybus()
    OpenDSSDirect.dss("clear")
    OpenDSSDirect.dss("compile \"$IEEE37_DSS\"")
    ybus = Matrix{ComplexF64}(OpenDSSDirect.Circuit.SystemY())
    nodeorder = String.(OpenDSSDirect.Circuit.YNodeOrder())
    return ybus, nodeorder, 0.32552083333333326
end

println("=" ^ 70)
println("Y-BUS COMPARISON: FeederFlow vs OpenDSS")
println("=" ^ 70)

# Parse and build Y-bus
network = parse_file(IEEE37_DSS)
ybus = build_y(network)
ff_ybus = Matrix{ComplexF64}(ybus.Ynet)
ff_ybase = network.base.Ybase

# Get OpenDSS Y-bus
dss_ybus, dss_nodeorder, dss_ybase = get_opendss_ybus()

# Reorder FeederFlow to match OpenDSS ordering
ff_all_order = vcat(ybus.network_order, ybus.slack_order)
ff_labels = [lowercase(string(node.bus, ".", node.phase)) for node in ff_all_order]

perm = Int[]
for dss_label in dss_nodeorder
    found_idx = findfirst(i -> ff_labels[i] == dss_label || lowercase(ff_labels[i]) == lowercase(dss_label), eachindex(ff_labels))
    if found_idx !== nothing
        push!(perm, found_idx)
    end
end

ff_aligned = ff_ybus[perm, perm]
ff_scaled = ff_aligned * ff_ybase / dss_ybase

# Key diagnostics
ff_sb = ff_aligned[1, 1]
dss_sb = dss_ybus[1, 1]

println("\n=== SOURCE/SLACK BUS ANALYSIS ===")
println("FeederFlow SOURCEBUS.1: $ff_sb")
println("OpenDSS SOURCEBUS.1: $dss_sb")
println("Ratio (FF/OD): $(abs(ff_sb / dss_sb))")

# Check network-only differences
n = length(ybus.network_order)
diff_network = abs.(ff_scaled[1:n, 1:n] - dss_ybus[1:n, 1:n])
max_diff = maximum(diff_network)
mean_diff = mean(diff_network)

println("\n=== NETWORK-ONLY COMPARISON (excluding slack buses) ===")
println("Nodes compared: $n x $n")
println("Max abs difference: $max_diff")
println("Mean abs difference: $mean_diff")

# Top differences
top_idx = sortperm(vec(diff_network), rev=true)[1:5]
println("\nTop 5 differences:")
for idx in top_idx
    i, j = divrem(idx - 1, 117) .+ 1
    if diff_network[i,j] > 0.1
        println("  ($i,$j): $(diff_network[i,j])")
    end
end

println("\n" * "=" ^ 70)
println("DIAGNOSIS")
println("=" ^ 70)

if abs(ff_sb / dss_sb) < 0.01
    println("✗ SUBSTATION TRANSFORMER MISSING")
    println("  The sourcebus self-admittance is ~340x smaller in FeederFlow.")
    println("  This indicates the substation transformer is not included in the Y-bus.")
end

if max_diff > 1e-3
    println("✗ Y-BUS MISMATCH")
    println("  Network Y-bus differs from OpenDSS by more than 0.1%")
    println("  Max difference: $max_diff")
end

# This test should be used to verify fixes
println("\n" * "=" ^ 70)
println("EXPECTED BEHAVIOR AFTER FIX")
println("=" ^ 70)
println("1. SOURCEBUS self-admittance should match OpenDSS (ratio > 0.9)")
println("2. Network-only max difference should be < 1e-4")
