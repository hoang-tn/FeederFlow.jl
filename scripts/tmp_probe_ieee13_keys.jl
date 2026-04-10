using PowerModelsDistribution

dss_path = joinpath("FeederFlow.jl","examples","grids","13_bus","IEEE13Nodeckt.dss")
data = PowerModelsDistribution.parse_file(
    dss_path;
    data_model = PowerModelsDistribution.MATHEMATICAL,
    make_pu = true,
    kron_reduce = true,
    phase_project = true,
)

println("bus count=", length(data["bus"]))
println("branch count=", length(data["branch"]))
println("gen count=", length(data["gen"]))

first_branch = first(values(data["branch"]))
println("branch keys:")
println(sort!(collect(keys(first_branch))))

first_gen = first(values(data["gen"]))
println("gen keys:")
println(sort!(collect(keys(first_gen))))

println("first branch summary:")
for k in ["name","f_bus","t_bus","f_connections","t_connections","c_rating_a","angmin","angmax","br_r","br_x","g_fr","b_fr"]
    if haskey(first_branch, k)
        println(k, " => ", first_branch[k])
    end
end

println("all branch rating field candidates:")
for k in sort!(collect(keys(first_branch)))
    if occursin("rating", String(k)) || occursin("ang", String(k)) || occursin("curr", String(k))
        println(k, " => ", first_branch[k])
    end
end
