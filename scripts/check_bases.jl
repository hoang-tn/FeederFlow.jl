using OpenDSSDirect

# Check OpenDSS base voltages for IEEE37
path = raw"C:\Users\hoang\OneDrive - Massachusetts Institute of Technology\1. MIT\2. Projects\4. Dist OPF\multiphase_modelling\three-phase-modeling\IEEE 37-bus feeder\IEEE37openDSSdata\ieee37opendss.dss"
quoted = replace(normpath(path), "\\" => "/")
dss("""
    clear
    compile "$quoted"
""")
Solution.Solve()

# Get all unique base voltages
node_names = Circuit.AllNodeNames()
node_voltages = Circuit.AllBusVolts()
node_mag_pu = Circuit.AllBusMagPu()

println("=== Base Voltage Analysis for IEEE37 ===")
bases = Dict{Float64,Vector{String}}()
for (name, voltage, mag_pu) in zip(node_names, node_voltages, node_mag_pu)
    abs(voltage) > 0 || continue
    mag_pu > 0 || continue
    base_voltage = abs(voltage) / mag_pu
    if !haskey(bases, base_voltage)
        bases[base_voltage] = String[]
    end
    push!(bases[base_voltage], name)
end

for (base, nodes) in sort!(collect(bases); by=first)
    println("\nVbase = $base V ($(length(nodes)) nodes)")
    println("  Nodes: ", join(first(nodes, 10), ", "))
    if length(nodes) > 10
        println("  ... and $(length(nodes) - 10) more")
    end
end
