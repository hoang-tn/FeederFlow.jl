using OpenDSSDirect
using FeederFlow

# Check OpenDSS voltages for IEEE37
path = raw"C:\Users\hoang\OneDrive - Massachusetts Institute of Technology\1. MIT\2. Projects\4. Dist OPF\multiphase_modelling\three-phase-modeling\IEEE 37-bus feeder\IEEE37openDSSdata\ieee37opendss.dss"
quoted = replace(normpath(path), "\\" => "/")
dss("""
    clear
    compile "$quoted"
""")
Solution.Solve()

# Get all node voltages
node_names = Circuit.AllNodeNames()
node_voltages = Circuit.AllBusVolts()
node_mag_pu = Circuit.AllBusMagPu()

println("=== OpenDSSDirect Sample Nodes ===")
for i in 1:min(10, length(node_names))
    name = node_names[i]
    voltage = node_voltages[i]
    mag_pu = node_mag_pu[i]
    base_voltage = abs(voltage) / mag_pu
    println("  $name: V=$voltage, |V|=$(abs(voltage)), pu=$mag_pu, Vbase=$base_voltage")
end

# Now check FeederFlow
network = FeederFlow.parse_file(path)
bundle = FeederFlow.solve_power_flow(network)

println("\n=== FeederFlow Voltages (general) ===")
let count = 0
    for (node, voltage) in bundle.result.phase_voltages
        println("  $(node.bus).$(node.phase): V=$voltage, |V|=$(abs(voltage))")
        count += 1
        if count >= 10
            break
        end
    end
end

# Check specific high-mismatch node: 741.1
println("\n=== Detailed comparison for 741.1 ===")
Circuit.SetActiveBus("741")
bus_kv = Buses.kVBase()
println("OpenDSS bus 741 kVBase: $bus_kv")

# Find 741.1 in OpenDSS
idx = findfirst(x -> lowercase(strip(x)) == "741.1", node_names)
if idx !== nothing
    println("OpenDSS 741.1: V=$(node_voltages[idx]), pu=$(node_mag_pu[idx]), base=$(abs(node_voltages[idx])/node_mag_pu[idx])")
end

# Find in FeederFlow
key_general = FeederFlow.BusPhase("741", 1)
if haskey(bundle.result.phase_voltages, key_general)
    println("FeederFlow (general) 741.1: V=$(bundle.result.phase_voltages[key_general])")
end
