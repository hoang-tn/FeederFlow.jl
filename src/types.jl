"""
    DSSParseError(file, line, object, property, message)

Structured parser exception with source location and OpenDSS object/property context.
"""
struct DSSParseError <: Exception
    file::String
    line::Int
    object::String
    property::String
    message::String
end

function Base.showerror(io::IO, err::DSSParseError)
    print(io, "DSSParseError(", err.file, ":", err.line)
    if !isempty(err.object)
        print(io, ", object=", err.object)
    end
    if !isempty(err.property)
        print(io, ", property=", err.property)
    end
    print(io, "): ", err.message)
end

"""
    Provenance(source_file, object_name, original_properties, command_origin)

Metadata snapshot for a parsed OpenDSS object.
"""
struct Provenance
    source_file::String
    object_name::String
    original_properties::Dict{String,Any}
    command_origin::String
end

"""
    ComponentTable(items)
    ComponentTable{T}(order, data)

Name-indexed, iteration-stable container used for parsed network components.
Supports vector-style iteration and string-key lookup.
"""
struct ComponentTable{T} <: AbstractVector{T}
    order::Vector{String}
    data::Dict{String,T}
    function ComponentTable{T}(order::Vector{String}, data::Dict{String,T}) where T
        length(order) == length(data) || throw(ArgumentError("ComponentTable order and data must have the same length"))
        for name in order
            haskey(data, name) || throw(ArgumentError("ComponentTable is missing data for component $name"))
        end
        new{T}(order, data)
    end
end

function ComponentTable(items::AbstractVector{T}) where T
    order = String[]
    data = Dict{String,T}()
    for item in items
        hasproperty(item, :name) || throw(ArgumentError("ComponentTable items must have a .name field"))
        name = String(getproperty(item, :name))
        haskey(data, name) && throw(ArgumentError("Duplicate component name $name"))
        push!(order, name)
        data[name] = item
    end
    return ComponentTable{T}(order, data)
end

Base.IndexStyle(::Type{<:ComponentTable}) = IndexLinear()
Base.size(table::ComponentTable) = (length(table.order),)
Base.axes(table::ComponentTable) = (Base.OneTo(length(table.order)),)
Base.getindex(table::ComponentTable, index::Int) = table.data[table.order[index]]
Base.getindex(table::ComponentTable, name::AbstractString) = table.data[String(name)]
Base.haskey(table::ComponentTable, name::AbstractString) = haskey(table.data, String(name))
Base.get(table::ComponentTable, name::AbstractString, default) = get(table.data, String(name), default)
Base.similar(table::ComponentTable, ::Type{T}, dims::Dims{1}) where T = Vector{T}(undef, dims[1])
Base.similar(table::ComponentTable, dims::Dims{1}) = Vector{eltype(table)}(undef, dims[1])

"""
    component_names(table)

Return component names in the table's deterministic iteration order.
"""
component_names(table::ComponentTable) = copy(table.order)

"""
    TerminalSpec(bus, phases)

Bus terminal descriptor with bus name and 1-based phase numbers.
"""
struct TerminalSpec
    bus::String
    phases::Vector{Int}
end

"""
    BusPhase(bus, phase)

Single electrical node identifier keyed by bus name and phase number.
"""
struct BusPhase
    bus::String
    phase::Int
end

"""
    BaseQuantities(Sbase, Vbase, Zbase, Ybase)

Per-unit base quantities used across network assembly and solving.

Fields:
- `Sbase`: System-wide power base (VA)
- `Vbase`: System-wide voltage base (LN, V)
- `Zbase`: System-wide impedance base (Ω)
- `Ybase`: System-wide admittance base (S)
"""
struct BaseQuantities
    Sbase::Float64
    Vbase::Float64
    Zbase::Float64
    Ybase::Float64
end

const DEFAULT_SOURCE_COST_COEFF = Float64[1.0, 100.0, 0.0]

"""
    SourceSpec(name, bus, phases, basekv, pu, angle_deg[, cost_coeff[, conn]])

Feeder source (slack) definition, parsed from the OpenDSS circuit/`Vsource`.

Fields:
- `name`, `bus`, `phases`: Source identifier and connection point
- `basekv`: Nominal line-to-line voltage (kV)
- `pu`, `angle_deg`: Voltage magnitude (pu) and phase-A angle (degrees)
- `cost_coeff`: Cost-curve coefficients for OPF (default `[1.0, 100.0, 0.0]`)
- `conn`: `:wye` or `:delta`
- `r1`, `x1`, `r0`, `x0`: Positive- and zero-sequence source impedance

Shorter constructors fill the remaining fields with defaults.
"""
struct SourceSpec
    name::String
    bus::String
    phases::Vector{Int}
    basekv::Float64
    pu::Float64
    angle_deg::Float64
    cost_coeff::Vector{Float64}
    conn::Symbol  # :wye or :delta
    r1::Float64
    x1::Float64
    r0::Float64
    x0::Float64
