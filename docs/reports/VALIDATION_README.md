# OpenDSS Validation Scenario Testing Suite

## Overview

This validation framework provides comprehensive testing of FeederFlow.jl against OpenDSS across multiple scenarios with varying loads and regulator tap positions. The suite generates statistical error metrics to inform development and identify areas for improvement.

## Features

- **Multi-Network Support**: Tests IEEE 13, 37, 123, and 906-bus feeders
- **Scenario Generation**: 
  - Deterministic load scaling (50%, 75%, 100%, 125%, 150%)
  - Random load variations (Monte Carlo with ±30% per load)
  - Tap position sweeps for regulators (±16 steps)
  - Random tap positions (Monte Carlo)
- **Error Metrics**: Voltage magnitude and angle differences
- **Statistical Analysis**: Max, mean, median, std, 95th/99th percentiles
- **CSV Output**: Easy analysis in spreadsheets or Python/R

## Installation

The validation suite is integrated into FeederFlow.jl. Required dependencies:

```julia
using Pkg
Pkg.add(["CSV", "DataFrames", "JSON3", "OpenDSSDirect"])
```

## Usage

### Basic Usage

List available networks:
```bash
julia --project=. --compiled-modules=no scripts/run_validation_scenarios.jl --list
```

Run validation on a single network:
```bash
julia --project=. --compiled-modules=no scripts/run_validation_scenarios.jl --networks=ieee37
```

Run on all networks:
```bash
julia --project=. --compiled-modules=no scripts/run_validation_scenarios.jl --networks=all
```

### Advanced Options

```bash
julia --project=. --compiled-modules=no scripts/run_validation_scenarios.jl \
    --networks=ieee37,ieee123 \
    --num-scenarios=20 \
    --output-dir=my_validation_results \
    --load-seed=12345 \
    --tap-seed=54321 \
    --verbose
```

**Options**:
- `--networks=NAMES`: Comma-separated network names or "all"
- `--num-scenarios=N`: Number of random scenarios (default: 10)
- `--output-dir=PATH`: Output directory (default: validation_results)
- `--load-seed=N`: Random seed for load variations (default: 12345)
- `--tap-seed=N`: Random seed for tap variations (default: 54321)
- `--list`: List available networks
- `--verbose`: Enable verbose output
- `--help`: Show help message

## Output Structure

```
validation_results/
├── scenarios/
│   ├── ieee13_scenarios.csv       # Scenario definitions
│   ├── ieee37_scenarios.csv
│   ├── ieee123_scenarios.csv
│   └── ieee906_scenarios.csv
├── raw_results/
│   ├── ieee13_raw.csv            # Per-bus-phase errors
│   ├── ieee37_raw.csv
│   ├── ieee123_raw.csv
│   └── ieee906_raw.csv
├── summary/
│   ├── scenario_summary.csv      # Per-scenario statistics
│   ├── network_summary.csv       # Per-network statistics
│   └── overall_summary.csv       # Cross-network summary
└── metadata.json                 # Run configuration
```

### Output File Descriptions

#### scenarios/*.csv
Defines each scenario with:
- `network`: Network name
- `scenario_id`: Unique scenario identifier
- `description`: Human-readable description
- `load_scale`: Global load scaling factor
- `n_load_variations`: Number of individual load modifications
- `n_tap_positions`: Number of regulator tap modifications

#### raw_results/*.csv
Per-bus-phase error metrics:
- `network`, `scenario_id`, `bus_phase`: Identifiers
- `abs_voltage_error`: |V_feederflow - V_opendss|
- `mag_voltage_error`: ||V_feederflow| - |V_opendss||
- `angle_error_deg`: Angle difference in degrees (wrapped ±180°)
- `feederflow_mag`, `feederflow_angle`: FeederFlow voltage
- `opendss_mag`, `opendss_angle`: OpenDSS voltage

#### summary/scenario_summary.csv
Aggregated statistics per scenario:
- `max_abs_error`, `mean_abs_error`, `std_abs_error`: Voltage error stats
- `p95_abs_error`: 95th percentile error
- `max_mag_error`, `mean_mag_error`: Magnitude error
- `max_angle_error`, `mean_angle_error`: Angle error
- `feederflow_converged`, `opendss_converged`: Convergence flags

