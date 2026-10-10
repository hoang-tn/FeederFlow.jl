# FeederFlow.jl

Unbalanced multiphase power flow for distribution feeders defined in OpenDSS.

FeederFlow reads an OpenDSS master file, builds a phase-domain nodal admittance matrix (Y-bus) covering lines, transformers, regulators, switches, capacitors, and shunts, models loads with OpenDSS ZIP-style load models, and solves with a fixed-point Z-bus iteration. It targets research on large feeders (IEEE 13, 123, 240, 906, and 8500, plus LV test cases) and is validated against OpenDSS voltages.

> **Status:** early research code (v0.1). Power flow is the current focus. The data model and Y-bus are designed to support AC OPF next.

## Installation

FeederFlow is not yet registered. Clone the repository and activate it:

```julia
using Pkg
Pkg.activate("path/to/FeederFlow.jl")
Pkg.instantiate()
```

Requires Julia 1.12 or later. OpenDSSDirect.jl and PowerModelsDistribution.jl are only needed for the test suite and the optional validation tooling. Neither is needed to run a power flow.

## Quick start

```julia
using FeederFlow

dss = joinpath(pkgdir(FeederFlow), "examples", "grids", "13_bus", "IEEE13Nodeckt.dss")

bundle = solve_case(dss; regulator_model = :nonideal, max_iter = 20, tol = 1e-6)
result = get_normalized_result(bundle)

result.converged       # true if the residual fell below `tol`
result.iterations      # number of Z-bus iterations used
result.phase_voltages  # Dict{BusPhase,ComplexF64}, per-unit on each bus's own voltage base
```

The same example is available as a script:

```bash
julia --project=. examples/ieee13_power_flow.jl
```

### Step by step

`solve_case` is a thin wrapper over the steps below, which you can call individually:

```julia
network = parse_file(dss)                      # OpenDSS -> NetworkModel
ybus    = build_y(network)                     # phase Y-bus and node ordering
bundle  = solve_power_flow(network)            # build Y-bus and loads, then solve
result  = get_normalized_result(bundle)
```

`solve_power_flow` accepts either a `NetworkModel` (as above) or a pre-assembled `AnalysisBundle`. Given a bundle, it runs only the iteration and returns a `PowerFlowResult`.

## Main API

| Function                              | Purpose                                                          |
|---------------------------------------|------------------------------------------------------------------|
| `parse_file(path)`                    | Parse an OpenDSS master file into a `NetworkModel`.              |
| `build_y(network)`                    | Assemble the Y-bus (`YBusModel`) and the bus-phase ordering.     |
| `compute_no_load(ybus)`               | Solve the no-load voltages used to seed and reference the loads. |
| `build_load_model(network, ybus, noload)` | Build load current operators and constant-impedance admittances. |
| `solve_power_flow(network)`           | Run the full pipeline and return an `AnalysisBundle`.            |
| `solve_case(path)`                    | Parse a DSS file and solve in one call.                          |
| `get_normalized_result(bundle)`       | Return voltages in each bus's local per-unit base.               |

### Options

| Keyword                | Default     | Meaning                                                              |
|------------------------|-------------|----------------------------------------------------------------------|
| `method`               | `:zbus`     | Solver method. `:zbus` is the only method in v0.1.                   |
| `regulator_model`      | `:nonideal` | `:nonideal` keeps regulator series impedance; `:ideal` removes it.   |
| `epsilon`              | `1e-5`      | Small regularization for regulator and transformer impedances.       |
| `max_iter`             | `10`        | Maximum Z-bus iterations.                                            |
| `tol`                  | `1e-5`      | Convergence tolerance on the nodal current residual (per unit, ∞-norm). |
| `include_neutral`      | `false`     | `false` drops phase 0 and treats the neutral as ground. `true` keeps phase 0 in parsed terminals, but the Y-bus still models phases 1–3 only (a warning is logged). |

Voltages in `bundle.result` use one system-wide per-unit base. `get_normalized_result` rescales them to each bus's local base, which is what you normally want when comparing against OpenDSS.

Helpers for updating the Y-bus after a switch changes state (`patch_switch_admittance!`, `switch_line_admittance`, `verify_switch_admittance_patch`) are not exported. Call them as `FeederFlow.<name>`. They support OPF-style workflows.

## Example feeders

Bundled in `examples/grids/`:

| Folder      | Feeder              |
|-------------|---------------------|
| `13_bus`    | IEEE 13-node        |
| `123_bus`   | IEEE 123-node       |
| `240_bus`   | IEEE 240-node       |
| `906_bus`   | IEEE 906-bus LV     |
| `IEEE8500`  | IEEE 8500-node      |

## Repository layout

```
src/
  FeederFlow.jl                # module definition and exports
  types.jl                     # data types (NetworkModel, YBusModel, results)
  parser.jl                    # DSS tokenizer and network builder
  line_geometry.jl             # line geometry and conductor catalog
  ybus.jl                      # Y-bus assembly
  loads.jl                     # load models
  solver.jl                    # no-load solve, Z-bus iteration, entry points
  regulator_post.jl            # regulator secondary voltages
  switch_admittance_patch.jl   # switch-state Y-bus updates
  utils.jl                     # shared helpers
examples/                      # runnable script and test feeders
validation/                    # optional OpenDSS comparison tooling (see validation/README.md)
test/                          # test suite
```

## Testing

```julia
using Pkg
Pkg.test()
```

The OpenDSS parity and PowerModelsDistribution comparison tests need the test dependencies listed in `Project.toml`; `Pkg.test()` installs them.

## License

MIT. See [LICENSE](LICENSE).
