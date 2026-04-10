using JSON3

fixture_file = raw"C:\Users\hoang\OneDrive - Massachusetts Institute of Technology\1. MIT\2. Projects\4. Dist OPF\multiphase_modelling\FeederFlow.jl\test\fixtures\ieee37_matlab_reference.json"
data = JSON3.read(read(fixture_file, String))

println("Keys: ", keys(data))
println("\nall_order type: ", typeof(data.all_order))
println("all_order length: ", length(data.all_order))
println("First 5: ", collect(data.all_order)[1:5])

println("\nfinal_phase_voltages type: ", typeof(data.final_phase_voltages))
println("final_phase_voltages length: ", length(data.final_phase_voltages))
println("First 10: ", collect(data.final_phase_voltages)[1:10])
