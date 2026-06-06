# FeederFlow.jl

`FeederFlow.jl` parses benchmark OpenDSS feeder files, assembles sparse admittance partitions, builds ZIP load operators, and runs a fixed-tap Z-Bus power flow.

## Public API

```@docs
balanced_slack
parse_file
build_y
compute_no_load
build_load_model
solve_power_flow
solve_case
component_names
```

## Public Types

```@docs
ComponentTable
DSSParseError
Provenance
TerminalSpec
BusPhase
BaseQuantities
SourceSpec
BusSpec
LineCode
LineDevice
TransformerWinding
RegControl
TransformerDevice
CapacitorDevice
LoadDevice
NetworkModel
YBusModel
NoLoadResult
LoadModel
PowerFlowResult
AnalysisBundle
```

## Internal utilities

```@docs
FeederFlow.compute_regulator_secondary_voltages
```
