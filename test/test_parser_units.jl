# Unit tests for FeederFlow parser internals
# Covers: tokenization primitives, literal parsing, normalization helpers,
# command collection, component-level parsers, and error paths.

# ── Helpers ──────────────────────────────────────────────────────────────────

# Shorten qualified access to internal functions
const FF = FeederFlow

# ── strip_comment ─────────────────────────────────────────────────────────────

@testset "strip_comment" begin
    # Basic cases
    @test FF.strip_comment("") == ""
    @test FF.strip_comment("  ") == ""
    @test FF.strip_comment("hello world") == "hello world"

    # ! comment
    @test FF.strip_comment("abc ! comment") == "abc"
    @test FF.strip_comment("! entire line") == ""
    @test FF.strip_comment("   ! leading spaces") == ""

    # // comment
    @test FF.strip_comment("abc // comment") == "abc"
    @test FF.strip_comment("// entire line") == ""
    @test FF.strip_comment("a/b") == "a/b"  # single slash is NOT a comment

    # ! and // inside double quotes are preserved
    @test FF.strip_comment("\"hello ! world\"") == "\"hello ! world\""
    @test FF.strip_comment("\"url // path\"") == "\"url // path\""

    # ! and // inside single quotes are preserved
    @test FF.strip_comment("'hello ! world'") == "'hello ! world'"
    @test FF.strip_comment("'url // path'") == "'url // path'"

    # Comment after quoted string
    @test FF.strip_comment("\"value\" ! comment") == "\"value\""
    @test FF.strip_comment("key=\"val\" // rest") == "key=\"val\""

    # Whitespace trimming
    @test FF.strip_comment("  value  ") == "value"
    @test FF.strip_comment("  value  ! comment  ") == "value"
end

# ── strip_block_comments ──────────────────────────────────────────────────────

@testset "strip_block_comments" begin
    # No comment → unchanged
    text, state = FF.strip_block_comments("hello", false)
    @test text == "hello"
    @test state == false

    # Inline block comment removed (replacement inserts a single space, so
    # surrounding whitespace means the result has extra spaces — collapse them)
    text, state = FF.strip_block_comments("before /* mid */ after", false)
    @test !occursin("/*", text) && !occursin("*/", text)
    @test occursin("before", text) && occursin("after", text)
    @test state == false

    # Block comment starts but not closed → signals open state
    text, state = FF.strip_block_comments("code /* start", false)
    @test strip(text) == "code"
    @test state == true

    # Continuation: inside block, close found on this line
    text, state = FF.strip_block_comments("still in block */ after", true)
    @test strip(text) == "after"
    @test state == false

    # Continuation: inside block, no close found → empty, still open
    text, state = FF.strip_block_comments("still in block", true)
    @test text == ""
    @test state == true

    # Multiple inline block comments on one line — all comment content removed
    text, state = FF.strip_block_comments("a /* x */ b /* y */ c", false)
    @test strip(replace(text, r"\s+" => " ")) == "a b c"
    @test state == false
end

# ── tokenize_dss ─────────────────────────────────────────────────────────────

@testset "tokenize_dss" begin
    @test FF.tokenize_dss("") == []
    @test FF.tokenize_dss("  ") == []

    # Simple tokens
    @test FF.tokenize_dss("New line.l1") == ["New", "line.l1"]
    @test FF.tokenize_dss("a b   c") == ["a", "b", "c"]

    # key=value stays as one token (no space around =)
    @test FF.tokenize_dss("key=value") == ["key=value"]

    # Quoted string with internal spaces is a single token
    @test FF.tokenize_dss("a \"hello world\" b") == ["a", "\"hello world\"", "b"]
    @test FF.tokenize_dss("a 'hello world' b") == ["a", "'hello world'", "b"]

    # Brackets keep internal spaces together
    @test FF.tokenize_dss("buses=[a b c]") == ["buses=[a b c]"]
    @test FF.tokenize_dss("matrix=[1 2 | 3 4]") == ["matrix=[1 2 | 3 4]"]

    # Parentheses also bind
    @test FF.tokenize_dss("taps=(1.0 1.05)") == ["taps=(1.0 1.05)"]

    # Mixed: quote and bracket
    @test FF.tokenize_dss("a [x y] \"q r\"") == ["a", "[x y]", "\"q r\""]

    # Nested brackets (depth tracking)
    @test FF.tokenize_dss("x=[[1 2] [3 4]]") == ["x=[[1 2] [3 4]]"]
