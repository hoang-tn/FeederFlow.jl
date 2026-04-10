using JuMP
using Ipopt
using LinearAlgebra
using Printf

nb = 13
branches = [
    (1, 2, 0.010 + 0.030im, 2.0),
    (2, 3, 0.012 + 0.036im, 1.8),
    (3, 4, 0.010 + 0.030im, 1.6),
    (4, 5, 0.015 + 0.045im, 1.5),
    (5, 6, 0.012 + 0.040im, 1.3),
    (3, 7, 0.020 + 0.060im, 1.2),
    (7, 8, 0.015 + 0.050im, 1.0),
    (8, 9, 0.015 + 0.050im, 1.0),
    (2, 10, 0.020 + 0.060im, 1.2),
    (10, 11, 0.015 + 0.045im, 1.1),
    (11, 12, 0.015 + 0.045im, 1.0),
    (12, 13, 0.020 + 0.060im, 0.9),
]

Y = zeros(ComplexF64, nb, nb)
for (f, t, z, _) in branches
    y = 1 / z
    Y[f, f] += y
    Y[t, t] += y
    Y[f, t] -= y
    Y[t, f] -= y
end
G = real.(Y)
B = imag.(Y)

Pd = zeros(nb)
Qd = zeros(nb)
for (i, p, q) in [
    (2, 0.18, 0.07), (3, 0.15, 0.06), (4, 0.12, 0.05), (5, 0.10, 0.04),
    (6, 0.08, 0.03), (7, 0.13, 0.05), (8, 0.10, 0.04), (9, 0.09, 0.04),
    (10, 0.11, 0.04), (11, 0.09, 0.04), (12, 0.08, 0.03), (13, 0.07, 0.03),
]
    Pd[i] = p
    Qd[i] = q
end

model = JuMP.Model(Ipopt.Optimizer)
set_silent(model)

@variable(model, Vm[1:nb])
@variable(model, Va[1:nb])

# Substation generator (bus 1)
@variable(model, 0.0 <= Pg_sub <= 2.0)
@variable(model, -1.0 <= Qg_sub <= 1.0)
@constraint(model, Pg_sub^2 + Qg_sub^2 <= 2.2^2)

# Two downstream DERs
@variable(model, 0.0 <= Pg7 <= 0.25)
@variable(model, -0.15 <= Qg7 <= 0.15)
@variable(model, 0.0 <= Pg12 <= 0.20)
@variable(model, -0.12 <= Qg12 <= 0.12)

# Slack bus and voltage limits
@constraint(model, Vm[1] == 1.0)
@constraint(model, Va[1] == 0.0)
for i in 2:nb
    @constraint(model, 0.93 <= Vm[i] <= 1.07)
end

# Angle-difference constraints on every branch
delta_max = deg2rad(35.0)
for (f, t, _, _) in branches
    @constraint(model, -delta_max <= Va[f] - Va[t] <= delta_max)
end

# AC nodal power balance in polar form
for i in 1:nb
    p_inj = @expression(model, sum(Vm[i] * Vm[j] * (G[i, j] * cos(Va[i] - Va[j]) + B[i, j] * sin(Va[i] - Va[j])) for j in 1:nb))
    q_inj = @expression(model, sum(Vm[i] * Vm[j] * (G[i, j] * sin(Va[i] - Va[j]) - B[i, j] * cos(Va[i] - Va[j])) for j in 1:nb))

    p_gen = i == 1 ? Pg_sub : (i == 7 ? Pg7 : (i == 12 ? Pg12 : 0.0))
    q_gen = i == 1 ? Qg_sub : (i == 7 ? Qg7 : (i == 12 ? Qg12 : 0.0))

    @constraint(model, p_inj == p_gen - Pd[i])
    @constraint(model, q_inj == q_gen - Qd[i])
end

# Branch current limits: |I_ft|^2 <= Imax^2
for (f, t, z, imax) in branches
    y = 1 / z
    yabs2 = abs2(y)
    @constraint(model, yabs2 * (Vm[f]^2 + Vm[t]^2 - 2 * Vm[f] * Vm[t] * cos(Va[f] - Va[t])) <= imax^2)
end

@objective(model, Min, 25.0 * Pg_sub^2 + 5.0 * Pg_sub + 6.0 * Pg7^2 + 6.0 * Pg12^2)

# Warm start for NLP robustness
set_start_value.(Vm, 1.0)
set_start_value.(Va, 0.0)
set_start_value(Pg_sub, sum(Pd))
set_start_value(Qg_sub, sum(Qd))
set_start_value(Pg7, 0.10)
set_start_value(Qg7, 0.0)
set_start_value(Pg12, 0.08)
set_start_value(Qg12, 0.0)

optimize!(model)

println("termination_status=", termination_status(model))
println("primal_status=", primal_status(model))
@printf("objective=%.8f\n", objective_value(model))
@printf("Pg_sub,Qg_sub=%.6f, %.6f\n", value(Pg_sub), value(Qg_sub))
@printf("Pg7,Qg7=%.6f, %.6f\n", value(Pg7), value(Qg7))
@printf("Pg12,Qg12=%.6f, %.6f\n", value(Pg12), value(Qg12))

# Check key constraints numerically
let
    max_angle = 0.0
    max_curr_ratio = 0.0
    for (f, t, z, imax) in branches
        delta = abs(value(Va[f]) - value(Va[t]))
        max_angle = max(max_angle, delta)
        y = 1 / z
        I = abs(y * ((value(Vm[f]) * cis(value(Va[f]))) - (value(Vm[t]) * cis(value(Va[t])))))
        max_curr_ratio = max(max_curr_ratio, I / imax)
    end
    @printf("max |angle diff| (deg)=%.4f\n", max_angle * 180 / pi)
    @printf("max branch current usage=%.4f pu of limit\n", max_curr_ratio)
    @printf("substation apparent usage=%.4f pu of limit\n", sqrt(value(Pg_sub)^2 + value(Qg_sub)^2) / 2.2)
end
