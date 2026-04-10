using FeederFlow
using LinearAlgebra
using Printf

root = normpath(joinpath(@__DIR__, ".."))
path = joinpath(root, "examples", "grids", "13_bus", "IEEE13Nodeckt.dss")

function debug_load_currents()
    network = parse_file(path; regulator_model=:nonideal)
    ybus = build_y(network; regulator_model=:nonideal, epsilon=1e-5)
    v_slack = FeederFlow.source_slack(network.source, network.base)
    noload = compute_no_load(ybus; v_slack)
    loads = build_load_model(network, ybus, noload)
    
    # Test voltage
    v_test = copy(noload.w)
    
    # YL * v (linear part - Z loads only)
    i_z = loads.YL * v_test
    
    # load_currents (nonlinear - includes PQ loads)
    i_nl = FeederFlow.load_currents(loads, v_test)
    
    println("YL * v (Z loads only): ", sum(abs, i_z))
    println("load_currents (all): ", sum(abs, i_nl))
    println("Difference: ", sum(abs, i_nl - i_z))
    
    # Check what's in contributions
    println("\n=== Load Contributions ===")
    for (i, contrib) in enumerate(loads.contributions)
        println("Contribution $i: mode=$(contrib.mode), conn=$(contrib.connection), values=$(length(contrib.values))")
    end
    
    println("\n=== YL matrix stats ===")
    println("Non-zeros in YL: ", nnz(loads.YL))
end

debug_load_currents()