end

# ── split_literal_rows ────────────────────────────────────────────────────────

@testset "split_literal_rows" begin
    @test FF.split_literal_rows("1 2 3") == ["1 2 3"]
    @test FF.split_literal_rows("1 | 2 3") == ["1", "2 3"]
    @test FF.split_literal_rows("1 | 0.1 2 | 0.2 0.3 3") == ["1", "0.1 2", "0.2 0.3 3"]

    # Trailing pipe → empty final row
    rows = FF.split_literal_rows("1 2 |")
    @test length(rows) == 2
    @test rows[1] == "1 2"

    # Pipe inside quotes is preserved (not a row separator)
    @test FF.split_literal_rows("\"a|b\" | c") == ["\"a|b\"", "c"]
end

# ── parse_atom ────────────────────────────────────────────────────────────────

@testset "parse_atom" begin
    @test FF.parse_atom("") == ""
    @test FF.parse_atom("  ") == ""

    # Quoted strings → unquoted
    @test FF.parse_atom("\"hello\"") == "hello"
    @test FF.parse_atom("'world'") == "world"

    # Booleans (case-insensitive)
    @test FF.parse_atom("yes") === true
    @test FF.parse_atom("YES") === true
    @test FF.parse_atom("no") === false
    @test FF.parse_atom("NO") === false

    # Floats
    @test FF.parse_atom("3.14") isa Float64
    @test FF.parse_atom("3.14") ≈ 3.14
    @test FF.parse_atom("1e3") ≈ 1000.0
    @test FF.parse_atom("-2.5") ≈ -2.5

    # Raw string fallback
    @test FF.parse_atom("wye") == "wye"
    @test FF.parse_atom("abc123") == "abc123"
end

# ── parse_literal ─────────────────────────────────────────────────────────────

@testset "parse_literal" begin
    # Scalar
    @test FF.parse_literal("42") ≈ 42.0
    @test FF.parse_literal("\"text\"") == "text"

    # Empty brackets
    @test FF.parse_literal("[]") == Any[]
    @test FF.parse_literal("()") == Any[]

    # Simple numeric vector (single row)
    result = FF.parse_literal("[1 2 3]")
    @test result isa Vector
    @test length(result) == 1
    @test result[1] ≈ [1.0, 2.0, 3.0]

    # Comma-separated vector
    result = FF.parse_literal("[1,2,3]")
    @test result isa Vector
    @test result[1] ≈ [1.0, 2.0, 3.0]

    # Multi-row matrix (lower-triangle OpenDSS format)
    # [1 | 0.1 2] → row1=[1], row2=[0.1 2]
    result = FF.parse_literal("[1 | 0.1 2]")
    @test result isa Vector{Vector{Float64}}
    @test length(result) == 2
    @test result[1] ≈ [1.0]
    @test result[2] ≈ [0.1, 2.0]

    # Parentheses are equivalent to brackets
    result = FF.parse_literal("(1 2)")
    @test result isa Vector
    @test result[1] ≈ [1.0, 2.0]

    # Mixed (non-numeric → not promoted)
    result = FF.parse_literal("[a b c]")
    @test result isa Vector
    @test all(x isa AbstractString for x in result[1])
end

# ── normalize_key ─────────────────────────────────────────────────────────────

@testset "normalize_key" begin
    @test FF.normalize_key("PHASES") == "phases"
    @test FF.normalize_key("  Phases  ") == "phases"
    @test FF.normalize_key("%loadloss") == "pctloadloss"
    @test FF.normalize_key("%R") == "pctr"
    @test FF.normalize_key("pctR") == "pctr"
    @test FF.normalize_key("xhl") == "xhl"
end

# ── property_alias ────────────────────────────────────────────────────────────

