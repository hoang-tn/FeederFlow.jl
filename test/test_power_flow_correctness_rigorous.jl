using Test
using FeederFlow

isdefined(@__MODULE__, :IEEE13_DSS) || include("test_support.jl")
isdefined(@__MODULE__, :dss_clear_compile!) || include("test_opendss_helpers.jl")

const POWER_FLOW_VOLTAGE_TOLERANCE = 1e-2
const IEEE13_MAX_VOLTAGE_TOLERANCE = 1e-2
const IEEE13_MAX_MAGNITUDE_TOLERANCE = 1e-2
const IEEE123_ALLOWED_MISSING_EXPECTED_KEYS = Set([
    "300_open.1",
    "300_open.2",
    "300_open.3",
    "94_open.1",
])

function assert_voltage_map_keys(actual::Dict{String,ComplexF64}, expected::Dict{String,ComplexF64}; label::AbstractString, allowed_missing_expected::Set{String} = Set{String}())
    shared_keys = Set(intersect(keys(actual), keys(expected)))
    missing_expected = Set{String}(setdiff(keys(expected), keys(actual)))
    extra_actual = Set{String}(setdiff(keys(actual), keys(expected)))
    unexpected_missing = setdiff(missing_expected, allowed_missing_expected)

    @test !isempty(shared_keys)
    @test isempty(unexpected_missing)
    @test isempty(extra_actual)
    @test isempty(setdiff(allowed_missing_expected, missing_expected))
    @test length(shared_keys) == length(keys(actual))
    @test all(isfinite(actual[key]) for key in shared_keys)
    @test all(isfinite(expected[key]) for key in shared_keys)

    @info(
        "$label coverage",
        shared_keys = length(shared_keys),
        actual_keys = length(keys(actual)),
        expected_keys = length(keys(expected)),
        missing_expected = length(missing_expected),
        extra_actual = length(extra_actual),
    )
end

function voltage_error_stats(actual::Dict{String,ComplexF64}, expected::Dict{String,ComplexF64})
    shared = intersect(keys(actual), keys(expected))
    isempty(shared) && return (; max = Inf, mean = Inf, max_magnitude = Inf, worst_key = "")

    max_error = -Inf
    max_magnitude = -Inf
    worst_key = ""
    sum_error = 0.0

    for key in shared
        a = actual[key]
        e = expected[key]
        phasor_error = abs(a - e)
        magnitude_error = abs(abs(a) - abs(e))

        sum_error += phasor_error
        if phasor_error > max_error
            max_error = phasor_error
            worst_key = key
        end
        max_magnitude = max(max_magnitude, magnitude_error)
    end

    return (
        max = max_error,
        mean = sum_error / length(shared),
        max_magnitude = max_magnitude,
        worst_key = worst_key,
    )
end

function assert_voltage_error_bounds(actual::Dict{String,ComplexF64}, expected::Dict{String,ComplexF64}; label::AbstractString, max_tol::Float64, mean_tol::Float64)
    stats = voltage_error_stats(actual, expected)
    @info(
        "$label mismatch",
        max = stats.max,
        mean = stats.mean,
        max_magnitude = stats.max_magnitude,
        worst_key = stats.worst_key,
    )
    @test stats.max < max_tol
    @test stats.mean < mean_tol
    return stats
end

function max_voltage_magnitude_diff(actual::Dict{String,ComplexF64}, expected::Dict{String,ComplexF64})
    shared = intersect(keys(actual), keys(expected))
    isempty(shared) && return Inf
    maximum(abs(abs(actual[key]) - abs(expected[key])) for key in shared)
end

function normalize_voltage_map_by_key(voltages::Dict{String,ComplexF64}, reference_key::AbstractString)
    haskey(voltages, reference_key) || return copy(voltages)
    reference = voltages[reference_key]
    abs(reference) > eps(Float64) || return copy(voltages)
    Dict(key => value / reference for (key, value) in voltages)
end

