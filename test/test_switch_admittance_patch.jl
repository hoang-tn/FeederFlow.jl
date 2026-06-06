using Test
using FeederFlow
using LinearAlgebra

const SWITCH_PATCH_TOL = 1e-8

switch_patch_tol(label::AbstractString) = label == "IEEE240" ? 2e-7 : SWITCH_PATCH_TOL

benchmark_cases() = [
    ("IEEE13", IEEE13_DSS),
    ("IEEE123", IEEE123_DSS),
    ("IEEE240", IEEE240_DSS),
    ("IEEE906", IEEE906_DSS),
]

switch_line_names(network::FeederFlow.NetworkModel) = [line.name for line in network.lines if line.is_switch]

function patchable_line_names(network::FeederFlow.NetworkModel; limit::Int = 4)
    names = String[]
    for line in network.lines
           FeederFlow.switch_line_admittance(network, line) === nothing && continue
        push!(names, line.name)
        length(names) >= limit && break
    end
    return names
end

function prepare_switch_case(network::FeederFlow.NetworkModel; limit::Int = 4)
    names = switch_line_names(network)
    if isempty(names)
        names = patchable_line_names(network; limit = limit)
        isempty(names) && error("No patchable lines found for synthetic switch test")
        promoted = deepcopy(network)
        for name in names
            line = promoted.lines[name]
            line.is_switch = true
            line.is_closed_base = true
            line.is_closed = true
        end
        network = promoted
    end
        ybus = FeederFlow.build_y(network; regulator_model = :nonideal, epsilon = 1e-5)
    scales = v_scale_full(ybus, network)
        Y_scaled_base = FeederFlow.scaled_ybus_matrix(ybus, scales)
    return network, ybus, scales, Y_scaled_base, names
end

function switch_batches(names::AbstractVector{<:AbstractString}; limit::Int = 4)
    upper = min(length(names), limit)
    return [String.(names[1:count]) for count in 1:upper]
end

@testset "Switch admittance patch" begin
    for (label, path) in benchmark_cases()
        @testset "$label batched switch toggles" begin
            network = FeederFlow.parse_file(path)
            network, ybus, scales, Y_scaled_base, names = prepare_switch_case(network)
            tol = switch_patch_tol(label)

            @test !isempty(names)
            for batch_names in switch_batches(names; limit = 4)
                result = FeederFlow.compare_switch_patch_to_rebuild(
                    network,
                    ybus,
                    Y_scaled_base,
                    batch_names,
                    scales;
                    regulator_model = :nonideal,
                    epsilon = 1e-5,
                )
                @test result.max_diff <= tol
            end
        end

        @testset "$label cumulative switch updates" begin
            network = FeederFlow.parse_file(path)
            network, ybus, scales, Y_scaled_base, names = prepare_switch_case(network)
            tol = switch_patch_tol(label)

            @test !isempty(names)

            patch_network = deepcopy(network)
            rebuild_network = deepcopy(network)
            for batch_names in switch_batches(names; limit = 4)
                for line_name in batch_names
                    patch_network.lines[line_name].is_closed = !patch_network.lines[line_name].is_closed_base
                    rebuild_network.lines[line_name].is_closed = !rebuild_network.lines[line_name].is_closed_base
                end

                patched = FeederFlow.patch_switch_admittance!(Y_scaled_base, patch_network, ybus, scales)

                rebuilt_ybus = FeederFlow.build_y(rebuild_network; regulator_model = :nonideal, epsilon = 1e-5)
                rebuilt = FeederFlow.scaled_ybus_matrix(rebuilt_ybus, scales)

                @test matrix_max_abs_diff(patched, rebuilt) <= tol
            end
        end

        @testset "$label legacy single-line helper" begin
            network = FeederFlow.parse_file(path)
            network, ybus, scales, Y_scaled_base, names = prepare_switch_case(network)
            tol = switch_patch_tol(label)

            @test !isempty(names)

            patch_network = deepcopy(network)
            rebuild_network = deepcopy(network)
            patched = copy(Y_scaled_base)

            line_name = first(names)
            patch_line = patch_network.lines[line_name]
            new_closed = !patch_line.is_closed

            FeederFlow.patch_switch_admittance!(patched, patch_network, ybus, patch_line, new_closed, scales)
            rebuild_network.lines[line_name].is_closed = new_closed

            rebuilt_ybus = FeederFlow.build_y(rebuild_network; regulator_model = :nonideal, epsilon = 1e-5)
            rebuilt = FeederFlow.scaled_ybus_matrix(rebuilt_ybus, scales)

            @test matrix_max_abs_diff(patched, rebuilt) <= tol
            @test patch_network.lines[line_name].is_closed == new_closed
            @test patch_network.lines[line_name].is_closed_base == network.lines[line_name].is_closed_base
        end

        @testset "$label base-state no-op" begin
            network = FeederFlow.parse_file(path)
            network, ybus, scales, Y_scaled_base, names = prepare_switch_case(network)

            @test !isempty(names)

            patch_network = deepcopy(network)
            patched = FeederFlow.patch_switch_admittance!(Y_scaled_base, patch_network, ybus, scales)

            @test matrix_max_abs_diff(patched, Y_scaled_base) == 0.0
            @test all(line.is_closed == line.is_closed_base for line in patch_network.lines if line.is_switch)
        end
    end
end
