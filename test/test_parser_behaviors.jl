using Test
using FeederFlow
using SparseArrays

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

@testset "xfkVA allocates load kW when kW is absent" begin
    mktempdir() do dir
        path = joinpath(dir, "xfkva_load.dss")
        write(path, """
        Clear
        New Circuit.test bus1=sourcebus basekv=12.47 pu=1.0
        New Load.ld phases=1 bus1=loadbus.1 conn=wye model=1 kv=7.2 xfkVA=100 pf=0.98
        """)
        net = parse_file(path)
        ld = net.loads["ld"]
        @test ld.p_pu > 0
        @test isapprox(ld.p_pu * (net.base.Sbase / 1000), 100 * 0.98; rtol=1e-6)
    end
end

@testset "Leading-zero and GIS numeric bus names" begin
    @test FeederFlow.should_preserve_numeric_bus_token("05410")
    @test FeederFlow.should_preserve_numeric_bus_token("1160483")
    @test !FeederFlow.should_preserve_numeric_bus_token("5410")
    @test !FeederFlow.should_preserve_numeric_bus_token("1.5")
    @test !FeederFlow.should_preserve_numeric_bus_token("633")

    @test FeederFlow.parse_atom("05410") == "05410"
    @test FeederFlow.parse_atom("1160483.2") == "1160483.2"

    term = FeederFlow.parse_bus_terminal("05410"; nphases = 3)
    @test term.bus == "05410"
    @test term.phases == [1, 2, 3]

    mktempdir() do dir
        path = joinpath(dir, "leading_zero.dss")
        write(path, """
        Clear
        New Circuit.test bus1=sourcebus basekv=34.5 pu=1.0
        New Line.head phases=3 bus1=subxfmr_lsb bus2=05410 length=1 units=km r1=0.01 x1=0.02
        New Line.tail phases=3 bus1=05410.1.2.3 bus2=loadbus.1.2.3 length=1 units=km r1=0.01 x1=0.02
        """)
        net = parse_file(path)
        head = net.lines["head"]
        tail = net.lines["tail"]
        @test head.to.bus == "05410"
        @test tail.from.bus == "05410"
        @test !haskey(net.buses, "5410")
        @test haskey(net.buses, "05410")
    end
end

@testset "Transformer defaults match OpenDSS assumptions" begin
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

    network240 = parse_file(IEEE240_DSS)
    @test network240.slack_bus == "eq_source_bus"
    @test isapprox(network240.base.Vbase, 13_800.0 / sqrt(3); atol = 1e-9)
    @test haskey(network240.buses, "eq_source_bus")
    @test isapprox(network240.buses["eq_source_bus"].vbase, 69_000.0 / sqrt(3); atol = 1e-9)
    @test !isempty(network240.regulators)
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
    three_wye_neutral = TransformerWinding(1, FeederFlow.TerminalSpec("three", [1, 2, 3, 0]), :wye, 4.16, 1000.0, 0.1, 1.0)
    delta_three = TransformerWinding(1, FeederFlow.terminal("delta", [1, 2, 3]), :delta, 4.16, 1000.0, 0.1, 1.0)

    @test isapprox(FeederFlow.transformer_winding_voltage(single_wye), 2400.0; atol = 1e-12)
    @test isapprox(FeederFlow.transformer_winding_voltage(three_wye), 4160.0 / sqrt(3); atol = 1e-12)
    @test isapprox(FeederFlow.transformer_winding_voltage(three_wye_neutral), 4160.0 / sqrt(3); atol = 1e-12)
    @test isapprox(FeederFlow.kv_to_vbase(4.16, [1, 2, 3, 4]), 4160.0 / sqrt(3); atol = 1e-12)
    @test isapprox(FeederFlow.transformer_winding_voltage(delta_three), 4160.0; atol = 1e-12)
end

@testset "Neutral conductors are filtered from modeled phases" begin
    mktempdir() do dir
        path = joinpath(dir, "neutral.dss")
        write(path, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus.1.2.3.4 pu=1.0 phases=3",
            "New linecode.tie nphases=3 units=kft r1=0.1 x1=0.2 r0=0.3 x0=0.6 c1=0 c0=0",
            "New line.tie phases=3 bus1=sourcebus.1.2.3.4 bus2=loadbus.1.2.3.4 linecode=tie length=0.05",
            "New load.ld phases=3 bus1=loadbus.1.2.3.4 conn=wye kv=4.16 kw=10 kvar=4",
        ], "\n"))

        network = parse_file(path)
        ybus = build_y(network)

        @test network.source.phases == [1, 2, 3]
        @test network.lines["tie"].phases == [1, 2, 3]
        @test network.loads["ld"].bus.phases == [1, 2, 3]
        @test !haskey(ybus.all_index, BusPhase("loadbus", 4))
        @test size(ybus.Y_NS, 2) == 3
        @test length(compute_no_load(ybus).w) == length(ybus.network_order)
    end
end

@testset "Three-winding center-tapped transformer stamps all low-voltage legs" begin
    mktempdir() do dir
        path = joinpath(dir, "center_tap.dss")
        write(path, join([
            "New object=circuit.test basekv=7.9677 bus1=sourcebus.1.2.3 pu=1.0 phases=3",
            "New Transformer.tx phases=1 windings=3 xhl=2.0 xht=2.0 xlt=1.3",
            "~ wdg=1 bus=sourcebus.1.0 conn=wye kv=7.9677 kva=25 %r=0.5",
            "~ wdg=2 bus=lowbus.1.0 conn=wye kv=0.120 kva=25 %r=1.0",
            "~ wdg=3 bus=lowbus.0.2 conn=wye kv=0.120 kva=25 %r=1.0",
            "New load.ld phases=2 conn=wye bus1=lowbus.1.2 kv=0.208 kw=1 kvar=0",
        ], "\n"))

        network = parse_file(path)
        ybus = build_y(network)

        @test network.transformers["tx"].phases == [1, 2]
        @test network.transformers["tx"].windings[2].bus.phases == [1, 0]
        @test network.transformers["tx"].windings[3].bus.phases == [0, 2]
        @test network.loads["ld"].bus.phases == [1, 2]

        for phase in (1, 2)
            idx = ybus.network_index[BusPhase("lowbus", phase)]
            @test nnz(ybus.Ynet[idx, :]) + nnz(ybus.Ynet[:, idx]) > 0
        end
    end
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
