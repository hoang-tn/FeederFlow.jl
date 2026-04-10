using FeederFlow
using JSON3

const PACKAGE_ROOT = normpath(joinpath(@__DIR__, ".."))
const REPO_ROOT = normpath(joinpath(PACKAGE_ROOT, ".."))
const FIXTURE_ROOT = joinpath(PACKAGE_ROOT, "test", "fixtures")
const MATLAB_EXE = get(ENV, "MATLAB_EXE", raw"C:\Program Files\MATLAB\R2024b\bin\matlab.exe")

function feeder_paths()
    Dict(
        "ieee37" => joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 37-bus feeder", "IEEE37openDSSdata", "ieee37opendss.dss"),
        "ieee123" => joinpath(REPO_ROOT, "three-phase-modeling", "IEEE 123-bus feeder", "IEEE123openDSSdata", "IEEE123Master.dss"),
    )
end

function write_json(path::AbstractString, value)
    open(path, "w") do io
        JSON3.pretty(io, value)
    end
end

function regulator_fixture(network::NetworkModel)
    regulators = Dict{String,Any}()
    for reg in sort(network.regulators, by = x -> x.name)
        regulators[reg.name] = Dict(
            "windings" => [
                Dict(
                    "bus" => winding.bus.bus,
                    "phases" => collect(winding.bus.phases),
                    "tap" => winding.tap,
                ) for winding in reg.windings
            ],
            "control" => isnothing(reg.regcontrol) ? nothing : Dict(
                "transformer" => reg.regcontrol.transformer,
                "winding" => reg.regcontrol.winding,
                "vreg" => reg.regcontrol.vreg,
                "band" => reg.regcontrol.band,
                "ptratio" => reg.regcontrol.ptratio,
                "ctprim" => reg.regcontrol.ctprim,
                "r" => reg.regcontrol.r,
                "x" => reg.regcontrol.x,
            ),
        )
    end
    regulators
end

function parser_fixture(network::NetworkModel)
    load_model_counts = Dict{String,Int}()
    load_conn_counts = Dict{String,Int}()
    for load in network.loads
        load_model_counts[string(load.model)] = get(load_model_counts, string(load.model), 0) + 1
        load_conn_counts[String(load.conn)] = get(load_conn_counts, String(load.conn), 0) + 1
    end
    Dict(
        "slack_bus" => network.slack_bus,
        "counts" => Dict(
            "buses" => length(network.buses),
            "lines" => length(network.lines),
            "transformers" => length(network.transformers),
            "regulators" => length(network.regulators),
            "capacitors" => length(network.capacitors),
            "loads" => length(network.loads),
            "linecodes" => length(network.linecodes),
        ),
        "base" => Dict(
            "Sbase" => network.base.Sbase,
            "Vbase" => network.base.Vbase,
            "Zbase" => network.base.Zbase,
            "Ybase" => network.base.Ybase,
        ),
        "bus_names" => [bus.name for bus in network.buses],
        "phases_by_bus" => Dict(bus.name => collect(bus.phases) for bus in network.buses),
        "regulator_names" => sort([reg.name for reg in network.regulators]),
        "regulators" => regulator_fixture(network),
        "capacitor_names" => sort([cap.name for cap in network.capacitors]),
        "load_model_counts" => load_model_counts,
        "load_conn_counts" => load_conn_counts,
    )
end

function run_matlab_export(feeder::AbstractString, output_path::AbstractString)
    script_dir = replace(joinpath(PACKAGE_ROOT, "scripts"), "\\" => "/")
    repo_root = replace(REPO_ROOT, "\\" => "/")
    output_norm = replace(output_path, "\\" => "/")
    expression = "addpath('$script_dir'); matlab_export_reference('$repo_root','$feeder','$output_norm');"
    run(Cmd([MATLAB_EXE, "-batch", expression]))
end

function main()
    isdir(FIXTURE_ROOT) || mkpath(FIXTURE_ROOT)
    for (feeder, dss_path) in feeder_paths()
        network = parse_file(dss_path)
        write_json(joinpath(FIXTURE_ROOT, "$(feeder)_parser_expected.json"), parser_fixture(network))
        run_matlab_export(feeder, joinpath(FIXTURE_ROOT, "$(feeder)_matlab_reference.json"))
    end
end

main()