end

function SourceSpec(name::String, bus::String, phases::Vector{Int}, basekv::Float64, pu::Float64)
    SourceSpec(name, bus, phases, basekv, pu, 0.0, copy(DEFAULT_SOURCE_COST_COEFF), :wye, 0.0, 0.0, 0.0, 0.0)
end

function SourceSpec(name::String, bus::String, phases::Vector{Int}, basekv::Float64, pu::Float64, angle_deg::Float64)
    SourceSpec(name, bus, phases, basekv, pu, angle_deg, copy(DEFAULT_SOURCE_COST_COEFF), :wye, 0.0, 0.0, 0.0, 0.0)
end

function SourceSpec(name::String, bus::String, phases::Vector{Int}, basekv::Float64, pu::Float64, angle_deg::Float64, conn::Symbol)
    SourceSpec(name, bus, phases, basekv, pu, angle_deg, copy(DEFAULT_SOURCE_COST_COEFF), conn, 0.0, 0.0, 0.0, 0.0)
end

function SourceSpec(name::String, bus::String, phases::Vector{Int}, basekv::Float64, pu::Float64,
                    angle_deg::Float64, cost_coeff::Real, conn::Symbol)
    SourceSpec(name, bus, phases, basekv, pu, angle_deg, Float64[Float64(cost_coeff), 0.0, 0.0], conn, 0.0, 0.0, 0.0, 0.0)
end

function SourceSpec(name::String, bus::String, phases::Vector{Int}, basekv::Float64, pu::Float64,
                    angle_deg::Float64, cost_coeff::Real)
    SourceSpec(name, bus, phases, basekv, pu, angle_deg, cost_coeff, :wye)
end

function SourceSpec(name::String, bus::String, phases::Vector{Int}, basekv::Float64, pu::Float64,
                    angle_deg::Float64, cost_coeff::AbstractVector{<:Real}, conn::Symbol)
    SourceSpec(name, bus, phases, basekv, pu, angle_deg, Float64.(cost_coeff), conn, 0.0, 0.0, 0.0, 0.0)
end

function SourceSpec(name::String, bus::String, phases::Vector{Int}, basekv::Float64, pu::Float64,
                    angle_deg::Float64, cost_coeff::AbstractVector{<:Real}, conn::Symbol,
                    r1::Real, x1::Real, r0::Real, x0::Real)
    SourceSpec(name, bus, phases, basekv, pu, angle_deg, Float64.(cost_coeff), conn,
               Float64(r1), Float64(x1), Float64(r0), Float64(x0))
end

"""
    BusSpec(name, phases[, vmin_pu, vmax_pu])

Bus metadata: available phases, voltage limits, and local voltage base.

Fields:
- `name`: Bus identifier
- `phases`: Available phase numbers
- `vmin_pu`, `vmax_pu`: Voltage magnitude limits in pu (default 0.9 and 1.1)
- `vbase`: Nominal line-to-neutral voltage base (V); `NaN` until it is inferred
"""
mutable struct BusSpec
    name::String
    phases::Vector{Int}
    vmin_pu::Float64
    vmax_pu::Float64
    vbase::Float64
end

# Backward-compatible constructor with default voltage limits
BusSpec(name::String, phases::Vector{Int}) = BusSpec(name, phases, 0.9, 1.1, NaN)

# Backward-compatible constructor without explicit voltage base
BusSpec(name::String, phases::Vector{Int}, vmin_pu::Float64, vmax_pu::Float64) = BusSpec(name, phases, vmin_pu, vmax_pu, NaN)

"""
    LineCode(name, nphases, rmatrix, xmatrix, cmatrix)

Line impedance and capacitance template parsed from OpenDSS linecode objects.

Fields:
- `name`: Linecode identifier
- `nphases`: Number of phases
- `rmatrix`, `xmatrix`: Series resistance and reactance matrices (Ω per unit length)
- `cmatrix`: Shunt capacitance matrix (nF per unit length)
- `units`: Length unit (`"none"`, `"mi"`, `"kft"`, `"km"`, `"m"`, `"ft"`; default `"none"`)
- `basefreq`: Frequency used for the capacitance calculation (default 60 Hz)
- `normamps`, `emergamps`: Normal and emergency current ratings (A; default 400 and 600)
"""
struct LineCode
    name::String
    nphases::Int
    rmatrix::Matrix{Float64}
    xmatrix::Matrix{Float64}
    cmatrix::Matrix{Float64}
    units::String
    basefreq::Float64
    normamps::Float64
    emergamps::Float64
