using FeederFlow
using LinearAlgebra
using Printf

IEEE37_DSS = joinpath(pwd(), "three-phase-modeling", "IEEE 37-bus feeder", "IEEE37openDSSdata", "ieee37opendss.dss")

network = FeederFlow.parse_file(IEEE37_DSS)

println("=" ^ 120)
println("LINE ADMITTANCE COMPARISON: FeederFlow.jl vs DSS Reference")
println("File: IEEE 37-bus feeder")
println("=" ^ 120)

# DSS linecode reference values from IEEELineCodes.DSS (lower triangular)
linecode_ref = Dict{String, Any}(
    "721" => (3, [0.055416667, 0.012746212, 0.050113636, 0.006382576, 0.012746212, 0.055416667],
                 [0.037367424, -0.006969697, 0.035984848, -0.007897727, -0.006969697, 0.037367424],
                 [80.27484728, 0.0, 80.27484728, 0.0, 0.0, 80.27484728]),
    "722" => (3, [0.089981061, 0.030852273, 0.085, 0.023371212, 0.030852273, 0.089981061],
                 [0.056306818, -0.006174242, 0.050719697, -0.011496212, -0.006174242, 0.056306818],
                 [64.2184109, 0.0, 64.2184109, 0.0, 0.0, 64.2184109]),
    "723" => (3, [0.245, 0.092253788, 0.246628788, 0.086837121, 0.092253788, 0.245],
                 [0.127140152, 0.039981061, 0.119810606, 0.028806818, 0.039981061, 0.127140152],
                 [37.5977112, 0.0, 37.5977112, 0.0, 0.0, 37.5977112]),
    "724" => (3, [0.396818182, 0.098560606, 0.399015152, 0.093295455, 0.098560606, 0.396818182],
                 [0.146931818, 0.051856061, 0.140113636, 0.040208333, 0.051856061, 0.146931818],
                 [30.26701029, 0.0, 30.26701029, 0.0, 0.0, 30.26701029]),
)

line_ref = Dict{String, Any}(
    "l1" => ("722", 0.96), "l2" => ("724", 0.4), "l3" => ("723", 0.36),
    "l4" => ("722", 1.32), "l5" => ("724", 0.24), "l6" => ("723", 0.6),
    "l7" => ("724", 0.08), "l8" => ("723", 0.8), "l9" => ("724", 0.32),
    "l10" => ("724", 0.24), "l11" => ("724", 0.28), "l12" => ("724", 0.76),
    "l13" => ("724", 0.12), "l14" => ("723", 0.32), "l15" => ("724", 0.32),
    "l16" => ("723", 0.6), "l17" => ("723", 0.32), "l18" => ("724", 0.2),
    "l19" => ("724", 1.28), "l20" => ("723", 0.4), "l21" => ("724", 0.2),
    "l22" => ("723", 0.52), "l23" => ("724", 0.52), "l24" => ("724", 0.92),
    "l25" => ("723", 0.6), "l26" => ("723", 0.28), "l27" => ("723", 0.2),
    "l28" => ("723", 0.56), "l29" => ("723", 0.64), "l30" => ("724", 0.52),
    "l31" => ("723", 0.4), "l32" => ("723", 0.4), "l33" => ("724", 0.2),
    "l34" => ("724", 0.28), "l35" => ("721", 1.85),
)

function lower_tri_to_matrix(vals)
    n = Int((-1 + sqrt(1 + 8 * length(vals))) / 2)
    m = zeros(Float64, n, n)
    idx = 1
    for j in 1:n
        for i in j:n
            m[i, j] = vals[idx]
            m[j, i] = vals[idx]
            idx += 1
        end
    end
    return m
end

ybase = network.base.Ybase
basefreq = 60.0

max_rel_err = 0.0
max_rel_err_line = ""
mismatch_count = 0
total = 0

println()
@printf "%-12s %12s %12s %35s %35s %12s\n" "Line" "FF Z11" "Ref Z11" "FF Yself[1,1]" "Ref Yself[1,1]" "Rel.Err"
println("-" ^ 120)

