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
        ("IEEE37", IEEE37_DSS, false),
        ("IEEE123", IEEE123_DSS, false),
        ("IEEE240", IEEE240_DSS, true),
        ("IEEE906", IEEE906_DSS, true),
    )

    for (_, dss_path, expect_generators) in benchmark_cases
        network = FeederFlow.parse_file(dss_path)
        @test network.source.cost_coeff == [1.0, 100.0, 0.0]
        if expect_generators
            @test !isempty(network.generators)
            @test all(g -> g.cost_coeff == [0.1, 5.0, 0.0], network.generators)
        else
            @test isempty(network.generators)
        end
    end
end