end

"""
    WireData(name, rac, rdc, gmrac, capradius, normamps, emergamps)

Overhead conductor catalog entry parsed from an OpenDSS `WireData` object.
Values are stored in SI units (Ω/m for resistance, m for lengths).
"""
struct WireData
    name::String
    rac::Float64
    rdc::Float64
    gmrac::Float64
    capradius::Float64
    normamps::Float64
    emergamps::Float64
end

"""
    LineGeometry(name, nconds, nphases, reduce, wires, xs, hs)

Conductor layout parsed from an OpenDSS `LineGeometry` object.
`xs` and `hs` are each conductor's horizontal position and height in meters,
and `wires` holds the `WireData` name used for each conductor.
"""
struct LineGeometry
    name::String
    nconds::Int
    nphases::Int
    reduce::Bool
    wires::Vector{String}
    xs::Vector{Float64}
    hs::Vector{Float64}
end

# Convenience constructor with defaults for backward compatibility
function LineCode(name::String, nphases::Int, rmatrix::Matrix{Float64}, xmatrix::Matrix{Float64}, cmatrix::Matrix{Float64})
    LineCode(name, nphases, rmatrix, xmatrix, cmatrix, "none", 60.0, 400.0, 600.0)
end

"""
    LineDevice(...)

Line element with its impedance data resolved from a linecode or line geometry.

Fields:
- `name`: Line identifier
- `from`, `to`: Terminals (`TerminalSpec`)
- `phases`: Phase numbers
- `linecode_name`: Name of the linecode, or `nothing`
- `length`: Line length, in `units`
- `rmatrix`, `xmatrix`, `cmatrix`: Per-unit-length R, X, and C matrices
- `units`: Length unit (`"none"`, `"mi"`, `"kft"`, `"km"`, `"m"`, `"ft"`)
- `basefreq`: Frequency used for shunt capacitance (Hz)
- `provenance`: Where the line was defined
- `is_switch`: `true` if defined with `Switch=y`
- `is_closed_base`: Closed state as parsed from the DSS file
- `is_closed`: Current closed state; mutable so switches can be toggled
- `normamps`, `emergamps`: Current ratings, in amperes as parsed and in pu after `parse_file`
"""
mutable struct LineDevice
    name::String
    from::TerminalSpec
    to::TerminalSpec
    phases::Vector{Int}
    linecode_name::Union{Nothing,String}
    length::Float64
    rmatrix::Matrix{Float64}
    xmatrix::Matrix{Float64}
    cmatrix::Matrix{Float64}
    units::String
    basefreq::Float64
    provenance::Provenance
    is_switch::Bool
    is_closed_base::Bool
    is_closed::Bool
    normamps::Float64
    emergamps::Float64
end

# Backward compatible constructor (without basefreq is_switch is_closed_base is_closed, defaults to 60 Hz false true true)
function LineDevice(name::String, from::TerminalSpec, to::TerminalSpec, phases::Vector{Int},
                    linecode_name::Union{Nothing,String}, length::Float64,
                    rmatrix::Matrix{Float64}, xmatrix::Matrix{Float64}, cmatrix::Matrix{Float64},
                    provenance::Provenance)
    LineDevice(name, from, to, phases, linecode_name, length, rmatrix, xmatrix, cmatrix, "none", 60.0, provenance, false, true, true, 0.0, 0.0)
end

# Backward compatible constructor (with units, without basefreq is_switch is_closed_base is_closed)
function LineDevice(name::String, from::TerminalSpec, to::TerminalSpec, phases::Vector{Int},
                    linecode_name::Union{Nothing,String}, length::Float64,
                    rmatrix::Matrix{Float64}, xmatrix::Matrix{Float64}, cmatrix::Matrix{Float64},
                    units::String, provenance::Provenance)
    LineDevice(name, from, to, phases, linecode_name, length, rmatrix, xmatrix, cmatrix, units, 60.0, provenance, false, true, true, 0.0, 0.0)
end

