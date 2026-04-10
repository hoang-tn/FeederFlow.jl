# FeederFlow.jl — Comprehensive Code Review Report

**Date:** 2026-04-05
**Repository:** `FeederFlow.jl`
**Branch:** `master`
**Commit:** `d7bffe9`
**Reviewers:** 5 parallel subagents (Core Source, Test Suite, Architecture, Validation Infrastructure, Comment/Docstring Analysis)

---

## Executive Summary

FeederFlow.jl is a Julia package for parsing OpenDSS DSS files and solving multiphase distribution power flow using a fixed-point Z-bus solver. The codebase demonstrates a solid foundation with clean module separation, comprehensive type definitions, and a working validation framework against OpenDSS.

**Overall Assessment:** The package is functionally complete with 4611 tests passing, but has **3 Critical issues**, **8 High-priority issues**, **10 Medium-priority issues**, and **25+ undocumented public-facing functions** that should be addressed before production use or publication.

---

## Critical Issues (Blocks Correctness)

### C1: Duplicate `best_fit_residual` Implementations with Swapped Arguments

**Location:** Across 5 test files (100+ lines of duplication)
**Severity:** Critical -- produces different numerical results for complex matrices

Five test files each implement their own `best_fit_residual` function with **different `dot()` argument orders** for complex matrices. For complex-valued power system quantities, `dot(a, b) != dot(b, a)`, meaning these functions silently produce inconsistent results. This can cause false passes or false failures in validation tests.

**Recommendation:** Extract a single canonical implementation to `test/test_support.jl` and remove all duplicates.

---

### C2: CSV Column Index Inconsistency in Voltage Parsing

**Location:**
- `scripts/compare_opendssdirect.jl` -- `voltage_csv_map()` uses columns `(3, 4, 5)`
- `test/test_support.jl` -- `parse_opendss_voltages()` uses columns `(3, 6, 5)`

**Severity:** Critical -- one of these produces wrong voltage magnitudes

The two functions that parse OpenDSS voltage CSV exports use different column indices for the magnitude field. Column 4 is raw voltage; column 6 is per-unit voltage. If both are used against the same CSV, one produces incorrect results.

**Recommendation:** Verify against an actual OpenDSS CSV export and reconcile to a single implementation.

---

### C3: `benchmark_compat.jl` Does Not Exist

**Location:** Referenced in AGENTS.md and all architectural documentation
**Severity:** Critical -- documented architecture does not match reality

AGENTS.md extensively documents a `BenchmarkCompat` submodule with `solve_case_benchmark()`, `build_y_benchmark()`, and IEEE 37/123-specific code. **This file does not exist.** The `use_benchmark` parameter flow documented in AGENTS.md is not implemented anywhere in the codebase.

**Recommendation:** Either implement the benchmark compatibility layer as documented, or update all documentation to reflect the current general-only implementation.

---

## High-Priority Issues

### H1: Benchmark Test Coverage Gap

All tests use the general code path via `parse_file`. The `use_benchmark=true/false/:auto` parameter is **never tested**, despite being critical for IEEE 37/123 MATLAB fixture parity.

### H2: `test_ybus_opendss_compare.jl` Has Zero Assertions

This file is not included in `runtests.jl` and contains no `@test` assertions. It is a diagnostic script masquerading as a test.

### H3: IEEE13 Voltage Comparison Tolerance Too Loose

`test_ieee13_component_diagnostics.jl` allows `max_mag_error < 5.0` per-unit -- meaning voltages could be 500% off and still pass. Tighten to a physically meaningful tolerance (e.g., 0.01 PU).

### H4: 30+ One-Off Experiment Scripts Clutter Package Root

Files like `debug_ieee37_odss.jl`, `fix_transformers.jl`, `compare_transformer_ybus.jl`, `run_dss_y_exp.jl`, `run_reg_experiment.jl`, `debug_base_voltage.jl`, `test_debug_norm.jl`, `test_debug.jl`, `exp.out`, `exp2.out`, `exp3.out`, `tmp_test.dss` pollute the package root.

### H5: `debug_ieee37_odss.jl` Has Syntax Errors

Line 4 uses Julia backtick syntax instead of string quotes:
```julia
REPO_ROOT = normpath(joinpath(`@__DIR__, `..))  # syntax error
```

### H6: Hardcoded Absolute Paths in Check Scripts

`check_voltages.jl`, `check_groups.jl`, `check_mismatches.jl` use raw absolute Windows paths that break on any other machine.

### H7: Duplicate Utility Functions Across 4+ Files

| Function | Files |
|----------|-------|
| `busphase_key()` | 4 files |
| `wrap_angle_diff_deg()` | 2 files |
| `actual_voltage_map()` | 2 files |
| OpenDSS solve pattern | 8+ files |

**Recommendation:** Extract shared utilities into `src/validation_utils.jl` or `test/test_utils.jl`.