@testset "property_alias" begin
    props = Dict{String,Any}("phases" => 3, "pctloadloss" => 0.4)

    # Single name hit
    @test FF.property_alias(props, "phases") == 3

    # Multiple aliases: first match wins
    @test FF.property_alias(props, "phases", "nphases") == 3
    @test FF.property_alias(props, "nphases", "phases") == 3

    # Miss on all → nothing
    @test FF.property_alias(props, "missing") === nothing
    @test FF.property_alias(props, "a", "b") === nothing

    # % alias resolution (keys stored as normalized)
    @test FF.property_alias(props, "pctloadloss") ≈ 0.4
end

# ── resolve_path ──────────────────────────────────────────────────────────────

@testset "resolve_path" begin
    mktempdir() do dir
        base = joinpath(dir, "master.dss")

        # Relative path resolved against base's directory
        resolved = FF.resolve_path(base, "sub.dss")
        @test resolved == normpath(joinpath(dir, "sub.dss"))

        # Quoted relative path
        resolved = FF.resolve_path(base, "\"sub.dss\"")
        @test resolved == normpath(joinpath(dir, "sub.dss"))

        # Absolute path returned as-is (normalized)
        abs_path = normpath(joinpath(dir, "other", "file.dss"))
        @test FF.resolve_path(base, abs_path) == abs_path
    end
end

# ── collect_commands ──────────────────────────────────────────────────────────

@testset "collect_commands - line continuation" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New linecode.code nphases=2",
            "~ rmatrix=[1 | 0.1 2]",
            "~ xmatrix=[3 | 0.2 4]",
        ], "\n"))
        cmds = FF.collect_commands(f)
        # 3 commands: circuit, linecode (merged with 2 continuations)
        @test length(cmds) == 2
        linecode_cmd = cmds[2][1]
        @test occursin("rmatrix", linecode_cmd)
        @test occursin("xmatrix", linecode_cmd)
    end
end

@testset "collect_commands - redirect chain" begin
    mktempdir() do dir
        sub = joinpath(dir, "sub.dss")
        master = joinpath(dir, "master.dss")
        write(sub, "New linecode.code nphases=3\n")
        write(master, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "Redirect sub.dss",
        ], "\n"))
        cmds = FF.collect_commands(master)
        @test length(cmds) == 2
        @test occursin("circuit", cmds[1][1])
        @test occursin("linecode", cmds[2][1])
    end
end

@testset "collect_commands - circular redirect guard" begin
    mktempdir() do dir
        a = joinpath(dir, "a.dss")
        b = joinpath(dir, "b.dss")
        write(a, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "Redirect b.dss",
        ], "\n"))
        write(b, "Redirect a.dss\n")
        # Should not infinite-loop; a.dss visited first so b→a redirect is skipped
        cmds = FF.collect_commands(a)
        @test length(cmds) >= 1
    end
end

@testset "collect_commands - block comments" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "/* this is a",
            "   multi-line comment */",
            "New linecode.code nphases=3",
        ], "\n"))
        cmds = FF.collect_commands(f)
        @test length(cmds) == 2
        @test occursin("circuit", cmds[1][1])
        @test occursin("linecode", cmds[2][1])
    end
end

@testset "collect_commands - orphan continuation error" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, "~ orphan continuation\n")
        @test_throws FF.DSSParseError FF.collect_commands(f)
    end
end

@testset "collect_commands - missing redirect target error" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "Redirect",
        ], "\n"))
        @test_throws FF.DSSParseError FF.collect_commands(f)
    end
end

# ── parse_object_header ───────────────────────────────────────────────────────

@testset "parse_object_header" begin
    # Standard: New line.l1 ...
    t, n = FF.parse_object_header(["New", "line.l1", "phases=3"], "f.dss", 1)
    @test t == "line"
    @test n == "l1"

    # With object= prefix: New object=line.l1 ...
    t, n = FF.parse_object_header(["New", "object=line.l1", "phases=3"], "f.dss", 1)
    @test t == "line"
    @test n == "l1"

    # Missing type.name → error
    @test_throws FF.DSSParseError FF.parse_object_header(["New", "justname"], "f.dss", 1)

    # Missing second token → error
    @test_throws FF.DSSParseError FF.parse_object_header(["New"], "f.dss", 1)