# Backward compatible constructor (with units and basefreq, without is_switch is_closed_base is_closed)
function LineDevice(name::String, from::TerminalSpec, to::TerminalSpec, phases::Vector{Int},
                    linecode_name::Union{Nothing,String}, length::Float64,
                    rmatrix::Matrix{Float64}, xmatrix::Matrix{Float64}, cmatrix::Matrix{Float64},
                    units::String, basefreq::Float64, provenance::Provenance)
    LineDevice(name, from, to, phases, linecode_name, length, rmatrix, xmatrix, cmatrix, units, basefreq, provenance, false, true, true, 0.0, 0.0)
end

# Backward compatible constructor for the old full signature without is_closed_base.
function LineDevice(name::String, from::TerminalSpec, to::TerminalSpec, phases::Vector{Int},
                    linecode_name::Union{Nothing,String}, length::Float64,
                    rmatrix::Matrix{Float64}, xmatrix::Matrix{Float64}, cmatrix::Matrix{Float64},
                    units::String, basefreq::Float64, provenance::Provenance,
                    is_switch::Bool, is_closed::Bool, normamps::Float64, emergamps::Float64)
    LineDevice(name, from, to, phases, linecode_name, length, rmatrix, xmatrix, cmatrix, units, basefreq, provenance, is_switch, is_closed, is_closed, normamps, emergamps)
end

"""
    TransformerWinding(index, bus, conn, kv, kva, resistance, tap)

One transformer winding: `index` (1-based), terminal `bus`, connection `conn`
(`:wye` or `:delta`), rated `kv` and `kva`, `resistance` (`%R`), and `tap` (pu).
"""
struct TransformerWinding
    index::Int
    bus::TerminalSpec
    conn::Symbol
    kv::Float64
    kva::Float64
    resistance::Float64
    tap::Float64
end

"""
    RegControl(...)

Voltage-regulator control settings from an OpenDSS `RegControl`, attached to the
transformer named by `transformer`: regulated `winding`, target `vreg`, `band`,
PT/CT ratios (`ptratio`, `ctprim`), line-drop compensation (`r`, `x`), and
whether the control is `enabled`.
"""
struct RegControl
    name::String
    transformer::String
    winding::Int
    vreg::Float64
    band::Float64
    ptratio::Float64
    ctprim::Float64
    r::Float64
    x::Float64
    enabled::Bool
    provenance::Provenance
end

"""
    TransformerDevice(...)

Transformer with its windings and, for voltage regulators, the control settings.

Fields:
- `name`: Transformer identifier
- `phases`: Phase numbers
- `windings`: `TransformerWinding` entries (two or three supported)
- `xhl_percent`: Leakage reactance between windings 1 and 2 (%)
- `xht_percent`, `xlt_percent`: Leakage reactance for pairs 1–3 and 2–3 (%); used by three-winding transformers only
- `percent_loadloss`: Copper loss at rated power (%)
- `percent_noloadloss`: Core loss at no load (%)
- `percent_imag`: Magnetizing current (%)
- `is_regulator`: `true` for a voltage regulator
- `regcontrol`: Associated `RegControl`, or `nothing`
- `provenance`: Where the transformer was defined
"""
struct TransformerDevice
    name::String
    phases::Vector{Int}
    windings::Vector{TransformerWinding}
    xhl_percent::Float64
    xht_percent::Float64
    xlt_percent::Float64
    percent_loadloss::Float64
    percent_noloadloss::Float64
    percent_imag::Float64
    is_regulator::Bool
    regcontrol::Union{Nothing,RegControl}
    provenance::Provenance
end

# Backward compatible constructor
function TransformerDevice(name::String, phases::Vector{Int}, windings::Vector{TransformerWinding},
                           xhl_percent::Float64, is_regulator::Bool, regcontrol::Union{Nothing,RegControl},
                           provenance::Provenance)
    TransformerDevice(name, phases, windings, xhl_percent, 0.0, 0.0, 0.0, 0.0, 0.0, is_regulator, regcontrol, provenance)
end

"""
    CapacitorDevice(...)

Shunt capacitor bank: terminal `bus`, `phases`, per-phase `kvar`, rated `kv`,
and connection `conn` (`:wye` or `:delta`).
"""
struct CapacitorDevice
    name::String
    bus::TerminalSpec
    phases::Vector{Int}
    kvar::Vector{Float64}
    kv::Float64
    conn::Symbol  # Connection type: :wye or :delta
    provenance::Provenance
end

const DEFAULT_PV_COST_COEFF = Float64[0.1, 5.0, 0.0]