### H8: 4 Source Files Not Included in Module

`src/opendss_interface.jl`, `src/scenarios.jl`, `src/validation_runner.jl`, `src/validation_stats.jl` exist in `src/` but are not `include`d in `FeederFlow.jl`. They are dead code in their current location.

---

## Medium-Priority Issues

### M1: Silent Fallback for Unknown Load Model

`src/loads.jl` silently falls through for unrecognized load model codes instead of erroring. For a power systems package, this can silently produce wrong results.

### M2: Regulator Tap Control Mixed Into Solver

`analyze_network_once` in `src/solver.jl` recreates `AnalysisBundle` **4 times** in a single call, with regulator tap control logic embedded directly in the solver. Tight coupling.

### M3: `ComponentTable` Has Minor Performance Double Storage

Names stored in `order::Vector{String}` and as keys in `data::Dict{String,T}`. Minor concern for typical network sizes.

### M4: Missing Acceptance Tolerance Bands

The validation framework compares FeederFlow vs OpenDSS but has no predefined pass/fail criteria.

### M5: No Per-Voltage-Level Statistics

Multi-voltage feeders (IEEE 123 has 4.16 kV and 0.48 kV sections) aggregate all errors together, masking per-level discrepancies.

### M6: No Regression Detection Between Validation Runs

No mechanism compares current results against previous runs.

### M7: `check_mismatches.jl` Has Wrong Package Activation

`Pkg.activate(".")` activates the parent directory project, not `FeederFlow.jl/`.

### M8: Misleading Test Names

Some test names suggest OpenDSS comparison but contain no actual OpenDSS comparison.

### M9: `@assert` Used Where `@test` Should Be Used

Multiple test files use `@assert` which throws `AssertionError` (not caught by test framework) and is stripped by `julia -O0`.

### M10: Missing Metrics in Validation Stats

Missing: RMS error, signed angle error tracking, per-component-type error grouping.

---

## Low-Priority / Suggestions

### L1: Docstring Gaps

Types missing docstrings: `BusPhase`, `BusSpec`, `LoadContribution`

### L2: `tmp_*.jl` Debug Files in Test Directory

Remove or move to separate directory.

### L3: Naming Inconsistency

`Vbase` (field) vs `bus_vbase` (function). Consider `v_base` or `vbase` for consistency.

### L4: `wrap_angle_diff_deg()` Returns Absolute Value

Loses signed angle information. Return signed value and let callers decide.

### L5: Cleanup Retry May Still Fail

5 exponential backoff retries for Windows file locks may still fail silently.

### L6: No Per-Voltage-Level Normalization Validation

The solver does not validate that per-bus normalization is actually meaningful.

---

## Documentation & Comment Review

*(From comment-analyzer subagent)*

### DC1: Misleading `unit_to_kft` Docstring

**Location:** `ybus.jl:122-127`

The docstring says `"none"` means values are already per-unit-length, but both `"none"` and `"kft"` return `1.0` for different reasons. Clarify that `"kft"` is the target basis unit itself, while `"none"` is the legacy default.

### DC2: Misleading Capacitance Default Comment

**Location:** `parser.jl:773`

```julia
# OpenDSS default shunt capacitance for overhead lines (~2.8 nF/mi diagonal)
```

This is a synthetic default, not OpenDSS-compliant. Rewrite: `# Synthetic default when cmatrix is omitted (not OpenDSS-compliant).`

### DC3: 25+ Public-Facing Functions Without Docstrings

**`ybus.jl` (15 undocumented functions):**
- `transformer_series_impedance`, `regulator_series_impedance`, `open_delta_regulator_series_impedance` -- core model formulas
- `transformer_ratio` -- tap scaling logic
- `delta_wye_coupling_matrix` -- phase map needs explanation
- `transformer_regularization` -- conditioning fix, why epsilon^2 vs epsilon?
- `stamp_transformer!` -- core Y-bus stamp function
- `stamp_capacitor!`, `open_delta_regulator_groups`, `kron_reduce_partition`, etc.

**`loads.jl` (all 9 functions undocumented):**
- `load_currents` -- most important function in the file
- `load_mode`, `branch_pairs`, `branch_powers`, `add_branch_stamp!`, etc.

**`utils.jl` (18 undocumented functions):**
- `source_slack` -- slack vector construction formula
- `sequence_to_phase_matrix` -- Fortescue transformation formula should be shown
- `lower_triangle_to_matrix`, `parse_bus_terminal`, `delta_incidence`, etc.

**`solver.jl` (4 undocumented functions):**
- `analyze_network_once` -- why separated from `solve_power_flow`?
- `single_phase_regulator_control_error` -- complex formula
- `apply_regulator_tap_steps`, `full_voltage_vector`

**`parser.jl` (15+ undocumented internal functions):**
- `parse_linecode`, `parse_line`, `parse_transformer`, `parse_load`, etc.
- `compute_bus_voltage_bases`, `infer_base_quantities`, `ordered_bus_names`