#### summary/network_summary.csv
Aggregated statistics per network:
- `n_scenarios`: Total scenarios tested
- `n_converged_both`, `n_converged_ff_only`, `n_converged_dss_only`, `n_failed_both`: Convergence counts
- `max_abs_error`, `mean_abs_error`, `median_abs_error`: Error distribution
- `std_abs_error`, `p95_abs_error`, `p99_abs_error`: Error statistics

#### summary/overall_summary.csv
Cross-network summary with total counts and overall error metrics.

#### metadata.json
Run configuration including:
- Networks tested
- Random seeds
- Timestamp
- Julia version
- Number of scenarios per network

## Scenario Design

### Networks Without Regulators (IEEE 13, 906)
- 5 load scaling scenarios
- N random load scenarios (default: 10)
- **Total**: ~15 scenarios per network

### Networks With Regulators (IEEE 37, 123)
- 5 load scaling scenarios
- N random load scenarios (default: 10)
- 9 tap sweep scenarios
- N/2 random tap scenarios (default: 5)
- Cross-product of loads × taps
- **Total**: ~69-150 scenarios per network (depending on N)

### Default Scenario Counts
With `--num-scenarios=10`:
- IEEE 13: 15 scenarios
- IEEE 37: 69 scenarios
- IEEE 123: 69 scenarios
- IEEE 906: 15 scenarios
- **Total**: ~168 scenarios

## Error Metrics

### Absolute Voltage Error
```
abs_voltage_error = |V_feederflow - V_opendss|
```
Measures total voltage phasor difference in per-unit.

### Magnitude Voltage Error
```
mag_voltage_error = ||V_feederflow| - |V_opendss||
```
Measures only magnitude difference, ignoring phase.

### Angle Error
```
angle_error_deg = angle(V_feederflow) - angle(V_opendss)
```
Wrapped to [-180°, 180°]. Measures phase angle difference.

## Implementation Details

### Module Structure

1. **scenarios.jl**: Scenario generation
   - `ScenarioConfig`: Scenario definition type
   - `generate_load_scaling_scenarios()`: Deterministic load scaling
   - `generate_random_load_scenarios()`: Monte Carlo load variations
   - `generate_tap_sweep_scenarios()`: Deterministic tap sweeps
   - `generate_random_tap_scenarios()`: Monte Carlo tap positions
   - `generate_all_scenarios()`: Complete scenario set generation

2. **opendss_interface.jl**: OpenDSS integration
   - `modify_dss_file()`: Create modified DSS files
   - `execute_opendss()`: Run OpenDSS and extract voltages
   - `feederflow_voltage_map()`: Convert FeederFlow output format

3. **validation_stats.jl**: Error metrics and statistics
   - `ErrorMetrics`: Per-bus-phase error type
   - `ScenarioSummary`: Per-scenario aggregate statistics
   - `compute_error_metrics()`: Calculate error metrics
   - `aggregate_scenario_metrics()`: Aggregate per scenario
   - `compute_network_statistics()`: Aggregate per network
   - `export_*()`: CSV export functions

4. **validation_runner.jl**: Orchestration
   - `NetworkConfig`: Network configuration type
   - `ValidationResult`: Scenario result type
   - `run_single_scenario()`: Execute one scenario
   - `run_all_scenarios()`: Execute all scenarios for a network
   - `generate_final_reports()`: Create summary reports

5. **scripts/run_validation_scenarios.jl**: Main entry point
   - Command-line interface
   - Network selection and configuration
   - Result aggregation and reporting

### Network Registry

Networks are automatically discovered from the repository structure:

```julia
ieee13  → FeederFlow.jl/examples/grids/13_bus/IEEE13Nodeckt.dss
ieee37  → three-phase-modeling/IEEE 37-bus feeder/IEEE37openDSSdata/ieee37opendss.dss
ieee123 → three-phase-modeling/IEEE 123-bus feeder/IEEE123openDSSdata/IEEE123Master.dss
ieee906 → three-phase-modeling/European 906-bus LV feeder/IEEELVopenDSSdata/Master.dss
```