"""
    GeneratorDevice(...)

Distributed energy resource (PV, wind, diesel, battery, ...) with the limits and
cost data needed for OPF. Power values are in per-unit on the system base.

Fields:
- `name`: Generator identifier
- `bus`, `phases`, `conn`, `kv`: Electrical connection
- `p_pu`: Active power setpoint or availability (pu on `Sbase`)
- `pf`: Power factor (positive lagging, negative leading)
- `kva_pu`: Apparent power rating, i.e. inverter capacity (pu on `Sbase`)
- `qmin_pu`, `qmax_pu`: Reactive power limits (pu on `Sbase`)
- `vminpu`, `vmaxpu`: Voltage operating limits (pu)
- `cost_coeff`: Cost-curve coefficients (PVs parsed from DSS default to `DEFAULT_PV_COST_COEFF`)
- `generator_type`: `:pv`, `:wind`, `:diesel`, `:battery`, etc.
- `provenance`: Where the generator was defined; the original (unconverted) values are kept in `original_properties`
"""
struct GeneratorDevice
    name::String
    bus::TerminalSpec
    phases::Vector{Int}
    conn::Symbol
    kv::Float64
    p_pu::Float64
    pf::Float64
    kva_pu::Float64
    qmax_pu::Float64
    qmin_pu::Float64
    vminpu::Float64
    vmaxpu::Float64
    cost_coeff::Vector{Float64}
    generator_type::Symbol
    provenance::Provenance
end

function GeneratorDevice(name::String, bus::TerminalSpec, phases::Vector{Int}, conn::Symbol,
                         kv::Float64, p_pu::Float64, pf::Float64, kva_pu::Float64,
                         qmax_pu::Float64, qmin_pu::Float64, vminpu::Float64, vmaxpu::Float64,
                         generator_type::Symbol, provenance::Provenance)
    GeneratorDevice(name, bus, phases, conn, kv, p_pu, pf, kva_pu, qmax_pu, qmin_pu, vminpu, vmaxpu,
                    Float64[0.0, 0.0, 0.0], generator_type, provenance)
end

function GeneratorDevice(name::String, bus::TerminalSpec, phases::Vector{Int}, conn::Symbol,
                         kv::Float64, p_pu::Float64, pf::Float64, kva_pu::Float64,
                         qmax_pu::Float64, qmin_pu::Float64, vminpu::Float64, vmaxpu::Float64,
                         cost_coeff::Real, generator_type::Symbol, provenance::Provenance)
    GeneratorDevice(name, bus, phases, conn, kv, p_pu, pf, kva_pu, qmax_pu, qmin_pu, vminpu, vmaxpu,
                    Float64[Float64(cost_coeff), 0.0, 0.0], generator_type, provenance)
end

function GeneratorDevice(name::String, bus::TerminalSpec, phases::Vector{Int}, conn::Symbol,
                         kv::Float64, p_pu::Float64, pf::Float64, kva_pu::Float64,
                         qmax_pu::Float64, qmin_pu::Float64, vminpu::Float64, vmaxpu::Float64,
                         cost_coeff::AbstractVector{<:Real}, generator_type::Symbol, provenance::Provenance)
    GeneratorDevice(name, bus, phases, conn, kv, p_pu, pf, kva_pu, qmax_pu, qmin_pu, vminpu, vmaxpu,
                    Float64.(cost_coeff), generator_type, provenance)
end

"""
    LoadDevice(...)

Load with its connection type, OpenDSS load `model` code (1–5), and demand
(`p_pu`, `q_pu`, per-unit on the system base). `vminpu`/`vmaxpu` set the voltage
band in which the model applies as specified, and `cvrwatts`/`cvrvars`
are the CVR exponents used by model 4. See `load_currents` for how each model behaves
outside the voltage band.
"""
struct LoadDevice
    name::String
    bus::TerminalSpec
    phases::Vector{Int}
    conn::Symbol
    model::Int
    kv::Float64
    p_pu::Float64
    q_pu::Float64
    vminpu::Float64
    vmaxpu::Float64
    cvrwatts::Float64
    cvrvars::Float64
    provenance::Provenance
end

function LoadDevice(name::String, bus::TerminalSpec, phases::Vector{Int}, conn::Symbol, model::Int,
                    kv::Float64, p_pu::Float64, q_pu::Float64, provenance::Provenance)
    LoadDevice(name, bus, phases, conn, model, kv, p_pu, q_pu, 0.95, 1.05, 1.0, 2.0, provenance)
end