end

# ── assign_property! ──────────────────────────────────────────────────────────

@testset "assign_property! - object-level and winding" begin
    obj = FF.DSSObject("transformer", "tx", Dict{String,Any}(),
        FF.Provenance("f.dss", "transformer.tx", Dict{String,Any}(), ""))

    FF.assign_property!(obj, "phases", 3)
    @test obj.properties["phases"] == 3

    # Winding-specific storage
    FF.assign_property!(obj, "kv", 4.16; winding = 1)
    FF.assign_property!(obj, "kv", 0.48; winding = 2)
    windings = obj.properties["__windings__"]
    @test windings[1]["kv"] ≈ 4.16
    @test windings[2]["kv"] ≈ 0.48

    # Object-level property still separate
    @test obj.properties["phases"] == 3
end

# ── parse_dss (command dispatch) ──────────────────────────────────────────────

@testset "parse_dss - nonmath commands accumulate" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "Set voltagebases=[4.16]",
            "CalcVoltageBases",
            "Solve",
        ], "\n"))
        state = FF.parse_dss(f)
        nonmath = [lowercase(cmd) for (cmd, _, _) in state.nonmath_commands]
        @test any(startswith(c, "set") for c in nonmath)
        @test any(startswith(c, "calcvoltagebases") for c in nonmath)
        @test any(startswith(c, "solve") for c in nonmath)
    end
end

@testset "parse_dss - inline edit syntax (type.name.prop=val)" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New transformer.tx phases=1 windings=2 buses=[sourcebus sourcer] kvs=[4.16 4.16] kvas=[1000 1000] xhl=1",
            "transformer.tx.Taps=[1.0 1.025]",
        ], "\n"))
        state = FF.parse_dss(f)
        tx = state.objects[("transformer", "tx")]
        @test tx.provenance.source_file == "test.dss"
        # Tap update is recorded in the provenance command
        @test occursin("1.025", tx.provenance.command_origin)
    end
end

@testset "parse_dss - edit command updates provenance" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New line.l1 phases=1 bus1=a.1 bus2=b.1 r1=1 x1=1 length=1",
            "Edit line.l1 length=2",
        ], "\n"))
        state = FF.parse_dss(f)
        l1 = state.objects[("line", "l1")]
        @test l1.properties["length"] ≈ 2.0
        @test occursin("length=2", l1.provenance.command_origin)
    end
end

# ── parse_linecode - sequence parameter path ──────────────────────────────────

@testset "parse_linecode - sequence parameters (r1/x1) for 3-phase" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New linecode.seq3 nphases=3 r1=0.1 x1=0.2 r0=0.3 x0=0.4 c1=0.0 c0=0.0",
        ], "\n"))
        network = parse_file(f)
        code = network.linecodes["seq3"]
        @test code.nphases == 3
        @test size(code.rmatrix) == (3, 3)
        # Diagonal should be close to (2*r1 + r0)/3
        diag_val = (2 * 0.1 + 0.3) / 3
        @test isapprox(code.rmatrix[1, 1], diag_val; atol = 1e-10)
        # Off-diagonal should be close to (r0 - r1)/3
        offdiag_val = (0.3 - 0.1) / 3
        @test isapprox(code.rmatrix[1, 2], offdiag_val; atol = 1e-10)
        # issymmetric uses exact ==; use isapprox for floating-point roundoff
        @test isapprox(code.rmatrix, code.rmatrix'; atol = 1e-12)
        @test isapprox(code.xmatrix, code.xmatrix'; atol = 1e-12)
    end
end

@testset "parse_linecode - sequence parameters for 1-phase" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New linecode.seq1 nphases=1 r1=0.5 x1=0.3",
        ], "\n"))
        network = parse_file(f)
        code = network.linecodes["seq1"]
        @test code.nphases == 1
        @test size(code.rmatrix) == (1, 1)
        @test code.rmatrix[1, 1] ≈ 0.5
        @test code.xmatrix[1, 1] ≈ 0.3
    end
