using FeederFlow
using LinearAlgebra
using Printf

REPO_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
IEEE37_DSS = joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 37-bus feeder", "IEEE37openDSSdata", "ieee37opendss.dss")
IEEE123_DSS = joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 123-bus feeder", "IEEE123openDSSdata", "IEEE123Master.dss")

function analyze_network(dss_path; label="")
    network = FeederFlow.parse_file(dss_path)
    ybase = network.base.Ybase
    println("=" ^ 80)
    println("FeederFlow line admittance: $label")
    println("ybase = $ybase S")
    println()

    println(@sprintf "%-12s %8s %-6s %20s %18s %10s" "Line" "Length" "Units" "Yseries[1,1]" "Yshunt[1,1]" "|Z|_ohm")
    println("-" ^ 90)

    errors = 0
    for line in network.lines
        z = complex.(line.rmatrix, line.xmatrix) * line.length
        yseries = inv(z) / ybase
        yshunt = zeros(ComplexF64, size(z))
        if !all(iszero, line.cmatrix)
            yshunt = (im * 2pi * line.basefreq * (line.cmatrix * 1e-9) * line.length) / ybase
        end

        # Validate: Real part of series admittance should be positive (positive resistance)
        if real(yseries[1,1]) <= 0
            println("  ERROR: Line $(line.name) has non-positive real series admittance: $(yseries[1,1])")
            errors += 1
        end

        zmag = abs(z[1,1])
        yser_str = @sprintf "%.6f%+.6fi" real(yseries[1,1]) imag(yseries[1,1])
        ysh_str = @sprintf "%.6e%+.6ei" real(yshunt[1,1]) imag(yshunt[1,1])
        
        println(@sprintf "%-12s %8.3f %-6s %20s %18s %10.4f" line.name line.length line.units yser_str ysh_str zmag)
    end

    println("-" ^ 90)
    println("Lines: $(length(network.lines)), Errors: $errors")
    println()
    
    # Print linecode summary
    println("Linecode parameters:")
    for (lc_name, lc) in pairs(network.linecodes)
        r11 = lc.rmatrix[1,1]
        x11 = lc.xmatrix[1,1]
        c11 = lc.cmatrix[1,1]
        println(@sprintf "  %-20s units=%-6s R11=%.6f X11=%.6f C11=%.4f nF  f=%.1f" 
                lc_name lc.units r11 x11 c11 lc.basefreq)
    end
    println()
    return errors
end

total_errors = 0
total_errors += analyze_network(IEEE37_DSS; label="IEEE 37-bus")
total_errors += analyze_network(IEEE123_DSS; label="IEEE 123-bus")

println("=" ^ 80)
if total_errors == 0
    println("ALL ADMITTANCE VALIDATIONS PASSED")
else
    println("VALIDATION FAILED: $total_errors errors found")
end

