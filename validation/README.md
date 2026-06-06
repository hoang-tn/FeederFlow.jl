# Validation Workflows

Optional offline tooling for comparing FeederFlow against OpenDSS across scenario sweeps. This code is not loaded by `using FeederFlow`.

## Requirements

Install the main package plus validation dependencies:

```julia
using Pkg
Pkg.activate("path/to/FeederFlow.jl")
Pkg.instantiate()
Pkg.add(["OpenDSSDirect", "CSV", "DataFrames", "JSON3"])
```

## Files

- `validation_runner.jl`: scenario orchestration and reporting
- `opendss_interface.jl`: DSS rewrite and OpenDSSDirect execution
- `scenarios.jl`: deterministic and random scenario generation
- `validation_stats.jl`: error metrics and CSV export

## Usage

From the package root:

```julia
using Pkg
Pkg.activate(".")
include("validation/validation_runner.jl")
list_available_networks()
```

Bundled feeders live under `examples/grids/`. EPRI `ckt5`, `ckt7`, and `ckt24` are not bundled in this repository.

## Output

Write results to `validation/output/` (gitignored) or another local directory when running scenario sweeps.
