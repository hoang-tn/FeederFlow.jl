# FeederFlow.jl

Julia package for **unbalanced multiphase distribution power flow** from OpenDSS feeders. It parses DSS masters, assembles a phase-domain Y-bus (lines, transformers, regulators, switches, shunts), models ZIP-style loads, and solves with a fixed-point Z-bus iteration.

Designed for research on larger feeders (IEEE 13/37/123/240/8500, LV test cases) with validation against OpenDSS voltages.

## Requirements

- Julia ≥ 1.12
- [OpenDSSDirect.jl](https://github.com/dss-oss/OpenDSSDirect.jl) (for validation workflows)

## Install

```julia
using Pkg
Pkg.activate("path/to/FeederFlow.jl")
Pkg.instantiate()
```

## Quick start

```julia
using FeederFlow

dss = joinpath(@__DIR__, "examples", "grids", "13_bus", "IEEE13Nodeckt.dss")
bundle = solve_case(dss; regulator_model=:nonideal, max_iter=20, tol=1e-6)

result = get_normalized_result(bundle)  # voltages in each bus's local pu base
result.converged
result.phase_voltages
```

Lower-level pipeline:

```julia
network = parse_file(dss; include_neutral=false)  # default: 3-wire, neutral at ground
ybus = build_y(network; regulator_model=:nonideal, epsilon=1e-5)
bundle = solve_power_flow(network; max_iter=20, tol=1e-6)
```

## Example grids

Bundled under `examples/grids/`:

| Folder    | Feeder        |
|-----------|---------------|
| `13_bus`  | IEEE 13       |
| `37_bus`  | IEEE 37       |
| `123_bus` | IEEE 123      |
| `240_bus` | IEEE 240      |
| `906_bus` | IEEE LV test  |
| `IEEE8500`| IEEE 8500-node|

See `examples/ieee13_zbus.jl` for a detailed IEEE 13 walkthrough (no-load voltages, load assembly, iteration).

## Main API

| Function | Role |
|----------|------|
| `parse_file` | OpenDSS → `NetworkModel` |
| `build_y` | Phase Y-bus and bus ordering |
| `build_load_model` | Load admittance / current injection |
| `solve_power_flow` / `solve_case` | Z-bus fixed-point solve → `AnalysisBundle` |
| `get_normalized_result` | Per-bus local-base pu voltages |

Solver options: `method=:zbus` (only method in v0.1), `regulator_model=:nonideal` or `:ideal`, `epsilon` for regulator regularization.

## Project layout

```
src/
  parser.jl          # DSS tokenizer and network build
  ybus.jl            # Admittance assembly
  loads.jl           # Load models
  solver.jl          # No-load solve + Z-bus iteration
  line_geometry.jl   # Line geometry / linecodes
  regulator_post.jl  # Regulator secondary voltages
examples/grids/      # Standard test feeders
```

## Status

Early research code (v0.1). Power flow is the current focus; the data model and Y-bus are intended to support **AC OPF** next.

Comparison target: **OpenDSS** phase voltages; parser behavior is checked against **PowerModelsDistribution** where applicable.