end

@testset "parse_linecode - defaults when no impedance specified" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New linecode.empty nphases=2",
        ], "\n"))
        network = parse_file(f)
        code = network.linecodes["empty"]
        @test all(iszero, code.rmatrix)
        @test all(iszero, code.xmatrix)
        @test all(iszero, code.cmatrix)
    end
end

# ── parse_load - PF-based kvar inference ──────────────────────────────────────

@testset "parse_load - kvar from positive power factor" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New load.pf_load phases=1 bus1=a.1 conn=wye kv=4.16 kw=100 pf=0.95",
        ], "\n"))
        network = parse_file(f)
        load = network.loads["pf_load"]
        expected_kvar = 100.0 * tan(acos(0.95))
        # Values are now in per-unit, convert back for comparison
        sbase_kva = network.base.Sbase / 1000.0
        @test isapprox(load.q_pu * sbase_kva, expected_kvar; atol = 1e-10)
        @test load.q_pu * sbase_kva > 0
    end
end

@testset "parse_load - kvar from negative power factor (leading)" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New load.pf_load phases=1 bus1=a.1 conn=wye kv=4.16 kw=100 pf=-0.95",
        ], "\n"))
        network = parse_file(f)
        load = network.loads["pf_load"]
        expected_kvar = -100.0 * tan(acos(0.95))
        sbase_kva = network.base.Sbase / 1000.0
        @test isapprox(load.q_pu * sbase_kva, expected_kvar; atol = 1e-10)
        @test load.q_pu * sbase_kva < 0
    end
end

@testset "parse_load - zero kvar when neither kvar nor pf specified" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New load.bare phases=1 bus1=a.1 conn=wye kv=4.16 kw=50",
        ], "\n"))
        network = parse_file(f)
        load = network.loads["bare"]
        sbase_kva = network.base.Sbase / 1000.0
        @test isapprox(load.q_pu * sbase_kva, 0.0; atol = 1e-12)
    end
end

@testset "parse_load - single-phase delta connection parsed correctly" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New load.dload phases=1 bus1=abus conn=delta kv=4.16 kw=10 kvar=5",
        ], "\n"))
        network = parse_file(f)
        load = network.loads["dload"]
        @test load.conn == :delta
        # parse_bus_terminal fills phases=[1] from nphases=1, so the
        # isempty(bus.phases) guard in parse_load never triggers here.
        @test load.bus.phases == [1]
        @test load.bus.bus == "abus"
    end
end

# ── parse_enabled ─────────────────────────────────────────────────────────────

@testset "parse_enabled" begin
    @test FF.parse_enabled(nothing) == true
    @test FF.parse_enabled("yes") == true
    @test FF.parse_enabled("YES") == true
    @test FF.parse_enabled("y") == true
    @test FF.parse_enabled("true") == true
    @test FF.parse_enabled("1") == true
    @test FF.parse_enabled("no") == false
    @test FF.parse_enabled("NO") == false
    @test FF.parse_enabled("n") == false
    @test FF.parse_enabled("false") == false
    @test FF.parse_enabled("0") == false
    @test FF.parse_enabled(true) == true
    @test FF.parse_enabled(false) == false
    # Default used for unknown values
    @test FF.parse_enabled("garbage") == true
    @test FF.parse_enabled("garbage", false) == false
end

# ── parse_pvsystem → GeneratorDevice ──────────────────────────────────────────

