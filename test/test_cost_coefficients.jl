@testset "Cost coefficient defaults" begin
    source = SourceSpec("source", "sourcebus", [1, 2, 3], 12.47, 1.0)
    @test source.cost_coeff == [1.0, 100.0, 0.0]
    @test source.conn == :wye

    legacy_source = SourceSpec("legacy", "busx", [1, 2, 3], 12.47, 1.0, 15.0, 7.5, :delta)
    @test legacy_source.cost_coeff == [7.5, 0.0, 0.0]
    @test legacy_source.conn == :delta

    provenance = Provenance("fixture.dss", "pv1", Dict{String,Any}(), "direct")
    generator = GeneratorDevice(
        "pv1",
        TerminalSpec("bus1", [1, 2, 3]),
        [1, 2, 3],
        :wye,
        4.16,
        0.5,
        1.0,
        0.6,
        0.3,
        -0.3,
        0.95,
        1.05,
        [0.1, 5.0, 0.0],
        :pv,
        provenance,
    )
    @test generator.cost_coeff == [0.1, 5.0, 0.0]

    legacy_generator = GeneratorDevice(
        "pv2",
        TerminalSpec("bus2", [1, 2, 3]),
        [1, 2, 3],
        :wye,
        4.16,
        0.5,
        1.0,
        0.6,
        0.3,
        -0.3,
        0.95,
        1.05,
        2.25,
        :pv,
        provenance,
    )
    @test legacy_generator.cost_coeff == [2.25, 0.0, 0.0]

    base = BaseQuantities(1.0e6, 12.47e3, (12.47e3)^2 / 1.0e6, 1.0e6 / (12.47e3)^2)
    converted = FeederFlow.convert_generators_to_pu([generator], base)
    @test converted[1].cost_coeff == generator.cost_coeff

    benchmark_cases = (
        ("IEEE13", IEEE13_DSS, true),
        ("IEEE123", IEEE123_DSS, true),
        ("IEEE240", IEEE240_DSS, true),
        ("IEEE906", IEEE906_DSS, true),
    )

    for (_, dss_path, expect_generators) in benchmark_cases
        network = FeederFlow.parse_file(dss_path; randomize_pv_cost=false)
        @test network.source.cost_coeff == [1.0, 100.0, 0.0]
        if expect_generators
            @test !isempty(network.generators)
            @test all(g -> g.cost_coeff == [0.1, 5.0, 0.0], network.generators)
        else
            @test isempty(network.generators)
        end
    end
end

@testset "PV cost coefficient randomization" begin
    spread = 0.5
    base = FeederFlow.DEFAULT_PV_COST_COEFF
    c0_bounds = (base[1] * (1 - spread), base[1] * (1 + spread))
    c1_bounds = (base[2] * (1 - spread), base[2] * (1 + spread))

    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New pvsystem.pv1 phases=1 bus1=a.1 kv=4.16 pmpp=100 kva=110",
            "New pvsystem.pv2 phases=1 bus1=b.1 kv=4.16 pmpp=50 kva=60",
        ], "\n"))

        network = FeederFlow.parse_file(f; randomize_pv_cost=true, pv_cost_seed=42, pv_cost_spread=spread)
        pv1 = network.generators["pv1"]
        pv2 = network.generators["pv2"]

        @test c0_bounds[1] ≤ pv1.cost_coeff[1] ≤ c0_bounds[2]
        @test c1_bounds[1] ≤ pv1.cost_coeff[2] ≤ c1_bounds[2]
        @test pv1.cost_coeff[3] == 0.0
        @test pv1.cost_coeff != pv2.cost_coeff

        network_repeat = FeederFlow.parse_file(f; randomize_pv_cost=true, pv_cost_seed=42, pv_cost_spread=spread)
        @test network_repeat.generators["pv1"].cost_coeff == pv1.cost_coeff
        @test network_repeat.generators["pv2"].cost_coeff == pv2.cost_coeff
    end

    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New pvsystem.pv1 phases=1 bus1=a.1 kv=4.16 pmpp=100 kva=110",
        ], "\n"))
        network = FeederFlow.parse_file(f; randomize_pv_cost=false)
        @test network.generators["pv1"].cost_coeff == base
    end
end