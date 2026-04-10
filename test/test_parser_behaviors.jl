using Test
using FeederFlow

isdefined(@__MODULE__, :IEEE13_DSS) || include("test_support.jl")
isdefined(@__MODULE__, :dss_clear_compile!) || include("test_opendss_helpers.jl")


@testset "Parser behavior" begin
    mktempdir() do dir
        master = joinpath(dir, "master.dss")
        defs = joinpath(dir, "defs.dss")
        edits = joinpath(dir, "edits.dss")

        write(master, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "Redirect defs.dss",
            "Redirect edits.dss",
        ], "\n"))

        write(defs, join([
            "New linecode.code nphases=2 units=mi",
            "~ rmatrix=[1 | 0.1 2]",
            "~ xmatrix=[3 | 0.2 4]",
            "~ cmatrix=[5 | 0.3 6]",
            "New transformer.tx phases=1 windings=2 buses=[sourcebus sourcer] conns=[wye wye] kvs=[4.16 4.16] kvas=[1000 1000] xhl=1",
            "New line.l1 phases=2 bus1=busa.3.1 bus2=busb.1.3 linecode=code length=5280 units=ft",
            "New line.l2 like=l1 bus1=busb.1.3 bus2=busc.1.3",
            "New load.ld1 phases=1 bus1=busb.3.1 conn=delta model=1 kv=4.16 kw=10 kvar=5",
        ], "\n"))

        write(edits, "transformer.tx.Taps=[1.0 1.0125]\n")

        network = parse_file(master)
        @test length(network.linecodes) == 1
        @test haskey(network.linecodes, "code")
        code = network.linecodes["code"]
        @test code.nphases == 2
        @test code.rmatrix == [1.0 0.1; 0.1 2.0]
        @test code.xmatrix == [3.0 0.2; 0.2 4.0]
        @test code.cmatrix == [5.0 0.3; 0.3 6.0]

        @test length(network.lines) == 2
        @test component_names(network.lines) == ["l1", "l2"]
        l1 = network.lines["l1"]
        l2 = network.lines["l2"]
        @test l1.phases == [3, 1]
        @test l2.phases == [1, 3]
        @test l1.linecode_name == "code"
        @test l2.linecode_name == "code"
        @test l1.from.bus == "busa"
        @test l1.to.bus == "busb"
        @test l2.from.bus == "busb"
        @test l2.to.bus == "busc"
        @test l2.rmatrix == l1.rmatrix
        @test l2.xmatrix == l1.xmatrix
        @test l2.cmatrix == l1.cmatrix
        @test l1.provenance.source_file == "defs.dss"
        @test l2.provenance.source_file == "defs.dss"
        @test l1.units == "mi"
        @test l2.units == "mi"
        @test isapprox(l1.length, 1.0; atol = 1e-12)
        @test isapprox(l2.length, 1.0; atol = 1e-12)

        @test component_names(network.transformers) == ["tx"]
        tx = network.transformers["tx"]
        @test length(tx.windings) == 2
        @test isapprox(tx.windings[2].tap, 1.0125; atol = 1e-12)
        @test tx.provenance.source_file == "edits.dss"
        @test isapprox(tx.percent_loadloss, 0.4; atol = 1e-12)
        @test all(isapprox(w.resistance, 0.2; atol = 1e-12) for w in tx.windings)

        @test component_names(network.loads) == ["ld1"]
        ld = network.loads["ld1"]
        @test ld.bus.bus == "busb"
        @test ld.bus.phases == [1, 3]
        @test ld.conn == :delta
        @test network.provenance["entry_file"] == "master.dss"
        @test sort(network.provenance["files"]) == ["defs.dss", "edits.dss", "master.dss"]
    end
end

@testset "Transformer defaults match OpenDSS assumptions" begin
    network37 = parse_file(IEEE37_DSS)
    reg37 = network37.regulators["reg1a"]
    @test isapprox(reg37.percent_loadloss, 0.4; atol = 1e-12)
    @test all(isapprox(w.resistance, 0.2; atol = 1e-12) for w in reg37.windings)

    network123 = parse_file(IEEE123_DSS)
    reg123 = network123.regulators["reg1a"]
    @test isapprox(reg123.percent_loadloss, 1e-5; atol = 1e-12)
    @test all(isapprox(w.resistance, 5e-6; atol = 1e-12) for w in reg123.windings)

    network13 = parse_file(IEEE13_DSS)
    sub = network13.transformers["sub"]
    @test isapprox(sub.xhl_percent, 0.008; atol = 1e-12)
    @test length(sub.windings) == 2
    @test all(isapprox(w.resistance, 0.0005; atol = 1e-12) for w in sub.windings)

    line650632 = network13.lines["650632"]
    @test line650632.units == "mi"
    @test isapprox(line650632.length, 2000 * 0.001 / 5.28; atol = 1e-12)
    switch671692 = network13.lines["671692"]
    @test switch671692.is_switch
    @test switch671692.is_closed_base
    @test switch671692.is_closed
    @test isapprox(switch671692.length, 0.001; atol = 1e-12)

    switch632671 = network13.lines["632671"]
    @test switch632671.is_switch
    @test !switch632671.is_closed_base
    @test !switch632671.is_closed