### DC4: Struct Field Documentation Inconsistency

Well-documented: `LineCode`, `BaseQuantities`, `LineDevice`, `TransformerDevice` (have `Fields:` sections).
Poorly documented: `CapacitorDevice`, `LoadDevice`, `RegControl`, `SourceSpec`, `Provenance`, `DSSParseError`, `BusPhase`, `BusSpec`, `LoadContribution`.

### DC5: No TODO/FIXME/HACK Markers Found

**Positive finding:** Zero technical debt markers in `src/`. However, there is a **commented-out test** in `runtests.jl` (`test_power_flow_correctness.jl` excluded) which is a form of technical debt.

---

## Good Documentation Examples

These docstrings serve as excellent Julia documentation models:

1. `parser.jl:37-60` -- `strip_comment`: Outstanding state-machine documentation
2. `parser.jl:113-143` -- `tokenize_dss`: Three state machines clearly explained
3. `parser.jl:362-395` -- `collect_commands`: Recursion, cycle detection, line continuation
4. `types.jl:48-65` -- `BaseQuantities`: Complete field descriptions with units
5. `types.jl:119-131` -- `LineCode`: Complete with unit strings and defaults
6. `types.jl:246-260` -- `AnalysisBundle`: Clear about when `normalized_result` is set

---

## Test Suite Status

| Area | Status | Notes |
|------|--------|-------|
| Parser correctness | OK | Well covered |
| Parser behaviors/edge cases | OK | Good coverage |
| Parser units | OK | Covered |
| Y-bus correctness | OK | Good coverage |
| Line sanity | OK | Covered |
| Line OpenDSS parity | WARN | Silent `isfile \|\| continue` can mask missing files |
| Regulator Y-prim | OK | Good coverage |
| Regulator secondary | OK | Covered |
| Component admittance parity | WARN | Duplicate `best_fit_residual` issue (C1) |
| Power flow correctness | OK | Rigorous test version exists |
| OpenDSS comparison | WARN | Zero assertions (H2) |
| IEEE13 diagnostics | FAIL | Not in `runtests.jl` |
| Benchmark compatibility | FAIL | Not tested (H1) |
| PMD parser PU | OK | Covered |

---

## Validation Framework Assessment

### Strengths
- Clean modular separation (scenarios -> OpenDSS interface -> stats -> runner)
- Consistent use of immutable structs for data
- Good use of CSV/JSON for result export
- Deterministic seed management for reproducibility
- Temp file isolation -- no pollution of original DSS files
- Global vbase normalization for consistent per-unit comparison
- Comprehensive scenario coverage (load scaling, random load, tap sweep, cross-product)
- Convergence tracking for both solvers

### Weaknesses
- No unit tests for the validation framework itself
- No acceptance criteria / pass-fail thresholds
- No regression detection between runs
- No CI integration
- 30+ ad-hoc scripts with significant duplication

---

## Priority Action Items

| # | Action | Impact | Effort |
|---|--------|--------|--------|
| 1 | Fix CSV column inconsistency (C2) | Blocks correct validation | Low |
| 2 | Fix or delete `debug_ieee37_odss.jl` (H5) | Dead code | Low |
| 3 | Extract single `best_fit_residual` (C1) | Prevents silent wrong results | Medium |
| 4 | Document or implement benchmark compat (C3) | Core architectural gap | High |
| 5 | Move archive scripts out of root (H4) | Major cleanup | Low |
| 6 | Extract shared utilities (H7) | Reduces duplication | Medium |
| 7 | Add `include()` for missing src files (H8) | Dead code | Low |
| 8 | Include IEEE13 diagnostics in tests | Missing coverage | Low |
| 9 | Fix hardcoded absolute paths (H6) | Portability | Low |
| 10 | Add docstrings to loads.jl (DC3) | 9 functions undocumented | Medium |
| 11 | Add docstrings to ybus.jl helpers (DC3) | 15 functions undocumented | Medium |
| 12 | Add pass/fail tolerance bands (M4) | Validation usefulness | Medium |

---

## Summary Statistics

| Category | Count |
|----------|-------|
| Critical Issues | 3 |
| High-Priority Issues | 8 |
| Medium-Priority Issues | 10 |
| Low-Priority / Suggestions | 6 |
| Undocumented Functions (public-facing) | 25+ |
| Misleading/Inaccurate Comments | 2 |
| Duplicate Utility Functions | 3 (across 4-8 files) |
| One-Off Scripts to Archive | ~20 |
| Test Coverage Gaps | 2 |
| TODO/FIXME/HACK Markers | 0 (positive finding) |

---

*This report was generated by 5 parallel code review subagents covering: (1) Core Source Code, (2) Test Suite Quality, (3) Architecture & Type System Design, (4) Validation Infrastructure & Diagnostic Scripts, (5) Comment & Docstring Analysis.*