function line_to_line_voltage_map(phase_to_ground::Dict{String,ComplexF64})
    grouped = Dict{String,Dict{Int,ComplexF64}}()
    for (key, voltage) in phase_to_ground
        parts = split(key, '.')
        length(parts) == 2 || continue
        bus = parts[1]
        phase = tryparse(Int, parts[2])
        phase === nothing && continue
        grouped_bus = get!(grouped, bus, Dict{Int,ComplexF64}())
        grouped_bus[phase] = voltage
    end

    line_to_line = Dict{String,ComplexF64}()
    for (bus, phases) in grouped
        (haskey(phases, 1) && haskey(phases, 2) && haskey(phases, 3)) || continue
        line_to_line["$bus.12"] = phases[1] - phases[2]
        line_to_line["$bus.23"] = phases[2] - phases[3]
        line_to_line["$bus.31"] = phases[3] - phases[1]
    end
    line_to_line
end

function parse_opendss_voltages_live_raw(path::AbstractString, network::FeederFlow.NetworkModel)
    quoted = replace(normpath(path), "\\" => "/")
    OpenDSSDirect.dss("clear")
    OpenDSSDirect.dss("compile \"$quoted\"")
    OpenDSSDirect.dss("set controlmode=off")

    # Match OpenDSS regulator taps to the parsed fixed-tap network state.
    for regulator in network.regulators
        for winding in regulator.windings
            OpenDSSDirect.dss("transformer.$(lowercase(regulator.name)).wdg=$(winding.index) tap=$(winding.tap)")
        end
    end

    OpenDSSDirect.Solution.Solve()
    voltages = Dict{String,ComplexF64}()
    names = String.(OpenDSSDirect.Circuit.AllNodeNames())
    values = OpenDSSDirect.Circuit.AllBusVolts()
    @test length(names) == length(values)

    for (name, value) in zip(names, values)
        parts = split(lowercase(strip(name)), '.')
        length(parts) == 2 || continue
        bus = String(parts[1])
        phase = tryparse(Int, parts[2])
        phase === nothing && continue
        phase == 0 && continue
        voltages[busphase_key(bus, phase)] = ComplexF64(value)
    end
    voltages
end

function raw_to_system_pu(raw_voltages::Dict{String,ComplexF64}, network::FeederFlow.NetworkModel)
    Dict(key => value / network.base.Vbase for (key, value) in raw_voltages)
end

@testset "Power flow correctness rigorous - IEEE37 (general)" begin
    network = FeederFlow.parse_file(IEEE37_DSS)
    bundle = FeederFlow.solve_power_flow(network; max_iter = 10, tol = 1e-5)

    @test bundle.result.converged

    normalized = FeederFlow.get_normalized_result(bundle)
    @test normalized.phase_voltages == bundle.result.phase_voltages

    dss_raw = parse_opendss_voltages_live_raw(IEEE37_DSS, network)
    dss_system = raw_to_system_pu(dss_raw, network)
    actual_system = actual_voltage_map(bundle.result.phase_voltages)

    @test haskey(actual_system, "799r.1")
    @test haskey(actual_system, "799r.2")
    @test haskey(actual_system, "799r.3")

    actual_system_ll = line_to_line_voltage_map(actual_system)
    dss_system_ll = line_to_line_voltage_map(dss_system)
    assert_voltage_map_keys(actual_system_ll, dss_system_ll; label = "IEEE37 system-base line-line PU")

    actual_system_ll_ref = normalize_voltage_map_by_key(actual_system_ll, "sourcebus.12")
    dss_system_ll_ref = normalize_voltage_map_by_key(dss_system_ll, "sourcebus.12")

    @test max_voltage_magnitude_diff(actual_system_ll_ref, dss_system_ll_ref) < POWER_FLOW_VOLTAGE_TOLERANCE
    assert_voltage_error_bounds(
        actual_system_ll_ref,
        dss_system_ll_ref;
        label = "IEEE37 system-base line-line PU",
        max_tol = POWER_FLOW_VOLTAGE_TOLERANCE,
        mean_tol = POWER_FLOW_VOLTAGE_TOLERANCE,
    )

    @test !isempty(bundle.result.history)
    @test bundle.result.iterations == length(bundle.result.history)
    @test all(isfinite, bundle.result.history)
end