end

@testset "IEEE13 power flow converges with parsed transformer taps" begin
    bundle13 = solve_case(IEEE13_DSS)
    @test bundle13.result.converged
    @test bundle13.result.iterations <= 10

    reg1 = bundle13.network.regulators["reg1"]
    reg2 = bundle13.network.regulators["reg2"]
    reg3 = bundle13.network.regulators["reg3"]
    @test isapprox(reg1.windings[2].tap, 1.0; atol = 1e-12)
    @test isapprox(reg2.windings[2].tap, 1.0; atol = 1e-12)
    @test isapprox(reg3.windings[2].tap, 1.0; atol = 1e-12)
end

@testset "IEEE906 loads default to wye and infer kvar from PF" begin
    network906 = parse_file(IEEE906_DSS)
    load1 = network906.loads["load1"]
    @test load1.conn == :wye
    @test load1.bus.phases == [1]
    # Values are now in per-unit, convert back for comparison
    sbase_kva = network906.base.Sbase / 1000.0
    @test isapprox(load1.p_pu * sbase_kva, 1.0; atol = 1e-12)
    @test isapprox(load1.q_pu * sbase_kva, tan(acos(0.95)); atol = 1e-12)
end

@testset "OpenDSS load model code mapping supports model=3" begin
    mktempdir() do dir
        path = joinpath(dir, "models.dss")
        write(path, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0 phases=3",
            "New linecode.tie nphases=3 units=kft r1=0.1 x1=0.2 r0=0.3 x0=0.6 c1=0 c0=0",
            "New line.tie phases=3 bus1=sourcebus.1.2.3 bus2=loadbus.1.2.3 linecode=tie length=0.05",
            "New load.m1 phases=1 bus1=loadbus.1 conn=wye model=1 kv=2.4 kw=10 kvar=4",
            "New load.m2 phases=1 bus1=loadbus.1 conn=wye model=2 kv=2.4 kw=10 kvar=4",
            "New load.m3 phases=1 bus1=loadbus.1 conn=wye model=3 kv=2.4 kw=10 kvar=4",
            "New load.m4 phases=1 bus1=loadbus.1 conn=wye model=4 kv=2.4 kw=10 kvar=4",
            "New load.m5 phases=1 bus1=loadbus.1 conn=wye model=5 kv=2.4 kw=10 kvar=4",
        ], "\n"))

        network = parse_file(path)
        ybus = build_y(network)
        noload = compute_no_load(ybus)
        loads = build_load_model(network, ybus, noload)

        @test get(loads.summary, :pq, 0) == 1
        @test get(loads.summary, :z, 0) == 1
        @test get(loads.summary, :motor, 0) == 1
        @test get(loads.summary, :cvr, 0) == 1
        @test get(loads.summary, :i, 0) == 1

        motor = only(filter(contrib -> contrib.mode == :motor, loads.contributions))
        @test all(isapprox(value, 0.0; atol = 1e-12) for value in motor.cvrwatts)
        @test all(isapprox(value, 2.0; atol = 1e-12) for value in motor.cvrvars)
    end
end

@testset "Transformer winding voltage helper is single-source and phase-aware" begin
    single_wye = TransformerWinding(1, FeederFlow.terminal("single", [1]), :wye, 2.4, 100.0, 0.1, 1.0)
    three_wye = TransformerWinding(1, FeederFlow.terminal("three", [1, 2, 3]), :wye, 4.16, 1000.0, 0.1, 1.0)
    delta_three = TransformerWinding(1, FeederFlow.terminal("delta", [1, 2, 3]), :delta, 4.16, 1000.0, 0.1, 1.0)

    @test isapprox(FeederFlow.transformer_winding_voltage(single_wye), 2400.0; atol = 1e-12)
    @test isapprox(FeederFlow.transformer_winding_voltage(three_wye), 4160.0 / sqrt(3); atol = 1e-12)
    @test isapprox(FeederFlow.transformer_winding_voltage(delta_three), 4160.0; atol = 1e-12)
end

function capture_parse_error(path::AbstractString)
    try
        parse_file(path)
        return nothing
    catch err
        return err
    end
end

@testset "Parser errors" begin
    mktempdir() do dir
        bad_like = joinpath(dir, "bad_like.dss")
        write(bad_like, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New line.l2 like=missing bus1=a.1 bus2=b.1 r1=1 x1=1 length=1",
        ], "\n"))
        err = capture_parse_error(bad_like)
        @test err isa DSSParseError
        @test err.property == "like"
        @test occursin("Unknown inherited object", err.message)

        bad_edit = joinpath(dir, "bad_edit.dss")
        write(bad_edit, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "line.missing.length=1",
        ], "\n"))
        err = capture_parse_error(bad_edit)
        @test err isa DSSParseError
        @test err.object == "line.missing"
        @test err.property == "length"

        unsupported = joinpath(dir, "unsupported.dss")
        write(unsupported, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "Foo line.l1 length=2",
        ], "\n"))
        err = capture_parse_error(unsupported)
        @test err isa DSSParseError
        @test occursin("Unsupported DSS command", err.message)
        @test err.line == 2
    end
end
