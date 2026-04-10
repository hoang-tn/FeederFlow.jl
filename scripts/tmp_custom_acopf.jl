using JuMP
using Ipopt
using LinearAlgebra
using Printf

# 3-bus AC network in per-unit.
branches = [
    (1, 2, 0.02 + 0.06im),
    (1, 3, 0.08 + 0.24im),
    (2, 3, 0.06 + 0.18im),
]

nb = 3
Y = zeros(ComplexF64, nb, nb)
for (f, t, z) in branches
    y = 1 / z
    Y[f, f] += y
    Y[t, t] += y
    Y[f, t] -= y
    Y[t, f] -= y
end
G = real.(Y)
B = imag.(Y)

Pd = Dict(1 => 0.0, 2 => 0.90, 3 => 1.00)
Qd = Dict(1 => 0.0, 2 => 0.30, 3 => 0.35)

model = Model(Ipopt.Optimizer)
set_silent(model)

@variable(model, vr[1:nb])
@variable(model, vi[1:nb])

@variable(model, 0.0 <= Pg1 <= 5.0)
@variable(model, -5.0 <= Qg1 <= 5.0)
@variable(model, 0.0 <= Pg2 <= 2.5)
@variable(model, -2.0 <= Qg2 <= 2.0)

# Slack reference.
@constraint(model, vr[1] == 1.0)
@constraint(model, vi[1] == 0.0)

# Voltage magnitude limits on non-slack buses.
for i in 2:nb
    @constraint(model, 0.90^2 <= vr[i]^2 + vi[i]^2)
    @constraint(model, vr[i]^2 + vi[i]^2 <= 1.10^2)
end

# AC nodal power-balance equations in rectangular coordinates.
for i in 1:nb
    ir = @expression(model, sum(G[i, j] * vr[j] - B[i, j] * vi[j] for j in 1:nb))
    ii = @expression(model, sum(B[i, j] * vr[j] + G[i, j] * vi[j] for j in 1:nb))
    p_inj = @expression(model, vr[i] * ir + vi[i] * ii)
    q_inj = @expression(model, vi[i] * ir - vr[i] * ii)

    if i == 1
        @constraint(model, p_inj == Pg1 - Pd[i])
        @constraint(model, q_inj == Qg1 - Qd[i])
    elseif i == 2
        @constraint(model, p_inj == Pg2 - Pd[i])
        @constraint(model, q_inj == Qg2 - Qd[i])
    else
        @constraint(model, p_inj == -Pd[i])
        @constraint(model, q_inj == -Qd[i])
    end
end

# Quadratic generation cost.
@objective(model, Min, 5.0 * Pg1^2 + 20.0 * Pg1 + 8.0 * Pg2^2 + 10.0 * Pg2)

optimize!(model)

println("termination_status = ", termination_status(model))
println("primal_status      = ", primal_status(model))
@printf("objective          = %.8f\n", objective_value(model))
@printf("Pg1, Qg1           = %.6f, %.6f\n", value(Pg1), value(Qg1))
@printf("Pg2, Qg2           = %.6f, %.6f\n", value(Pg2), value(Qg2))

for i in 1:nb
    vm = sqrt(value(vr[i])^2 + value(vi[i])^2)
    va = atan(value(vi[i]), value(vr[i])) * 180 / pi
    @printf("bus %d: Vm=%.6f, Va=%.4f deg\n", i, vm, va)
end

# Sanity-check max nodal mismatch.
let
    max_p_mismatch = 0.0
    max_q_mismatch = 0.0
    for i in 1:nb
        vr_i = value(vr[i])
        vi_i = value(vi[i])
        ir_i = sum(G[i, j] * value(vr[j]) - B[i, j] * value(vi[j]) for j in 1:nb)
        ii_i = sum(B[i, j] * value(vr[j]) + G[i, j] * value(vi[j]) for j in 1:nb)
        p_i = vr_i * ir_i + vi_i * ii_i
        q_i = vi_i * ir_i - vr_i * ii_i

        p_rhs = i == 1 ? value(Pg1) - Pd[i] : (i == 2 ? value(Pg2) - Pd[i] : -Pd[i])
        q_rhs = i == 1 ? value(Qg1) - Qd[i] : (i == 2 ? value(Qg2) - Qd[i] : -Qd[i])

        max_p_mismatch = max(max_p_mismatch, abs(p_i - p_rhs))
        max_q_mismatch = max(max_q_mismatch, abs(q_i - q_rhs))
    end
    @printf("max |P mismatch|   = %.3e\n", max_p_mismatch)
    @printf("max |Q mismatch|   = %.3e\n", max_q_mismatch)
end