@testset "parse_pvsystem - GeneratorDevice with OPF fields" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New pvsystem.pv1 phases=1 bus1=a.1 kv=4.16 pmpp=100 pf=0.95 kva=110",
        ], "\n"))
        network = parse_file(f; randomize_pv_cost=false)
        pv = network.generators["pv1"]
        sbase_kva = network.base.Sbase / 1000.0
        @test pv.generator_type == :pv
        @test pv.p_pu * sbase_kva == 100.0
        @test pv.pf == 0.95
        @test pv.kva_pu * sbase_kva == 110.0
        # Q limits from inverter circle: Qmax = sqrt(S^2 - P^2)
        expected_qmax = sqrt(110.0^2 - 100.0^2)
        @test isapprox(pv.qmax_pu * sbase_kva, expected_qmax; atol = 1e-10)
        @test isapprox(pv.qmin_pu * sbase_kva, -expected_qmax; atol = 1e-10)
        @test pv.vminpu == 0.9
        @test pv.vmaxpu == 1.1
        @test pv.cost_coeff == [0.1, 5.0, 0.0]
        @test pv.conn == :wye
        # PV should NOT appear in loads
        @test !haskey(network.loads, "pv1")
    end
end

# ── object enabled/disabled ───────────────────────────────────────────────────

@testset "disabled objects are excluded from parse_file" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New linecode.active nphases=1 r1=1 x1=1",
            "New linecode.inactive nphases=1 r1=2 x1=2 enabled=no",
        ], "\n"))
        network = parse_file(f)
        @test haskey(network.linecodes, "active")
        @test !haskey(network.linecodes, "inactive")
    end
end

# ── per-bus voltage base propagation ─────────────────────────────────────────

@testset "single global voltage base - transformer step-down feeder" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New transformer.sub phases=3 windings=2 buses=[sourcebus lowbus] conns=[wye wye] kvs=[4.16 0.48] kvas=[500 500] xhl=0.01",
            "New line.dist phases=3 bus1=lowbus bus2=loadbus linecode=dummy length=1",
            "New linecode.dummy nphases=3 r1=0.1 x1=0.1",
            "New load.ld1 phases=3 bus1=loadbus kv=0.48 kw=10 kvar=5",
        ], "\n"))
        network = parse_file(f)

        @test isapprox(network.base.Vbase, 480.0 / sqrt(3); rtol = 1e-9)
        @test isapprox(network.buses["sourcebus"].vbase, 4160.0 / sqrt(3); rtol = 1e-9)
        @test isapprox(network.buses["lowbus"].vbase, 480.0 / sqrt(3); rtol = 1e-9)
        @test isapprox(network.buses["loadbus"].vbase, 480.0 / sqrt(3); rtol = 1e-9)
    end
end

@testset "single global voltage base - delta source with step-down transformer" begin
    mktempdir() do dir
        f = joinpath(dir, "test_delta_source.dss")
        write(f, join([
            "New object=circuit.test basekv=115 bus1=sourcebus pu=1.0",
            "New transformer.sub phases=3 windings=2 buses=[sourcebus mvbus] conns=[delta wye] kvs=[115 4.16] kvas=[5000 5000] xhl=8",
            "New line.dist phases=3 bus1=mvbus bus2=loadbus linecode=dummy length=1",
            "New linecode.dummy nphases=3 r1=0.1 x1=0.1",
            "New load.ld1 phases=3 bus1=loadbus kv=4.16 kw=100 kvar=50",
        ], "\n"))

        network = parse_file(f)
        @test isapprox(network.base.Vbase, 4160.0 / sqrt(3); rtol = 1e-9)
        @test isapprox(network.buses["sourcebus"].vbase, 115_000.0 / sqrt(3); rtol = 1e-9)
        @test isapprox(network.buses["mvbus"].vbase, 4160.0 / sqrt(3); rtol = 1e-9)
        @test isapprox(network.buses["loadbus"].vbase, 4160.0 / sqrt(3); rtol = 1e-9)
    end
end