Regulator presence is auto-detected by parsing the DSS file.

## Known Limitations

### DSS File Dependencies
The current implementation creates modified DSS files in temporary directories. OpenDSS `Redirect` and `Include` statements use relative paths, which can cause issues when the modified file is in a different directory than the original.

**Workaround**: Future versions should:
1. Parse and inline all `Redirect`/`Include` statements
2. Use OpenDSS API to modify circuit in-memory rather than file-based
3. Copy entire DSS file directory structure to temp location

### Convergence Issues
Some scenarios may fail to converge in FeederFlow or OpenDSS, particularly:
- Extreme load scaling (50% or 150%)
- Extreme tap positions (±16 steps)
- Combined extreme scenarios

Failed scenarios are recorded with NaN error metrics and tracked in convergence statistics.

### Performance
- Large scenario counts (>100 per network) can be slow
- Each scenario requires parsing DSS file and solving power flow twice
- Estimated time: ~5-10 seconds per scenario

## Analyzing Results

### Load CSV in Python

```python
import pandas as pd

# Load scenario summary
summary = pd.read_csv('validation_results/summary/scenario_summary.csv')

# Filter to converged scenarios
converged = summary[summary['feederflow_converged'] & summary['opendss_converged']]

# Plot error distribution
import matplotlib.pyplot as plt
plt.hist(converged['max_abs_error'], bins=50)
plt.xlabel('Max Absolute Voltage Error (pu)')
plt.ylabel('Count')
plt.title('Error Distribution Across Scenarios')
plt.show()

# Group by network
network_errors = converged.groupby('network')['max_abs_error'].describe()
print(network_errors)
```

### Load CSV in Julia

```julia
using CSV, DataFrames, Statistics

# Load scenario summary
summary = CSV.read("validation_results/summary/scenario_summary.csv", DataFrame)

# Filter converged scenarios
converged = filter(row -> row.feederflow_converged && row.opendss_converged, summary)

# Compute statistics
println("Mean max error: ", mean(converged.max_abs_error))
println("95th percentile: ", quantile(converged.max_abs_error, 0.95))

# Group by network
grouped = groupby(converged, :network)
combine(grouped, :max_abs_error => mean, :max_abs_error => maximum)
```

## Development Notes

### Adding New Networks

1. Add network to `get_network_registry()` in `validation_runner.jl`
2. Ensure DSS file path is correct
3. Run with `--networks=new_network_name`

### Modifying Scenario Generation

Edit `scenarios.jl`:
- Adjust load scaling factors in `generate_load_scaling_scenarios()`
- Change tap positions in `generate_tap_sweep_scenarios()`
- Modify variation percentages in random generators

### Adding New Error Metrics

1. Add fields to `ErrorMetrics` type in `validation_stats.jl`
2. Update `compute_error_metrics()` to calculate new metrics
3. Update CSV export functions to include new fields

## Troubleshooting

### "Package not found" errors
```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

### OpenDSSDirect warnings
Use `--compiled-modules=no` to avoid precompilation issues with OpenDSSDirect v0.9.9:
```bash
julia --project=. --compiled-modules=no scripts/run_validation_scenarios.jl ...
```

### Empty results
- Check that DSS files exist at expected paths
- Verify network names with `--list`
- Enable `--verbose` to see detailed error messages

### Memory issues with large networks
Reduce `--num-scenarios` or test networks individually.

## Citation

If you use this validation framework in research, please cite:

```bibtex
@software{feederflow_validation,
  title = {OpenDSS Validation Scenario Testing for FeederFlow.jl},
  year = {2026},
  author = {FeederFlow Development Team}
}
```

## Contributing

To contribute improvements:
1. Test changes on at least IEEE 37 and 123 networks
2. Ensure backward compatibility with existing CSV outputs
3. Document any new command-line options
4. Update this README

## License

Same license as FeederFlow.jl parent project.
