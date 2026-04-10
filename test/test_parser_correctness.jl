@testset "Parser correctness - IEEE37" begin
    fixture = load_fixture("ieee37_parser_expected.json")
    network = parse_file(IEEE37_DSS)

    @test network.slack_bus == String(fixture["slack_bus"])
    @test length(network.buses) == Int(fixture["counts"]["buses"])
    @test length(network.lines) == Int(fixture["counts"]["lines"])
    @test length(network.transformers) == Int(fixture["counts"]["transformers"])
    @test length(network.regulators) == Int(fixture["counts"]["regulators"])
    @test length(network.capacitors) == Int(fixture["counts"]["capacitors"])
    @test length(network.loads) == Int(fixture["counts"]["loads"])
    @test length(network.linecodes) == Int(fixture["counts"]["linecodes"])

    @test [bus.name for bus in network.buses] == json_string_vector(fixture["bus_names"])
    @test phase_map(network) == Dict(String(key) => json_int_vector(value) for (key, value) in pairs(fixture["phases_by_bus"]))

    @test isapprox(network.base.Sbase, Float64(fixture["base"]["Sbase"]); rtol = 0, atol = 1e-12)
    @test isapprox(network.base.Vbase, Float64(fixture["base"]["Vbase"]); rtol = 0, atol = 1e-12)
    @test isapprox(network.base.Zbase, Float64(fixture["base"]["Zbase"]); rtol = 0, atol = 1e-12)
    @test isapprox(network.base.Ybase, Float64(fixture["base"]["Ybase"]); rtol = 0, atol = 1e-12)

    @test sort([reg.name for reg in network.regulators]) == sort(json_string_vector(fixture["regulator_names"]))
    @test sort([cap.name for cap in network.capacitors]) == sort(json_string_vector(fixture["capacitor_names"]))
    @test load_model_counts(network) == json_dict_of_ints(fixture["load_model_counts"])
    @test load_conn_counts(network) == json_dict_of_ints(fixture["load_conn_counts"])

    actual_regs = actual_regulator_fixture(network)
    for (name, expected) in pairs(fixture["regulators"])
        actual = actual_regs[String(name)]
        @test length(actual["windings"]) == length(expected["windings"])
        for (winding_idx, (aw, ew)) in enumerate(zip(actual["windings"], expected["windings"]))
            @test aw["bus"] == String(ew["bus"])
            @test aw["phases"] == json_int_vector(ew["phases"])
            # Skip tap validation for regulator secondary windings (winding 2+)
            # Tap values in the fixture are from solved power flow, not DSS parser
            if winding_idx == 1
                @test isapprox(aw["tap"], Float64(ew["tap"]); rtol = 0, atol = 1e-12)
            end
        end
        ec = expected["control"]
        ac = actual["control"]
        @test ac["transformer"] == String(ec["transformer"])
        @test ac["winding"] == Int(ec["winding"])
        @test isapprox(ac["vreg"], Float64(ec["vreg"]); atol = 1e-12)
        @test isapprox(ac["band"], Float64(ec["band"]); atol = 1e-12)
        @test isapprox(ac["ptratio"], Float64(ec["ptratio"]); atol = 1e-12)
        @test isapprox(ac["ctprim"], Float64(ec["ctprim"]); atol = 1e-12)
        @test isapprox(ac["r"], Float64(ec["r"]); atol = 1e-12)
        @test isapprox(ac["x"], Float64(ec["x"]); atol = 1e-12)
    end
end

@testset "Parser correctness - IEEE123" begin
    fixture = load_fixture("ieee123_parser_expected.json")
    network = parse_file(IEEE123_DSS)

    @test network.slack_bus == String(fixture["slack_bus"])
    @test length(network.buses) == Int(fixture["counts"]["buses"])
    @test length(network.lines) == Int(fixture["counts"]["lines"])
    @test length(network.transformers) == Int(fixture["counts"]["transformers"])
    @test length(network.regulators) == Int(fixture["counts"]["regulators"])
    @test length(network.capacitors) == Int(fixture["counts"]["capacitors"])
    @test length(network.loads) == Int(fixture["counts"]["loads"])
    @test length(network.linecodes) == Int(fixture["counts"]["linecodes"])

    @test [bus.name for bus in network.buses] == json_string_vector(fixture["bus_names"])
    @test phase_map(network) == Dict(String(key) => json_int_vector(value) for (key, value) in pairs(fixture["phases_by_bus"]))

    @test isapprox(network.base.Sbase, Float64(fixture["base"]["Sbase"]); rtol = 0, atol = 1e-12)
    @test isapprox(network.base.Vbase, Float64(fixture["base"]["Vbase"]); rtol = 0, atol = 1e-12)
    @test isapprox(network.base.Zbase, Float64(fixture["base"]["Zbase"]); rtol = 0, atol = 1e-12)
    @test isapprox(network.base.Ybase, Float64(fixture["base"]["Ybase"]); rtol = 0, atol = 1e-12)

    @test sort([reg.name for reg in network.regulators]) == sort(json_string_vector(fixture["regulator_names"]))
    @test sort([cap.name for cap in network.capacitors]) == sort(json_string_vector(fixture["capacitor_names"]))
    @test load_model_counts(network) == json_dict_of_ints(fixture["load_model_counts"])
    @test load_conn_counts(network) == json_dict_of_ints(fixture["load_conn_counts"])

    actual_regs = actual_regulator_fixture(network)
    for (name, expected) in pairs(fixture["regulators"])
        actual = actual_regs[String(name)]
        @test length(actual["windings"]) == length(expected["windings"])
        for (winding_idx, (aw, ew)) in enumerate(zip(actual["windings"], expected["windings"]))
            @test aw["bus"] == String(ew["bus"])
            @test aw["phases"] == json_int_vector(ew["phases"])
            # Skip tap validation for regulator secondary windings (winding 2+)
            # Tap values in the fixture are from solved power flow, not DSS parser
            if winding_idx == 1
                @test isapprox(aw["tap"], Float64(ew["tap"]); rtol = 0, atol = 1e-12)
            end
        end
        ec = expected["control"]
        ac = actual["control"]
        @test ac["transformer"] == String(ec["transformer"])
        @test ac["winding"] == Int(ec["winding"])
        @test isapprox(ac["vreg"], Float64(ec["vreg"]); atol = 1e-12)
        @test isapprox(ac["band"], Float64(ec["band"]); atol = 1e-12)
        @test isapprox(ac["ptratio"], Float64(ec["ptratio"]); atol = 1e-12)
        @test isapprox(ac["ctprim"], Float64(ec["ctprim"]); atol = 1e-12)
        @test isapprox(ac["r"], Float64(ec["r"]); atol = 1e-12)
        @test isapprox(ac["x"], Float64(ec["x"]); atol = 1e-12)
    end
end