@testset "single global voltage base - benchmark feeders" begin
    ln3(v) = v / sqrt(3)
    cases = [
        ("IEEE37", IEEE37_DSS, ln3(4800.0), [
            ("sourcebus", ln3(230_000.0)),
            ("799", ln3(4800.0)),
            ("799r", ln3(4800.0)),
            ("775", ln3(480.0)),
        ]),
        ("IEEE13", IEEE13_DSS, ln3(4160.0), [
            ("sourcebus", ln3(115_000.0)),
            ("650", ln3(4160.0)),
            ("634", ln3(480.0)),
        ]),
        ("IEEE123", IEEE123_DSS, ln3(4160.0), [
            ("150", ln3(4160.0)),
            ("610", ln3(480.0)),
        ]),
        ("IEEE240", IEEE240_DSS, ln3(13_800.0), [
            ("eq_source_bus", ln3(69_000.0)),
            ("bus1009", ln3(13_800.0)),
            ("t_bus3131_l", ln3(13_800.0) * 0.120 / 7.9677),
        ]),
    ]

    for (label, dss_path, global_vbase, bus_checks) in cases
        @testset "$label" begin
            network = FF.parse_file(dss_path)
            @test isapprox(network.base.Vbase, global_vbase; rtol = 1e-9)
            for (bus_name, expected_vbase) in bus_checks
                @test isapprox(network.buses[bus_name].vbase, expected_vbase; rtol = 1e-9)
            end
        end
    end

    @testset "IEEE906" begin
        network = parse_file(IEEE906_DSS)
        @test isapprox(network.base.Vbase, ln3(416.0); rtol = 1e-9)
        @test isapprox(network.buses["sourcebus"].vbase, ln3(11_000.0); rtol = 1e-9)
        non_source = [bus.vbase for bus in network.buses if bus.name != network.slack_bus]
        @test !isempty(non_source)
        @test all(isapprox(vbase, network.base.Vbase; rtol = 1e-9) for vbase in non_source)
    end
end

# ── like inheritance ──────────────────────────────────────────────────────────

@testset "like inheritance copies and overrides properties" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "New linecode.base nphases=3 r1=0.5 x1=0.3",
            "New linecode.derived like=base r1=0.9",
        ], "\n"))
        network = parse_file(f)
        base = network.linecodes["base"]
        derived = network.linecodes["derived"]
        # Overridden property
        @test derived.rmatrix[1, 1] != base.rmatrix[1, 1]
        # xmatrix inherited from base
        @test isapprox(derived.xmatrix[1, 1], base.xmatrix[1, 1]; atol = 1e-10)
    end
end

# ── vector_property / float_vector / string_vector / matrix_property ──────────

@testset "vector_property helpers" begin
    # vector_property with nothing
    @test FF.vector_property(nothing) == Any[]

    # vector_property with scalar
    result = FF.vector_property(3.14)
    @test result == [3.14]

    # vector_property with space-separated string
    result = FF.vector_property("a b c")
    @test result == ["a", "b", "c"]

    # vector_property with flat vector
    result = FF.vector_property([1.0, 2.0, 3.0])
    @test result ≈ [1.0, 2.0, 3.0]
end

@testset "matrix_property helpers" begin
    # Zeros when nothing
    m = FF.matrix_property(nothing, 3)
    @test m == zeros(3, 3)

    # Lower-triangle expansion from parse_literal format
    raw = [[1.0], [0.1, 2.0]]   # two rows as returned by parse_literal
    m = FF.matrix_property(raw, 2)
    @test m[1, 1] ≈ 1.0
    @test m[2, 2] ≈ 2.0
    @test m[1, 2] ≈ 0.1
    @test m[2, 1] ≈ 0.1  # symmetrized
end

# ── parse_float with RPN expressions ─────────────────────────────────────────

@testset "parse_float - RPN arithmetic" begin
    # RPN: "2 3 +" → 5.0
    @test FF.parse_float([2.0, 3.0, "+"]) ≈ 5.0
    @test FF.parse_float([10.0, 2.0, "/"]) ≈ 5.0
    @test FF.parse_float([3.0, 4.0, "*"]) ≈ 12.0
    @test FF.parse_float([5.0, 2.0, "^"]) ≈ 25.0

    # RPN text form (OpenDSS uses "(1 2 +)" syntax)
    @test FF.parse_float("(2 3 +)") ≈ 5.0
end

# ── bus terminal parsing ──────────────────────────────────────────────────────

