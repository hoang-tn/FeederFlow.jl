using FeederFlow

# Parse IEEE37
path = raw"C:\Users\hoang\OneDrive - Massachusetts Institute of Technology\1. MIT\2. Projects\4. Dist OPF\multiphase_modelling\three-phase-modeling\IEEE 37-bus feeder\IEEE37openDSSdata\ieee37opendss.dss"
network = FeederFlow.parse_file(path)

# Check base quantities
println("=== Network Base Quantities ===")
println("  Sbase: ", network.base.Sbase)
println("  Vbase: ", network.base.Vbase)
println("  Zbase: ", network.base.Zbase)
println("  Ybase: ", network.base.Ybase)
println("  Source basekv: ", network.source.basekv)
println("  Source phases: ", network.source.phases)

# Solve power flow
bundle_general = FeederFlow.solve_power_flow(network)

# Check slack voltage
println("\n=== Slack Bus Voltages ===")
for (node, voltage) in bundle_general.result.phase_voltages
    if node.bus == network.slack_bus
        println("  $(node.bus).$(node.phase): V=$voltage, |V|=$(abs(voltage))")
    end
end

# Check a few other voltages
println("\n=== Sample Voltages (first 5) ===")
count = 0
for (node, voltage) in bundle_general.result.phase_voltages
    if node.bus != network.slack_bus
        println("  $(node.bus).$(node.phase): V=$voltage, |V|=$(abs(voltage))")
        count += 1
        if count >= 5
            break
        end
    end
end

# Expected: if pu, slack should be ~1.0; if volts, should be ~132790 V
