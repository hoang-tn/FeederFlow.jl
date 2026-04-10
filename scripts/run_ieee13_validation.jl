include(joinpath(@__DIR__, "run_validation_scenarios.jl"))

output_dir = raw"C:\Users\hoang\Desktop\ieee13_validation"
rm(output_dir; recursive=true, force=true)

main(["--networks=ieee13", "--num-scenarios=10", "--output-dir=$output_dir"])

