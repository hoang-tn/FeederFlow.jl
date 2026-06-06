using PowerModelsDistribution

function pmd_math_model(path::AbstractString)
    PowerModelsDistribution.parse_file(
        path;
        data_model = PowerModelsDistribution.MATHEMATICAL,
        make_pu = true,
        kron_reduce = false,
        phase_project = false,
    )
end

function pmd_branch_map(data)
    Dict(String(branch["name"]) => branch for branch in values(data["branch"]) if haskey(branch, "name"))
end

function pmd_load_map(data)
    Dict(String(load["name"]) => load for load in values(data["load"]) if haskey(load, "name"))
end

function line_pu_matrix(line::LineDevice, branch, sbase::Float64)
    vbase = Float64(branch["vbase"])
    scale = (sbase / 1000) / vbase^2
    complex.(line.rmatrix, line.xmatrix) * line.length * scale
end

function connection_key(phases::Vector{Int})
    return sort(collect(phases))
end

function connection_config(conn::Symbol)
    conn == :delta && return "DELTA"
    return "WYE"
end

@testset "PMD parser/per-unit comparison - IEEE123" begin
    network = FeederFlow.parse_file(IEEE123_DSS)
    math = pmd_math_model(IEEE123_DSS)
    branches = pmd_branch_map(math)
    loads = pmd_load_map(math)
    sbase = Float64(math["settings"]["sbase"])
    feederflow_sbase_kva = network.base.Sbase / 1000.0

    @test length(branches) >= length(network.lines)
    @test length(loads) == length(network.loads)

    for line in network.lines
        @test haskey(branches, line.name)
        haskey(branches, line.name) || continue
        branch = branches[line.name]
        expected = line_pu_matrix(line, branch, sbase)
        @test sort(branch["f_connections"]) == sort(collect(line.from.phases))
        @test sort(branch["t_connections"]) == sort(collect(line.to.phases))
        @test isapprox(branch["br_r"], real(expected); rtol = 1e-8, atol = 1e-10)
        @test isapprox(branch["br_x"], imag(expected); rtol = 1e-8, atol = 1e-10)
    end

    for load in network.loads
        @test haskey(loads, load.name)
        math_load = loads[load.name]
        @test sort(filter(!=(4), math_load["connections"])) == connection_key(load.bus.phases)
        @test (4 in math_load["connections"]) == (load.conn == :wye)
        @test string(math_load["configuration"]) == connection_config(load.conn)
        @test isapprox(sum(math_load["pd"]), load.p_pu * feederflow_sbase_kva / sbase; rtol = 1e-8, atol = 1e-10)
        @test isapprox(sum(math_load["qd"]), load.q_pu * feederflow_sbase_kva / sbase; rtol = 1e-8, atol = 1e-10)
    end
end