@testset "should_preserve_bus_terminal_token" begin
    @test FF.should_preserve_bus_terminal_token("05410")
    @test FF.should_preserve_bus_terminal_token("1160483")
    @test FF.should_preserve_bus_terminal_token("1160483.2")
    @test FF.should_preserve_bus_terminal_token("63683.1.3")
    @test FF.should_preserve_bus_terminal_token("sourcebus.1.2.3.0")
    @test FF.should_preserve_bus_terminal_token("_MDV_SUB_1_LSB.1.2.3.0")
    @test !FF.should_preserve_bus_terminal_token("39756.2")
    @test !FF.should_preserve_bus_terminal_token("1.5")
    @test !FF.should_preserve_bus_terminal_token("0.001")
    @test !FF.should_preserve_bus_terminal_token("sourcebus")
end

@testset "parse_atom preserves bus-terminal tokens" begin
    @test FF.parse_atom("05410") == "05410"
    @test FF.parse_atom("1160483.2") == "1160483.2"
    @test FF.parse_atom("63683.1.3") == "63683.1.3"
    @test FF.parse_atom("1.5") === 1.5
    @test FF.parse_atom("0.001") === 0.001
end

@testset "parse_bus_terminal integer bus names from float tokens" begin
    term = FF.parse_bus_terminal(633.0; nphases = 3)
    @test term.bus == "633"
    @test term.phases == [1, 2, 3]
end

@testset "parse_bus_terminal numeric and mixed bus ids" begin
    term = FF.parse_bus_terminal("1160483.2"; nphases = 1, preserve_order = true)
    @test term.bus == "1160483"
    @test term.phases == [2]

    term = FF.parse_bus_terminal("63683.1.3"; nphases = 2, preserve_order = true)
    @test term.bus == "63683"
    @test term.phases == [1, 3]

    term = FF.parse_bus_terminal("39756.2"; nphases = 1)
    @test term.bus == "39756"
    @test term.phases == [2]

    term = FF.parse_bus_terminal("X_1144260.2"; nphases = 1)
    @test term.bus == "x_1144260"
    @test term.phases == [2]
end

@testset "parse_bus_terminal rejects scientific-notation floats" begin
    @test_throws ArgumentError FF.parse_bus_terminal(1.1604832e6; nphases = 1)
end

@testset "parse_file - numeric seven-digit bus terminals" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=115 bus1=sourcebus pu=1.0",
            "New line.l1 phases=1 bus1=1160483.2 bus2=1160484.1 r1=1 x1=1 length=1",
        ], "\n"))
        network = parse_file(f)
        @test length(network.lines) == 1
        line = network.lines["l1"]
        @test line.from.bus == "1160483"
        @test line.from.phases == [2]
        @test line.to.bus == "1160484"
        # parse_line applies the from-terminal phase list to both ends when nonempty
        @test line.to.phases == [2]
    end
end

@testset "parse_file - transformer buses tuple with numeric bus id" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=115 bus1=sourcebus pu=1.0",
            "New transformer.tx phases=1 windings=2 buses=(sourcebus 1160483.2) conns=(wye wye) kvs=(115 12.47) kvas=(1000 1000) xhl=1",
            "New line.tie phases=1 bus1=1160483.2 bus2=1160484.1 r1=1 x1=1 length=1",
        ], "\n"))
        network = parse_file(f)
        tx = network.transformers["tx"]
        @test tx.windings[2].bus.bus == "1160483"
        @test tx.windings[2].bus.phases == [2]
    end
end

# ── parse_file error paths ────────────────────────────────────────────────────

@testset "parse_file - unsupported command error carries line number" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "UnknownCommand line.l1",
        ], "\n"))
        err = try
            parse_file(f)
            nothing
        catch e
            e
        end
        @test err isa DSSParseError
        @test err.line == 2
        @test occursin("Unsupported", err.message)
    end
end

@testset "parse_file - edit non-existent object raises DSSParseError" begin
    mktempdir() do dir
        f = joinpath(dir, "test.dss")
        write(f, join([
            "New object=circuit.test basekv=4.16 bus1=sourcebus pu=1.0",
            "Edit line.ghost length=5",
        ], "\n"))
        err = try
            parse_file(f)
            nothing
        catch e
            e
        end
        @test err isa DSSParseError
        @test occursin("ghost", err.object)
    end
end
