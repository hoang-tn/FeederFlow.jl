# Minimal test: just create a circuit and check OpenDSSDirect works
using OpenDSSDirect
using LinearAlgebra
using Printf

# Create test DSS file
dss_content = """
New Circuit.Test basekv=4.16 pu=1.0 Isc3=1000 Isc1=800
New Linecode.test1 phases=3 normamps=300 emergamps=400 units=none
  R1=0.4 X1=0.15 R0=0.4 X0=0.15 C1=20 C0=20 basefreq=60
New Line.test phases=3 bus1=src.1.2.3 bus2=load.1.2.3 LineCode=test1 Length=1.0
"""

test_dss = tempname() * ".dss"
open(test_dss, "w") do f
    write(f, dss_content)
end

normal_path = replace(test_dss, "\\" => "/")
println("Test file: $normal_path")

# Use compile command properly
OpenDSSDirect.dss("""
    clear
    compile "$normal_path"
""")

println("Circuit compiled successfully")

# Get line parameters
OpenDSSDirect.Lines.Name("Line.test")
r1 = OpenDSSDirect.Lines.R1()
x1 = OpenDSSDirect.Lines.X1()
r0 = OpenDSSDirect.Lines.R0()
x0 = OpenDSSDirect.Lines.X0()
c1 = OpenDSSDirect.Lines.C1()
c0 = OpenDSSDirect.Lines.C0()
length_val = OpenDSSDirect.Lines.Length()
units = OpenDSSDirect.Lines.Units()
basefreq = OpenDSSDirect.CktElement.BaseFreq()

println("Line params from OpenDSS: R1=$r1 X1=$x1 R0=$r0 X0=$x0 C1=$c1 C0=$c0 Length=$length_val Units=$units BaseFreq=$basefreq")

# Get system Y matrix
nodes = OpenDSSDirect.Circuit.AllNodeNames()
Y_flat = OpenDSSDirect.Circuit.SystemY()
N = length(nodes)

println("\nNode order: $nodes")
println("SystemY size: $(length(Y_flat)) elements")

Y_matrix = reshape(Y_flat[1:N*N], N, N)

# Build expected Y matrix manually
# For balanced line: z_self=(z0+2*z1)/3, z_mutual=(z0-z1)/3
z1_total = ComplexF64(r1, x1) * length_val
z0_total = ComplexF64(r0, x0) * length_val
z_self = (z0_total + 2*z1_total) / 3
z_mutual = (z0_total - z1_total) / 3

Z = [z_self z_mutual z_mutual; z_mutual z_self z_mutual; z_mutual z_mutual z_self]
Yseries = inv(Z)

c1_eff = c1 * 1e-9 * length_val
c0_eff = c0 * 1e-9 * length_val
c_self = (c0_eff + 2*c1_eff) / 3
c_mutual = (c0_eff - c1_eff) / 3
C = [c_self c_mutual c_mutual; c_mutual c_self c_mutual; c_mutual c_mutual c_self]
Yshunt = im * 2pi * basefreq * C

Yself = Yseries + 0.5 * Yshunt
Ymutual = -Yseries

println("\nExpected Yself (per-unit-length, no base scaling):")
for i in 1:3
    for j in 1:3
        print("  Yself[$i,$j] = $(@sprintf("%+.8f", real(Yself[i,j])))$( @sprintf("%+.8fim", imag(Yself[i,j])))")
    end
    println()
end

println("\nExpected Ymutual:")
for i in 1:3
    for j in 1:3
        print("  Ymut[$i,$j] = $(@sprintf("%+.8f", real(Ymutual[i,j])))$( @sprintf("%+.8fim", imag(Ymutual[i,j])))")
    end
    println()
end

# Map to OpenDSS node indices
src_idx = [1, 2, 3]  # src.1, src.2, src.3
load_idx = [4, 5, 6]  # load.1, load.2, load.3

println("\nOpenDSS SystemY diagonal (src,src):")
for i in 1:3, j in 1:3
    odss_val = Y_matrix[src_idx[i], src_idx[j]]
    exp_val = Yself[i, j]
    if abs(exp_val) > 1e-15
        err = abs(odss_val - exp_val) / abs(exp_val)
    else
        err = abs(odss_val - exp_val)
    end
    println("  ODSS[$i,$j] = $(@sprintf("%+.8f", real(odss_val)))$(@sprintf("%+.8fim", imag(odss_val)))  vs Expected = $(@sprintf("%+.8f", real(exp_val)))$(@sprintf("%+.8fim", imag(exp_val)))  rel_err=$(err)")
end

println("\nOpenDSS SystemY off-diagonal (src,load):")
for i in 1:3, j in 1:3
    odss_val = Y_matrix[src_idx[i], load_idx[j]]
    exp_val = Ymutual[i, j]
    if abs(exp_val) > 1e-15
        err = abs(odss_val - exp_val) / abs(exp_val)
    else
        err = abs(odss_val - exp_val)
    end
    println("  ODSS[$i,$j] = $(@sprintf("%+.8f", real(odss_val)))$(@sprintf("%+.8fim", imag(odss_val)))  vs Expected = $(@sprintf("%+.8f", real(exp_val)))$(@sprintf("%+.8fim", imag(exp_val)))  rel_err=$(err)")
end

println("\nOpenDSS SystemY diagonal (load,load):")
for i in 1:3, j in 1:3
    odss_val = Y_matrix[load_idx[i], load_idx[j]]
    exp_val = Yself[i, j]
    if abs(exp_val) > 1e-15
        err = abs(odss_val - exp_val) / abs(exp_val)
    else
        err = abs(odss_val - exp_val)
    end
    println("  ODSS[$i,$j] = $(@sprintf("%+.8f", real(odss_val)))$(@sprintf("%+.8fim", imag(odss_val)))  vs Expected = $(@sprintf("%+.8f", real(exp_val)))$(@sprintf("%+.8fim", imag(exp_val)))  rel_err=$(err)")
end

rm(test_dss; force=true)