@testset "Power flow correctness rigorous - IEEE123 (general)" begin
    network = FeederFlow.parse_file(IEEE123_DSS)
    bundle = FeederFlow.solve_power_flow(network; max_iter = 10, tol = 1e-5)

    @test bundle.result.converged

    dss_raw = parse_opendss_voltages_live_raw(IEEE123_DSS, network)

    normalized = FeederFlow.get_normalized_result(bundle)
    @test normalized.phase_voltages == bundle.result.phase_voltages

    actual_system = actual_voltage_map(bundle.result.phase_voltages)
    dss_system = raw_to_system_pu(dss_raw, network)
    assert_voltage_map_keys(
        actual_system,
        dss_system;
        label = "IEEE123 system-base PU",
        allowed_missing_expected = IEEE123_ALLOWED_MISSING_EXPECTED_KEYS,
    )

    for key in ("150r.1", "150r.2", "150r.3", "9r.1", "25r.1", "25r.3", "160r.1", "160r.2", "160r.3")
        @test haskey(actual_system, key)
    end

    assert_voltage_error_bounds(
        actual_system,
        dss_system;
        label = "IEEE123 system-base PU",
        max_tol = POWER_FLOW_VOLTAGE_TOLERANCE,
        mean_tol = POWER_FLOW_VOLTAGE_TOLERANCE,
    )
    @test isapprox(actual_system["150r.1"], dss_system["150r.1"]; atol = POWER_FLOW_VOLTAGE_TOLERANCE)

    @test all(isfinite, values(actual_system))
    @test !isempty(bundle.result.history)
    @test bundle.result.iterations == length(bundle.result.history)
    @test all(isfinite, bundle.result.history)
end

@testset "Power flow correctness rigorous - IEEE13 (general)" begin
    network = FeederFlow.parse_file(IEEE13_DSS)
    bundle = FeederFlow.solve_power_flow(network; max_iter = 50, tol = 1e-5)

    @test bundle.result.converged
    @test haskey(bundle.result.phase_voltages, BusPhase("rg60", 1))
    @test haskey(bundle.result.phase_voltages, BusPhase("rg60", 2))
    @test haskey(bundle.result.phase_voltages, BusPhase("rg60", 3))

    dss_raw = parse_opendss_voltages_live_raw(IEEE13_DSS, network)

    normalized = FeederFlow.get_normalized_result(bundle)
    @test normalized.phase_voltages == bundle.result.phase_voltages

    actual_system = actual_voltage_map(bundle.result.phase_voltages)
    dss_system = raw_to_system_pu(dss_raw, network)
    assert_voltage_map_keys(actual_system, dss_system; label = "IEEE13 system-base PU")

    system_stats = assert_voltage_error_bounds(
        actual_system,
        dss_system;
        label = "IEEE13 system-base PU",
        max_tol = IEEE13_MAX_VOLTAGE_TOLERANCE,
        mean_tol = POWER_FLOW_VOLTAGE_TOLERANCE,
    )
    max_mag_diff = max_voltage_magnitude_diff(actual_system, dss_system)
    @info("IEEE13 max voltage magnitude mismatch",
        max_voltage_magnitude_diff = max_mag_diff,
        worst_key = system_stats.worst_key,
        max_phasor_error = system_stats.max,
        tolerance = IEEE13_MAX_VOLTAGE_TOLERANCE,
    )
    @test max_mag_diff < IEEE13_MAX_VOLTAGE_TOLERANCE
    @test system_stats.max_magnitude < IEEE13_MAX_MAGNITUDE_TOLERANCE

    @test haskey(actual_system, "650.1")
    @test haskey(actual_system, "650.2")
    @test haskey(actual_system, "650.3")
    @test isapprox(actual_system["650.1"], dss_system["650.1"]; atol = POWER_FLOW_VOLTAGE_TOLERANCE)

    @test all(isfinite, values(bundle.result.phase_voltages))

    @test isapprox(bundle.network.regulators["reg1"].windings[2].tap, 1.0; atol = 1e-12)
    @test isapprox(bundle.network.regulators["reg2"].windings[2].tap, 1.0; atol = 1e-12)
    @test isapprox(bundle.network.regulators["reg3"].windings[2].tap, 1.0; atol = 1e-12)

    @test !isempty(bundle.result.history)
    @test bundle.result.iterations == length(bundle.result.history)
    @test all(isfinite, bundle.result.history)
end
