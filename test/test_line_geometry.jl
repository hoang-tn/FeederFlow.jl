using Test
using FeederFlow
using LinearAlgebra
using SparseArrays
using OpenDSSDirect
using PowerModelsDistribution

const GEOMETRY_LINE_DSS = opendss_fixture_path("geometry_line_parity.dss")

const GEOMETRY_MATRIX_RTOL = 1e-4
const GEOMETRY_MATRIX_ATOL = 1e-3
# Geometry lines differ from OpenDSSDirect by ~1% on series R (OpenDSS vs PMD/FF constants).
const GEOMETRY_YPRIM_RTOL = 2e-2

function geometry_catalog(path::AbstractString)
    state = FeederFlow.parse_dss(path)
    wiredata = Dict{String,FeederFlow.WireData}()
    linegeometries = Dict{String,FeederFlow.LineGeometry}()
    for ((objtype, _), object) in state.objects
        if objtype == "wiredata"
            wiredata[object.name] = FeederFlow.parse_wiredata(object)
        elseif objtype == "linegeometry"
            linegeometries[object.name] = FeederFlow.parse_linegeometry(object)
        end
    end
    return wiredata, linegeometries
end

function geometry_only_lines(network::FeederFlow.NetworkModel)
    [line for line in network.lines if line.linecode_name === nothing]
end

@testset "WireData and LineGeometry parsing" begin
    wiredata, linegeometries = geometry_catalog(GEOMETRY_LINE_DSS)
    @test haskey(wiredata, "al_4/0_7str")
    @test haskey(linegeometries, "3ph_horiz_lg_1c-al_4/0_7stral_4/0_7stral_4/0_7stracsr_1/0_6/1")

    wire = wiredata["al_4/0_7str"]
    @test wire.rac > 0
    @test wire.gmrac > 0
    @test wire.capradius > 0

    geom = linegeometries["3ph_horiz_lg_1c-al_4/0_7stral_4/0_7stral_4/0_7stracsr_1/0_6/1"]
    @test geom.nconds == 4
    @test geom.nphases == 3
    @test geom.reduce
    @test geom.wires[4] == "acsr_1/0_6/1"
    @test geom.xs[1] ≈ -1.39598 atol = 1e-6
end

@testset "geometry_line_matrices vs PowerModelsDistribution" begin
    wiredata, linegeometries = geometry_catalog(GEOMETRY_LINE_DSS)
    geom = linegeometries["3ph_horiz_lg_1c-al_4/0_7stral_4/0_7stral_4/0_7stracsr_1/0_6/1"]

  # PMD engineering model stores series R/X in Ω/m; compare geometry matrices in the same basis.
    ff_r, ff_x, _ = FeederFlow.geometry_line_matrices(geom, wiredata; length_units = "m")

    pmd = PowerModelsDistribution.parse_file(GEOMETRY_LINE_DSS)
    pmd_line = pmd["line"]["geom_line"]
    pmd_r = Matrix{Float64}(pmd_line["rs"])
    pmd_x = Matrix{Float64}(pmd_line["xs"])

    @test ff_r ≈ pmd_r rtol = GEOMETRY_MATRIX_RTOL atol = GEOMETRY_MATRIX_ATOL
    @test ff_x ≈ pmd_x rtol = GEOMETRY_MATRIX_RTOL atol = GEOMETRY_MATRIX_ATOL
end

@testset "EPRI feeder geometry parse smoke tests" begin
    @test isfile(CKT5_DSS)
    @test isfile(CKT7_DSS)
    @test isfile(CKT24_DSS)

    net5 = FeederFlow.parse_file(CKT5_DSS)
    net7 = FeederFlow.parse_file(CKT7_DSS)
    net24 = FeederFlow.parse_file(CKT24_DSS)

    @test length(net5.lines) > 2000
    @test length(net7.lines) > 1000
    @test length(net24.lines) > 4000

    geom5 = geometry_only_lines(net5)
    geom24 = geometry_only_lines(net24)
    @test length(geom5) > 500
    @test length(geom24) > 200

    zero_geom = [
        line for line in geom5
        if norm(line.rmatrix) < 1e-9 && norm(line.xmatrix) < 1e-9
    ]
    @test length(zero_geom) > 0
    @test all(
        line.is_switch ||
        occursin("busbar", lowercase(line.name)) ||
        occursin("fuse", lowercase(line.name)) ||
        occursin("elb", lowercase(line.name))
        for line in zero_geom
    )

    nonzero = [line for line in geom5 if norm(line.rmatrix) > 1e-6 || norm(line.xmatrix) > 1e-6]
    @test !isempty(nonzero)
end

function parse_busphase_label(label::AbstractString)
    split_idx = findlast(==('.'), label)
    split_idx === nothing && error("Invalid bus-phase label '$label'")
    bus = label[1:split_idx - 1]
    phase = parse(Int, label[split_idx + 1:end])
    return FeederFlow.BusPhase(bus, phase)
end

indexmap_from_labels(labels::Vector{String}) = Dict(parse_busphase_label(label) => idx for (idx, label) in enumerate(labels))

@testset "geometry line OpenDSS matrix parity" begin
    dss_clear_compile!(GEOMETRY_LINE_DSS)
    dss_select_element!("line", "geom_line")
    net = FeederFlow.parse_file(GEOMETRY_LINE_DSS)
    line = net.lines["geom_line"]
    ods_r = OpenDSSDirect.Lines.RMatrix()
    ods_x = OpenDSSDirect.Lines.XMatrix()
    ods_c = OpenDSSDirect.Lines.CMatrix()
    ods_rtol = 2e-2
    ods_atol = 1e-2
    @test line.rmatrix ≈ ods_r rtol = ods_rtol atol = ods_atol
    @test line.xmatrix ≈ ods_x rtol = ods_rtol atol = ods_atol
    @test line.cmatrix ≈ ods_c rtol = ods_rtol atol = ods_atol
end

@testset "geometry line OpenDSS YPrim parity" begin
    dss_clear_compile!(GEOMETRY_LINE_DSS)
    dss_select_element!("line", "geom_line")
    net = FeederFlow.parse_file(GEOMETRY_LINE_DSS)
    line = net.lines["geom_line"]
    base = net.base
    dss = dss_active_phase_yprim_pu(base.Ybase)
    labels = vcat(
        [busphase_key(line.from.bus, phase) for phase in line.phases],
        [busphase_key(line.to.bus, phase) for phase in line.phases],
    )
    rows = Int[]
    cols = Int[]
    vals = ComplexF64[]
    FeederFlow.stamp_line!(rows, cols, vals, indexmap_from_labels(labels), line; include_shunt = true, ybase = base.Ybase)
    ff_y = Matrix(sparse(rows, cols, vals, length(labels), length(labels)))
    dss_y = reorder_square_matrix(dss.yprim, dss.labels, labels)
    rel = norm(ff_y - dss_y) / max(norm(dss_y), 1e-12)
    @test rel < GEOMETRY_YPRIM_RTOL
end
