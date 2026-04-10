using OpenDSSDirect
const REPO_ROOT = "C:/Users/hoang/OneDrive - Massachusetts Institute of Technology/1. MIT/2. Projects/4. Dist OPF/multiphase_modelling"
const IEEE37_DSS = joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 37-bus feeder", "IEEE37openDSSdata", "ieee37opendss.dss")
println("DSS path: $IEEE37_DSS")

OpenDSSDirect.dss("clear")
OpenDSSDirect.dss("compile \"$IEEE37_DSS\"")
ybus = OpenDSSDirect.Circuit.YMatrix(Get=true)
println("Ybus size: ", size(ybus))

# Try to get base
props = names(OpenDSSDirect.Solution)
println("Solution props: $props")

# Get bus names to identify ordering
bus_names = OpenDSSDirect.Circuit.BusNames()
println("Num buses: ", length(bus_names))
println("First 5 buses: ", bus_names[1:5])