for line in network.lines
    line.name == "jumper" && continue

    lc_name_len = get(line_ref, line.name, nothing)
    if lc_name_len === nothing
        println(@sprintf "%-12s NOT FOUND in DSS reference" line.name)
        continue
    end

    lc_name, len = lc_name_len
    lc = linecode_ref[lc_name]
    nph, r_vals, x_vals, c_vals = lc
    rmat = lower_tri_to_matrix(r_vals)
    xmat = lower_tri_to_matrix(x_vals)
    cmat = lower_tri_to_matrix(c_vals)

    z_ref = complex.(rmat, xmat) * len
    yseries_ref = inv(z_ref) / ybase
    yshunt_ref = (im * 2pi * basefreq * (cmat * 1e-9) * len) / ybase
    yself_ref = yseries_ref + 0.5 .* yshunt_ref

    z_ff = complex.(line.rmatrix, line.xmatrix) * line.length
    yseries_ff = inv(z_ff) / ybase
    if !all(iszero, line.cmatrix)
        yshunt_ff = (im * 2pi * line.basefreq * (line.cmatrix * 1e-9) * line.length) / ybase
    else
        yshunt_ff = zeros(ComplexF64, size(z_ff))
    end
    yself_ff = yseries_ff + 0.5 .* yshunt_ff

    global total += 1

    if abs(yself_ref[1,1]) > 1e-15
        rel_err = abs(yself_ff[1,1] - yself_ref[1,1]) / abs(yself_ref[1,1])
    else
        rel_err = abs(yself_ff[1,1] - yself_ref[1,1])
    end

    if rel_err > max_rel_err
        global max_rel_err = rel_err
        global max_rel_err_line = line.name
    end

    if rel_err > 1e-10
        global mismatch_count += 1
    end

    ff_str = @sprintf("%.8f%+.8fi", real(yself_ff[1,1]), imag(yself_ff[1,1]))
    ref_str = @sprintf("%.8f%+.8fi", real(yself_ref[1,1]), imag(yself_ref[1,1]))
    @printf "%-12s %12.6f %12.6f %35s %35s %12.2e\n" line.name real(z_ff[1,1]) real(z_ref[1,1]) ff_str ref_str rel_err
end

println("-" ^ 120)
println()
println("  Max rel error: $max_rel_err (line: $max_rel_err_line)")
println("  Lines with >1e-10 mismatch: $mismatch_count / $total")
println()

# Detailed matrix comparison
println("=" ^ 120)
println("DETAILED MATRIX COMPARISON (first 3 lines)")
println("=" ^ 120)

count = 0
for line in network.lines
    count >= 3 && break
    line.name == "jumper" && continue

    lc_name_len = get(line_ref, line.name, nothing)
    lc_name_len === nothing && continue
    lc_name, len = lc_name_len
    lc = linecode_ref[lc_name]
    nph, r_vals, x_vals, c_vals = lc
    rmat = lower_tri_to_matrix(r_vals)
    xmat = lower_tri_to_matrix(x_vals)
    cmat = lower_tri_to_matrix(c_vals)

    z_ref = complex.(rmat, xmat) * len
    z_ff = complex.(line.rmatrix, line.xmatrix) * line.length

    println()
    println("Line: $(line.name)  linecode=$lc_name  length=$len")
    println("  Z max diff: $(maximum(abs.(z_ff .- z_ref)))")
    println("  Z FF:")
    for i in 1:size(z_ff, 1)
        print("    [")
        for j in 1:size(z_ff, 2)
            print(@sprintf("%.8f%+.8fi ", real(z_ff[i,j]), imag(z_ff[i,j])))
        end
        println("]")
    end
    println("  Z Ref:")
    for i in 1:size(z_ref, 1)
        print("    [")
        for j in 1:size(z_ref, 2)
            print(@sprintf("%.8f%+.8fi ", real(z_ref[i,j]), imag(z_ref[i,j])))
        end
        println("]")
    end

    # Also compare full admittance
    yseries_ref = inv(z_ref) / ybase
    yshunt_ref = (im * 2pi * basefreq * (cmat * 1e-9) * len) / ybase
    yself_ref = yseries_ref + 0.5 .* yshunt_ref

    yseries_ff = inv(z_ff) / ybase
    if !all(iszero, line.cmatrix)
        yshunt_ff = (im * 2pi * line.basefreq * (line.cmatrix * 1e-9) * line.length) / ybase
    else
        yshunt_ff = zeros(ComplexF64, size(z_ff))
    end
    yself_ff = yseries_ff + 0.5 .* yshunt_ff

    println("  Yself FF:")
    for i in 1:size(yself_ff, 1)
        print("    [")
        for j in 1:size(yself_ff, 2)
            print(@sprintf("%.8f%+.8fi ", real(yself_ff[i,j]), imag(yself_ff[i,j])))
        end
        println("]")
    end
    println("  Yself Ref:")
    for i in 1:size(yself_ref, 1)
        print("    [")
        for j in 1:size(yself_ref, 2)
            print(@sprintf("%.8f%+.8fi ", real(yself_ref[i,j]), imag(yself_ref[i,j])))
        end
        println("]")
    end

    global count += 1
end
