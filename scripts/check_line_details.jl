# Create a minimal DSS file with just one line for admittance comparison
import FeederFlow
import OpenDSSDirect

REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
IEEE37_DSS = joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 37-bus feeder", "IEEE37openDSSdata", "ieee37opendss.dss")

# Get line info from FeederFlow
network = FeederFlow.parse_file(IEEE37_DSS)
ybase = network.base.Ybase

println("FeederFlow network: $(length(network.lines)) lines, $(length(network.linecodes)) linecodes")
println("ybase = $ybase S")
println()

# Print some line details
for line in network.lines[1:min(5, length(network.lines))]
    println("Line: $(line.name)")
    println("  phases=$(line.phases), length=$(line.length), units=$(line.units), basefreq=$(line.basefreq)")
    if !isnothing(line.linecode_name)
        lc = network.linecodes[line.linecode_name]
        println("  linecode=$(line.linecode_name), lc_units=$(lc.units)")
        println("  rmatrix:")
        println("    ", line.rmatrix)
        println("  xmatrix:")
        println("    ", line.xmatrix)
        println("  cmatrix:")
        println("    ", line.cmatrix)
    end

    z = complex.(line.rmatrix, line.xmatrix) * line.length
    yseries = inv(z) / ybase
    yshunt = zeros(ComplexF64, size(z))
    if !all(iszero, line.cmatrix)
        yshunt = (im * 2pi * line.basefreq * (line.cmatrix * 1e-9) * line.length) / ybase
    end

    yself = yseries + 0.5 .* yshunt
    ymutual = -yseries

    println("  yseries[1,1] = $(yseries[1,1])")
    println("  ymutual[1,1] = $(ymutual[1,1])")
    println("  yshunt[1,1]  = $(yshunt[1,1])")
    println("  yself[1,1]   = $(yself[1,1])")
    println()
end