"""
    NetworkModel(...)

Parsed feeder: bus and component tables, the source/slack definition, system
base quantities, and parse provenance. Built by `parse_file`.
"""
struct NetworkModel
    buses::ComponentTable{BusSpec}
    slack_bus::String
    source::SourceSpec
    linecodes::ComponentTable{LineCode}
    lines::ComponentTable{LineDevice}
    transformers::ComponentTable{TransformerDevice}
    regulators::ComponentTable{TransformerDevice}
    capacitors::ComponentTable{CapacitorDevice}
    generators::ComponentTable{GeneratorDevice}
    loads::ComponentTable{LoadDevice}
    base::BaseQuantities
    provenance::Dict{String,Any}
end

"""
    YBusModel(...)

Nodal admittance model built by `build_y`.

- `Ynet`: Full admittance matrix, with network nodes first and slack nodes last
- `Y`, `Y_NS`, `Y_SS`: Blocks of `Ynet` — network–network, network–slack, and slack–slack
- `network_order`, `slack_order`, `all_order`: Node ordering; `all_order` is network nodes followed by slack nodes
- `network_index`, `all_index`: Row lookup by `BusPhase`
- `available_phases`: Phases present at each bus
- `YL`: Constant-impedance load admittances from `build_load_model`
"""
struct YBusModel
    Ynet::SparseMatrixCSC{ComplexF64,Int}
    Y::SparseMatrixCSC{ComplexF64,Int}
    Y_NS::SparseMatrixCSC{ComplexF64,Int}
    Y_SS::SparseMatrixCSC{ComplexF64,Int}
    network_order::Vector{BusPhase}
    slack_order::Vector{BusPhase}
    all_order::Vector{BusPhase}
    network_index::Dict{BusPhase,Int}
    all_index::Dict{BusPhase,Int}
    available_phases::Dict{String,Vector{Int}}
    YL::SparseMatrixCSC{ComplexF64,Int}
end

"""
    NoLoadResult(slack, w, phase_voltages)

No-load voltage solution: the fixed `slack` voltages, the solved network voltages
`w`, and all of them keyed by `BusPhase` in `phase_voltages`.
"""
struct NoLoadResult
    slack::Vector{ComplexF64}
    w::Vector{ComplexF64}
    phase_voltages::Dict{BusPhase,ComplexF64}
end

struct LoadContribution
    connection::Symbol
    mode::Symbol
    node_pairs::Vector{NTuple{2,Int}}
    values::Vector{ComplexF64}
    nominal_magnitudes::Vector{Float64}
    vminpu::Vector{Float64}
    vmaxpu::Vector{Float64}
    cvrwatts::Vector{Float64}
    cvrvars::Vector{Float64}
end

"""
    LoadModel(contributions, YL, summary)

Load model for the solver: nonlinear current-injection `contributions`, constant-impedance
admittances `YL`, and a `summary` count of loads by type.
"""
struct LoadModel
    contributions::Vector{LoadContribution}
    YL::SparseMatrixCSC{ComplexF64,Int}
    summary::Dict{Symbol,Int}
end

"""
    PowerFlowResult(...)

Power-flow solution.

- `iterations`, `converged`: Iteration count and whether the tolerance was met
- `voltages`: Complex voltages in `all_order` (network then slack nodes)
- `phase_voltages`: The same voltages keyed by `BusPhase`
- `magnitudes`, `angles_deg`: Magnitude and angle of `voltages`
- `history`: Residual (∞-norm) after each iteration
"""
struct PowerFlowResult
    iterations::Int
    converged::Bool
    voltages::Vector{ComplexF64}
    phase_voltages::Dict{BusPhase,ComplexF64}
    magnitudes::Vector{Float64}
    angles_deg::Vector{Float64}
    history::Vector{Float64}
end

"""
    AnalysisBundle(network, ybus, noload, loads, result)

Everything produced by a solve: the parsed `network`, the `ybus`, the `noload`
solution, the `loads` model, and the power-flow `result`.

`result` uses one system-wide per-unit base. `normalized_result` holds the same
voltages on each bus's local base, or is `nothing` if not computed; use
`get_normalized_result` to read whichever is available.
"""
struct AnalysisBundle
    network::NetworkModel
    ybus::YBusModel
    noload::NoLoadResult
    loads::LoadModel
    result::PowerFlowResult
    normalized_result::Union{PowerFlowResult,Nothing}
end

function AnalysisBundle(network, ybus, noload, loads, result)
    AnalysisBundle(network, ybus, noload, loads, result, nothing)
end
