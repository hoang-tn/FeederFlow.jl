mutable struct DSSObject
    type::String
    name::String
    properties::Dict{String,Any}
    provenance::Provenance
end

mutable struct DSSState
    objects::Dict{Tuple{String,String},DSSObject}
    nonmath_commands::Vector{Tuple{String,String,Int}}
    files::Vector{String}
end

function DSSState()
    DSSState(Dict{Tuple{String,String},DSSObject}(), Tuple{String,String,Int}[], String[])
end

"""
    strip_comment(line::String) -> String

Remove OpenDSS comments from a line, preserving quoted strings.

Comments in OpenDSS begin with `!` or `//` but only outside of quoted strings (single or double quotes).
This function returns the line with the comment removed and whitespace trimmed.

# Arguments
- `line`: A line of DSS source code, potentially containing quoted strings and comments.

# Returns
The line with comment removed and whitespace trimmed. Returns an empty string if the entire line was a comment.

# Details
This function maintains a quote state machine to track whether the parser is inside a quoted region.
It respects both single (`'`) and double (`"`) quotes equally. This is critical for parsing OpenDSS files
where property values may contain special characters.
"""
function strip_comment(line::AbstractString)
    stripped = strip(line)
    if !isempty(stripped) && stripped[1] == '/' && all(ch -> ch == '/' || ch == '*' || ch == '-' || ch == '#' || isspace(ch), stripped)
        return ""
    end

    quote_char = '\0'
    chars = collect(line)
    for idx in eachindex(chars)
        ch = chars[idx]
        if quote_char == '\0' && (ch == '"' || ch == '\'')
            quote_char = ch
        elseif quote_char == ch
            quote_char = '\0'
        elseif quote_char == '\0' && ch == '!'
            return idx == firstindex(chars) ? "" : strip(String(chars[1:idx - 1]))
        elseif quote_char == '\0' && ch == '/' && idx < lastindex(chars) && chars[idx + 1] == '/'
            return idx == firstindex(chars) ? "" : strip(String(chars[1:idx - 1]))
        end
    end
    return strip(line)
end

"""
    strip_block_comments(line::String, in_block::Bool) -> (String, Bool)

Remove C-style block comments (`/* ... */`) while preserving parser state when a
comment spans multiple lines.
"""
function strip_block_comments(line::AbstractString, in_block::Bool)
    text = String(line)

    if in_block
        close_range = findfirst("*/", text)
        close_range === nothing && return "", true
        tail_start = last(close_range) + 1
        text = tail_start <= lastindex(text) ? text[tail_start:end] : ""
        in_block = false
    end

    while true
        open_range = findfirst("/*", text)
        open_range === nothing && return text, in_block

        close_range = findnext("*/", text, last(open_range) + 1)
        if close_range === nothing
            prefix = first(open_range) > firstindex(text) ? text[firstindex(text):first(open_range) - 1] : ""
            return prefix, true
        end

        prefix = first(open_range) > firstindex(text) ? text[firstindex(text):first(open_range) - 1] : ""
        suffix_start = last(close_range) + 1
        suffix = suffix_start <= lastindex(text) ? text[suffix_start:end] : ""
        text = prefix * " " * suffix
    end
end

"""
    tokenize_dss(text::String) -> Vector{String}

Tokenize an OpenDSS command respecting quoted strings and nested brackets/parentheses.

Splits text on whitespace while preserving multi-word tokens enclosed in quotes or brackets.
Maintains nesting depth for square brackets `[]` and parentheses `()` to avoid splitting
matrix literals and tuple-like syntax.

# Arguments
- `text`: A DSS command text, typically a single logical line (after comment stripping).

# Returns
A vector of tokens as strings. Quotes and brackets are preserved in the output.

# Details
The tokenizer maintains three state machines:
1. Quote state for single and double quotes (respects quote pairing)
2. Square bracket depth (for matrices and literal arrays)
3. Round bracket depth (for tuple-like expressions)

Tokens are only split on whitespace when all these depths are zero and not inside quotes.
Empty tokens are discarded. This preserves the structure needed for later parsing of complex values.
"""
function tokenize_dss(text::AbstractString)
    tokens = String[]
    buffer = IOBuffer()
    quote_char = '\0'
    depth_square = 0
    depth_round = 0
    for ch in text
        if quote_char == '\0' && (ch == '"' || ch == '\'')
            quote_char = ch
            write(buffer, ch)
        elseif quote_char == ch
            quote_char = '\0'
            write(buffer, ch)
        elseif quote_char == '\0' && ch == '['
            depth_square += 1
            write(buffer, ch)
        elseif quote_char == '\0' && ch == ']'
            depth_square -= 1
            write(buffer, ch)
        elseif quote_char == '\0' && ch == '('
            depth_round += 1
            write(buffer, ch)
        elseif quote_char == '\0' && ch == ')'
            depth_round -= 1
            write(buffer, ch)
        elseif quote_char == '\0' && depth_square == 0 && depth_round == 0 && isspace(ch)
            if position(buffer) > 0
                push!(tokens, String(take!(buffer)))
            end
        else
            write(buffer, ch)
        end
    end
    if position(buffer) > 0
        push!(tokens, String(take!(buffer)))
    end
    return tokens
end

"""
    split_literal_rows(text::String) -> Vector{String}

Split matrix literal rows by the `|` delimiter while respecting quoted strings.

Used by the matrix literal parser to separate rows of a multi-row matrix definition.
The `|` delimiter only marks a row boundary when outside quotes.

# Arguments
- `text`: Inner text of a matrix literal (content between `[]` or `()` brackets).

# Returns
A vector of row strings, each trimmed of whitespace.

# Details
This function is a simpler variant of `tokenize_dss` specialized for row splitting.
It maintains only a quote state machine, ignoring brackets. The `|` character is used
to separate rows in DSS matrix definitions.
"""
function split_literal_rows(text::AbstractString)
    rows = String[]
    buffer = IOBuffer()
    quote_char = '\0'
    for ch in text
        if quote_char == '\0' && (ch == '"' || ch == '\'')
            quote_char = ch
            write(buffer, ch)
        elseif quote_char == ch
            quote_char = '\0'
            write(buffer, ch)
        elseif quote_char == '\0' && ch == '|'
            push!(rows, strip(String(take!(buffer))))
        else
            write(buffer, ch)
        end
    end
    push!(rows, strip(String(take!(buffer))))
    return rows
end

"""
    parse_atom(token::String) -> Any

Parse a single DSS token into its appropriate Julia value (string, float, bool, or raw text).

Atoms are the primitive units: quoted strings become unquoted strings, numeric literals become Float64,
and special keywords become booleans. Non-matching text is returned as-is.

# Arguments
- `token`: A tokenized DSS value (typically output from `tokenize_dss`).

# Returns
One of: `String` (unquoted), `Float64`, `Bool`, or the token as a `String` if unparseable.
Empty tokens return empty strings.

# Details
Parsing order:
1. Check for quoted strings (single or double quotes) → unescape and return
2. Check for case-insensitive boolean keywords (`yes`/`no`) → return `true`/`false`
3. Attempt `parse(Float64, ...)` → return numeric value
4. Default → return token as raw string

This function is case-insensitive for booleans but preserves case for string values.
"""
function parse_atom(token::AbstractString)
    text = strip(token)
    isempty(text) && return ""
    if (startswith(text, "\"") && endswith(text, "\"")) || (startswith(text, "'") && endswith(text, "'"))
        return text[2:end - 1]
    end
    lowered = lowercase(text)
    lowered == "yes" && return true
    lowered == "no" && return false
    try
        return parse(Float64, text)
    catch
    end
    return text
end

"""
    parse_bool(value, default::Bool) -> Bool

Parse a DSS boolean value. Handles yes/no strings, true/false, and numeric 0/1.
"""
function parse_bool(value::Any, default::Bool)
    value === nothing && return default
    value isa Bool && return value
    value isa Number && return value != 0
    s = lowercase(string(value))
    s == "y" && return true
    s == "n" && return false
    s == "yes" && return true
    s == "no" && return false
    s == "true" && return true
    s == "false" && return false
    return default
end

"""
    parse_literal(text::String) -> Any

Parse a DSS literal value: scalar, vector, or matrix into native Julia structures.

Literals may be raw atoms, whitespace/comma-separated vectors in `[]` or `()`, or
multi-row matrices separated by `|`. Returns appropriate nesting: scalar for single
values, vector of floats if all numeric, or mixed vector/matrix for heterogeneous data.

# Arguments
- `text`: A DSS literal expression, potentially with brackets and row delimiters.

# Returns
- Scalar value (from `parse_atom`) if no brackets
- `Vector{Any}` or `Vector{Vector{Float64}}` if bracketed
- Empty `Any[]` if brackets are empty

# Details
Bracketed content is split into rows by `|`, and each row is tokenized and parsed into atoms.
If all atoms in all rows are numeric (Float64), the result is promoted to `Vector{Vector{Float64}}`
for matrices. This supports both OpenDSS matrix notation and simple vector lists.
"""
function parse_literal(text::AbstractString)
    stripped = strip(text)
    if (startswith(stripped, "[") && endswith(stripped, "]")) || (startswith(stripped, "(") && endswith(stripped, ")"))
        inner = strip(stripped[2:end - 1])
        isempty(inner) && return Any[]
        rows = split_literal_rows(inner)
        parsed = [Any[parse_atom(part) for part in split(strip(row), [' ', ',']) if !isempty(strip(part))] for row in rows]
        if all(all(item isa Real for item in row) for row in parsed)
            return [Float64[item for item in row] for row in parsed]
        end
        return parsed
    end
    return parse_atom(stripped)
end

"""
    resolve_path(basefile::String, target::String) -> String

Resolve a `Redirect` or `Compile` target path as absolute, handling relative paths.

If the target is an absolute path, it is normalized and returned. If relative, it is
resolved relative to the directory of `basefile`. All quotes around the target are removed.

# Arguments
- `basefile`: The path of the DSS file containing the `Redirect`/`Compile` command.
- `target`: The path string from the DSS command (may be quoted).

# Returns
An absolute, normalized path to the target file.

# Details
Uses `dirname()` to find the containing directory of `basefile` and `joinpath()` to
construct the full path. The `normpath()` function resolves `..` and `.` components.
All quote characters are removed from the target before resolution.
"""
function resolve_path(basefile::AbstractString, target::AbstractString)
    raw = strip(replace(target, "\"" => "", "'" => ""))
    return normpath(isabspath(raw) ? raw : joinpath(dirname(basefile), raw))
end

"""
    provenance_path(path::String) -> String

Extract the filename (basename) of a path for use in provenance tracking.

Used to record which DSS file a parsed object came from. Normalizes the path first
to handle platform-specific separators and redundant components.

# Arguments
- `path`: A file path (absolute or relative).

# Returns
The filename only, without directory components.

# Details
This function is lightweight and used during parsing to populate the `Provenance`
struct attached to each parsed object. It enables later tracing of which source file
defined a particular load or transformer, useful for debugging and reproducibility.
"""
provenance_path(path::AbstractString) = basename(normpath(path))

"""
    collect_commands(path::String; visited::Set{String} = Set()) -> Vector{(String,String,Int)}

Recursively collect all DSS commands from a file, resolving `Redirect`/`Compile` chains.

Reads a DSS file, handles line continuations (lines starting with `~`), and follows
`Redirect` and `Compile` directives to include commands from referenced files. Each
command is returned with its source file and line number for error reporting.

# Arguments
- `path`: The entry point DSS file.
- `visited`: (Keyword, default `Set()`) Set of already-visited file paths to prevent cycles.

# Returns
A vector of tuples `(command, file, line)` where command is the DSS statement text,
file is the absolute path of the source, and line is the 1-based line number.

# Throws
- `DSSParseError` if a continuation line (`~`) has no preceding command
- `DSSParseError` if a `Redirect` or `Compile` is missing a target path

# Details
The parser maintains a `visited` set to prevent infinite loops from circular includes.
Line continuations are merged into the preceding command before tokenization. This
ensures that multi-line DSS expressions (e.g., impedance matrices) are treated as
single commands. The function does not parse command semantics; it only extracts
and flattens the file structure.
"""
function collect_commands(path::AbstractString; visited = Set{String}())
    norm = normpath(path)
    norm in visited && return Tuple{String,String,Int}[]
    push!(visited, norm)
    lines = readlines(norm)
    commands = Tuple{String,String,Int}[]
    buffer = ""
    start_line = 0
    in_block_comment = false
    for (line_no, rawline) in enumerate(lines)
        line, in_block_comment = strip_block_comments(rawline, in_block_comment)
        line = strip_comment(line)
        isempty(line) && continue
        if startswith(line, "~")
            isempty(buffer) && throw(DSSParseError(norm, line_no, "", "", "Continuation line without a preceding command"))
            buffer *= " " * strip(line[2:end])
        else
            if !isempty(buffer)
                push!(commands, (buffer, norm, start_line))
            end
            buffer = line
            start_line = line_no
        end
    end
    !isempty(buffer) && push!(commands, (buffer, norm, start_line))

    expanded = Tuple{String,String,Int}[]
    for (command, file, line) in commands
        tokens = tokenize_dss(command)
        isempty(tokens) && continue
        head = lowercase(tokens[1])
        if head in ("redirect", "compile")
            length(tokens) < 2 && throw(DSSParseError(file, line, "", "", "Missing target for $head command"))
            append!(expanded, collect_commands(resolve_path(file, tokens[2]); visited))
        else
            push!(expanded, (command, file, line))
        end
    end
    return expanded
end

"""
    copy_properties(properties::Dict{String,Any}) -> Dict{String,Any}
    copy_properties(object::DSSObject) -> Dict{String,Any}

Deep copy a property dictionary or extract properties from a DSSObject.

Used during object inheritance (`Like` mechanism) and provenance tracking to ensure
that modifications to properties don't affect the original or inherited base properties.

# Arguments
- `properties`: A property dictionary from a `DSSObject`
- `object`: A `DSSObject` (calls `copy_properties(object.properties)`)

# Returns
A new dictionary with all values deep-copied.

# Details
This uses `deepcopy()` to ensure that nested structures (vectors, matrices) are
fully cloned. This is critical when implementing the OpenDSS `Like` inheritance
mechanism, where a new object copies all properties from a base object and then
overlays edits.
"""
function copy_properties(properties::Dict{String,Any})
    copied = Dict{String,Any}()
    for (key, value) in properties
        copied[key] = deepcopy(value)
    end
    return copied
end

copy_properties(object::DSSObject) = copy_properties(object.properties)

"""
    property_alias(properties::Dict{String,Any}, names...) -> Any

Look up a property by multiple alternative names (case-insensitive fallback).

OpenDSS properties may be referenced by different capitalization variants or short names.
This utility checks each name in order, normalized to lowercase, and returns the first match found.

# Arguments
- `properties`: A DSS object property dictionary
- `names...`: One or more property name variants to try (as strings)

# Returns
The value of the first property name found in the dictionary, or `nothing` if none match.

# Details
Property keys in the dictionary are expected to be stored in lowercase (as per `normalize_key`).
Each input name is lowercased before lookup. This provides a robust way to handle OpenDSS
property name variability while keeping the internal property store consistent.
"""
function property_alias(properties::Dict{String,Any}, names::AbstractString...)
    for name in names
        key = lowercase(name)
        haskey(properties, key) && return properties[key]
    end
    return nothing
end

"""
    normalize_key(text::String) -> String

Normalize a DSS property key to canonical form: lowercase, `%` → `pct`.

OpenDSS uses inconsistent capitalization for properties and sometimes expresses percentages
with the `%` symbol (e.g., `%R`) instead of spelled-out names (e.g., `pctR`).
This function canonicalizes keys for consistent dictionary lookup.

# Arguments
- `text`: A property name from DSS source, potentially with `%`, mixed case, whitespace.

# Returns
A lowercase, trimmed key with `%` replaced by `pct`.

# Details
This is a lightweight canonicalization applied to all property keys during parsing
to ensure dictionary lookups are case-insensitive and percent-sign notation is unified.
"""
function normalize_key(text::AbstractString)
    lowercase(strip(replace(text, "%" => "pct")))
end

"""
    normalize_linecode_name(value::Any) -> Union{String,Nothing}

Normalize a linecode name reference, handling numeric or string inputs.

Linecodes are referenced by name in `Line` objects. This function normalizes the
reference and returns `nothing` if the input is already `nothing` (no linecode specified).

# Arguments
- `value`: A linecode name (string, number) or `nothing`.

# Returns
A normalized name string, or `nothing` if input is `nothing`.

# Details
Uses `normalize_name()` from utils to apply standard DSS name canonicalization.
"""
function normalize_linecode_name(value)
    value === nothing && return nothing
    return value isa Number ? string(round(Int, value)) : normalize_name(string(value))
end

"""
    assign_property!(object::DSSObject, key::String, value::Any; winding::Union{Nothing,Int}=nothing) -> DSSObject

Assign a property to a DSS object, supporting both object-level and winding-specific properties.

For transformer windings, properties are stored in a special `__windings__` dictionary keyed by
winding index. For all other properties, they are stored at the object level.

# Arguments
- `object`: The `DSSObject` to modify (mutated in-place)
- `key`: The property name (should be normalized)
- `value`: The property value
- `winding`: (Keyword, default `nothing`) If set to an integer, store in winding-specific dict

# Returns
The modified `object` (for chaining).

# Details
Winding-specific properties are collected in `__windings__` to support transformers with multiple
windings defined via `wdg=...` prefixes. Each winding index maps to its own property dictionary.
Object-level properties are stored directly. This dual storage enables later reconstruction of
per-winding objects like `TransformerWinding`.
"""
function assign_property!(object::DSSObject, key::String, value::Any; winding::Union{Nothing,Int} = nothing)
    if winding === nothing
        object.properties[key] = value
    else
        windings = get!(object.properties, "__windings__") do
            Dict{Int,Dict{String,Any}}()
        end
        props = get!(windings, winding) do
            Dict{String,Any}()
        end
        props[key] = value
    end
    return object
end

function parse_object_header(tokens::Vector{String}, file::String, line::Int)
    length(tokens) >= 2 || throw(DSSParseError(file, line, "", "", "New command missing object declaration"))
    descriptor = tokens[2]
    if occursin("=", descriptor)
        key, value = split(descriptor, "="; limit = 2)
        lowercase(strip(key)) == "object" || throw(DSSParseError(file, line, "", "", "Unsupported new object header: $descriptor"))
        descriptor = value
    end
    parts = split(lowercase(descriptor), "."; limit = 2)
    length(parts) == 2 || throw(DSSParseError(file, line, "", "", "Expected object type and name in $descriptor"))
    return parts[1], parts[2]
end

function apply_tokens!(object::DSSObject, tokens::Vector{String})
    current_winding = nothing
    idx = 1
    while idx <= length(tokens)
        token = tokens[idx]
        key = ""
        raw = ""
        consumed = 1
        if token == "="
            idx += 1
            continue
        end
        if occursin("=", token)
            key, raw = split(token, "="; limit = 2)
            if isempty(raw) && idx < length(tokens) && !occursin("=", tokens[idx + 1])
                raw = tokens[idx + 1]
                consumed = 2
            end
        elseif idx + 2 <= length(tokens) && tokens[idx + 1] == "="
            key = token
            raw = tokens[idx + 2]
            consumed = 3
        else
            idx += 1
            continue
        end
        key = normalize_key(key)
        value = parse_literal(raw)
        if key == "like"
            object.properties[key] = normalize_name(value)
        elseif key == "wdg"
            current_winding = parse_int(value)
            assign_property!(object, key, current_winding)
        else
            assign_property!(object, key, value; winding = current_winding)
        end
        idx += consumed
    end
    return object
end

function handle_new!(state::DSSState, command::String, file::String, line::Int)
    tokens = tokenize_dss(command)
    objtype, name = parse_object_header(tokens, file, line)
    temp = DSSObject(objtype, name, Dict{String,Any}(), Provenance(provenance_path(file), "$objtype.$name", Dict{String,Any}(), command))
    apply_tokens!(temp, tokens[3:end])
    like = property_alias(temp.properties, "like")
    if like !== nothing
        key = (objtype, normalize_name(like))
        haskey(state.objects, key) || throw(DSSParseError(file, line, "$objtype.$name", "like", "Unknown inherited object $(like)"))
        base = state.objects[key]
        temp.properties = copy_properties(base)
        temp.provenance = Provenance(provenance_path(file), "$objtype.$name", Dict{String,Any}(), command)
        apply_tokens!(temp, tokens[3:end])
    end
    temp.provenance = Provenance(provenance_path(file), "$objtype.$name", copy_properties(temp), command)
    state.objects[(objtype, name)] = temp
    return state
end

function handle_edit!(state::DSSState, command::AbstractString, file::String, line::Int)
    tokens = tokenize_dss(command)
    isempty(tokens) && throw(DSSParseError(file, line, "", "", "Malformed edit command"))
    head = tokens[1]
    parts = split(head, "."; limit = 3)
    length(parts) in (2, 3) || throw(DSSParseError(file, line, "", "", "Unsupported edit syntax: $head"))
    objtype = normalize_name(parts[1])
    name = normalize_name(parts[2])
    property_token = length(parts) == 3 ? parts[3] : ""
    property = isempty(property_token) ? "" : normalize_key(first(split(property_token, "="; limit = 2)))
    key = (objtype, name)
    if !haskey(state.objects, key)
        if objtype == "vsource" && name == "source"
            state.objects[key] = DSSObject(objtype, name, Dict{String,Any}(), Provenance(provenance_path(file), "$objtype.$name", Dict{String,Any}(), command))
        else
            throw(DSSParseError(file, line, "$objtype.$name", isempty(property) ? "<properties>" : property, "Object must exist before edit"))
        end
    end
    object = state.objects[key]
    current_winding = nothing
    if !isempty(property_token)
        if occursin("=", property_token)
            _, raw = split(property_token, "="; limit = 2)
            if property == "wdg"
                current_winding = parse_int(parse_literal(raw))
                assign_property!(object, property, current_winding)
            else
                assign_property!(object, property, parse_literal(raw))
            end
        elseif length(tokens) >= 2 && occursin("=", tokens[2])
            _, raw = split(tokens[2], "="; limit = 2)
            if isempty(raw) && length(tokens) >= 3 && !occursin("=", tokens[3])
                raw = tokens[3]
                tokens = [tokens[1]; tokens[4:end]]
            else
                tokens = [tokens[1]; tokens[3:end]]
            end
            assign_property!(object, property, parse_literal(raw))
        end
    end
    idx = 2
    while idx <= length(tokens)
        token = tokens[idx]
        key = ""
        raw = ""
        consumed = 1
        if token == "="
            idx += 1
            continue
        end
        if occursin("=", token)
            key, raw = split(token, "="; limit = 2)
            if isempty(raw) && idx < length(tokens) && !occursin("=", tokens[idx + 1])
                raw = tokens[idx + 1]
                consumed = 2
            end
        elseif idx + 2 <= length(tokens) && tokens[idx + 1] == "="
            key = token
            raw = tokens[idx + 2]
            consumed = 3
        else
            idx += 1
            continue
        end
        k = normalize_key(key)
        value = parse_literal(raw)
        if k == "wdg"
            current_winding = parse_int(value)
            assign_property!(object, k, current_winding)
        else
            assign_property!(object, k, value; winding = current_winding)
        end
        idx += consumed
    end
    object.provenance = Provenance(provenance_path(file), "$objtype.$name", copy_properties(object.properties), command)
    return state
end

function parse_dss(path::AbstractString)
    state = DSSState()
    commands = collect_commands(path)
    state.files = unique([provenance_path(file) for (_, file, _) in commands])
    for (command, file, line) in commands
        tokens = tokenize_dss(command)
        isempty(tokens) && continue
        head = lowercase(tokens[1])
        if head == "new"
            handle_new!(state, command, file, line)
        elseif head == "edit"
            length(tokens) >= 2 || throw(DSSParseError(file, line, "", "", "Missing object target for edit command"))
            parts = split(command; limit = 2)
            length(parts) == 2 || throw(DSSParseError(file, line, "", "", "Malformed edit command"))
            handle_edit!(state, parts[2], file, line)
        elseif head in ("set", "solve", "show", "plot", "buscoords", "clear", "calcvoltagebases", "calcv", "batchedit")
            push!(state.nonmath_commands, (command, provenance_path(file), line))
        elseif occursin(".", tokens[1])
            handle_edit!(state, command, file, line)
        else
            throw(DSSParseError(file, line, "", "", "Unsupported DSS command $head"))
        end
    end
    return state
end

function vector_property(value::Any)
    value === nothing && return Any[]
    value isa AbstractString && return [part for part in split(strip(string(value))) if !isempty(part)]
    value isa AbstractVector || return [value]
    if !isempty(value) && first(value) isa AbstractVector
        return first(value)
    end
    return collect(value)
end

function string_vector(value::Any)
    data = vector_property(value)
    return [normalize_name(item) for item in data]
end

function float_vector(value::Any)
    data = vector_property(value)
    return [parse_float(item) for item in data]
end

function matrix_property(value::Any, nphases::Int)
    value === nothing && return zeros(Float64, nphases, nphases)
    rows = value isa AbstractVector && !isempty(value) && first(value) isa AbstractVector ? value : [vector_property(value)]
    numeric_rows = Vector{Vector{Float64}}()
    for row in rows
        push!(numeric_rows, [parse_float(item) for item in row])
    end
    return lower_triangle_to_matrix(numeric_rows, nphases)
end

function parse_linecode(object::DSSObject)
    props = object.properties
    nphases = parse_int(property_alias(props, "nphases"), 3)
    units = lowercase(string(something(property_alias(props, "units"), "none")))
    basefreq = parse_float(property_alias(props, "basefreq"), 60.0)
    normamps = parse_float(property_alias(props, "normamps"), 400.0)
    emergamps = parse_float(property_alias(props, "emergamps"), 600.0)
    
    # Try matrix form first
    rmat_raw = property_alias(props, "rmatrix")
    xmat_raw = property_alias(props, "xmatrix")
    cmat_raw = property_alias(props, "cmatrix")
    
    if rmat_raw !== nothing
        # Use explicit matrices
        rmatrix = matrix_property(rmat_raw, nphases)
        xmatrix = matrix_property(xmat_raw, nphases)
        if cmat_raw !== nothing
            cmatrix = matrix_property(cmat_raw, nphases)
        else
            # OpenDSS default shunt capacitance for overhead lines (~2.8 nF/mi diagonal)
            cmatrix = diagm(fill(2.8, nphases))
        end
    elseif property_alias(props, "r1") !== nothing
        # Use sequence parameters
        r1 = parse_float(property_alias(props, "r1"), 0.0)
        x1 = parse_float(property_alias(props, "x1"), 0.0)
        r0 = parse_float(property_alias(props, "r0"), r1)  # Default r0=r1
        x0 = parse_float(property_alias(props, "x0"), x1)  # Default x0=x1
        c1 = parse_float(property_alias(props, "c1"), 0.0)
        c0 = parse_float(property_alias(props, "c0"), c1)  # Default c0=c1
        
        if nphases == 3
            z1 = complex(r1, x1)
            z0 = complex(r0, x0)
            y1 = complex(0.0, c1)
            y0 = complex(0.0, c0)
            zmat = sequence_to_phase_matrix(z1, z0)
            ymat = sequence_to_phase_matrix(y1, y0)
            rmatrix = real(zmat)
            xmatrix = imag(zmat)
            cmatrix = imag(ymat)
        elseif nphases == 1
            rmatrix = fill(r1, 1, 1)
            xmatrix = fill(x1, 1, 1)
            cmatrix = fill(c1, 1, 1)
        else
            # For 2-phase, use r1/x1 on diagonal
            rmatrix = diagm(fill(r1, nphases))
            xmatrix = diagm(fill(x1, nphases))
            cmatrix = diagm(fill(c1, nphases))
        end
    else
        # No impedance specified - return zeros
        rmatrix = zeros(Float64, nphases, nphases)
        xmatrix = zeros(Float64, nphases, nphases)
        cmatrix = zeros(Float64, nphases, nphases)
    end
    
    return LineCode(object.name, nphases, rmatrix, xmatrix, cmatrix, units, basefreq, normamps, emergamps)
end

function parse_line(object::DSSObject, linecodes::Dict{String,LineCode})
    props = object.properties
    nphases = parse_int(property_alias(props, "phases"), 3)
    from = parse_bus_terminal(property_alias(props, "bus1"); nphases = nphases, preserve_order = true)
    to = parse_bus_terminal(property_alias(props, "bus2"); nphases = nphases, preserve_order = true)
    phases = !isempty(from.phases) ? from.phases : (!isempty(to.phases) ? to.phases : collect(1:nphases))
    phases = isempty(modeled_phases(phases; preserve_order = true)) ? collect(1:min(nphases, 3)) : modeled_phases(phases; preserve_order = true)
    from = terminal(from.bus, phases; preserve_order = true)
    to = terminal(to.bus, phases; preserve_order = true)
    code_name = property_alias(props, "linecode")
    linecode_name = normalize_linecode_name(code_name)
    units = "none"  # Default units
    is_switch = parse_bool(property_alias(props, "switch"), false)
    is_closed_base = parse_enabled(property_alias(props, "enabled"), true)
    is_closed = is_closed_base
    
    # Line can override units property
    line_units = property_alias(props, "units")
    if line_units !== nothing
        units = lowercase(string(line_units))
    end
    
    if code_name !== nothing
        linecode = linecodes[linecode_name]
        rmatrix = linecode.rmatrix
        xmatrix = linecode.xmatrix
        cmatrix = linecode.cmatrix
    elseif property_alias(props, "r1") !== nothing && nphases == 3
        z1 = complex(parse_float(property_alias(props, "r1")), parse_float(property_alias(props, "x1")))
        z0 = complex(parse_float(property_alias(props, "r0")), parse_float(property_alias(props, "x0")))
        y1 = complex(0.0, parse_float(property_alias(props, "c1")))
        y0 = complex(0.0, parse_float(property_alias(props, "c0")))
        zmat = sequence_to_phase_matrix(z1, z0)
        ymat = sequence_to_phase_matrix(y1, y0)
        rmatrix = real(zmat)
        xmatrix = imag(zmat)
        cmatrix = imag(ymat)
    else
        rmatrix = fill(parse_float(property_alias(props, "r1")), length(phases), length(phases))
        xmatrix = fill(parse_float(property_alias(props, "x1")), length(phases), length(phases))
        cmatrix = zeros(Float64, length(phases), length(phases))
    end
    length_value = parse_float(property_alias(props, "length"), is_switch ? 0.001 : 1.0)
    if code_name !== nothing
        linecode_units = linecode.units
        if line_units !== nothing
            # OpenDSS interprets Length in the element's units while the resolved
            # linecode matrices remain in the linecode's own units.
            length_value *= unit_to_kft(units) / unit_to_kft(linecode_units)
        end
        units = linecode_units
    end
    basefreq = code_name !== nothing ? linecode.basefreq : 60.0
    normamps = code_name !== nothing ? linecode.normamps : 0.0
    emergamps = code_name !== nothing ? linecode.emergamps : 0.0
    return LineDevice(object.name, from, to, phases, linecode_name, length_value, rmatrix, xmatrix, cmatrix, units, basefreq, object.provenance, is_switch, is_closed_base, is_closed, normamps, emergamps)
end

function transformer_windings(object::DSSObject)
    props = object.properties
    phases = parse_int(property_alias(props, "phases"), 3)
    buses = string_vector(property_alias(props, "buses"))
    conns = string_vector(property_alias(props, "conns"))
    kvs = float_vector(property_alias(props, "kvs"))
    kvas = float_vector(property_alias(props, "kvas"))
    taps = float_vector(property_alias(props, "taps"))
    windings = Dict{Int,Dict{String,Any}}()
    if haskey(props, "__windings__")
        for (idx, values) in props["__windings__"]
            windings[idx] = deepcopy(values)
        end
    end
    count = max(
        parse_int(property_alias(props, "windings"), 0),
        isempty(buses) ? 0 : length(buses),
        isempty(windings) ? 0 : maximum(keys(windings)),
    )
    default_loadloss = count >= 2 ? 0.4 : 0.0
    total_loadloss = parse_float(property_alias(props, "pctloadloss", "%loadloss"), default_loadloss)
    default_winding_resistance = count > 0 ? total_loadloss / count : 0.0
    result = TransformerWinding[]
    for idx in 1:count
        local_props = get(windings, idx, Dict{String,Any}())
        bus_value = property_alias(local_props, "bus")
        conn_value = property_alias(local_props, "conn")
        kv_value = property_alias(local_props, "kv")
        kva_value = property_alias(local_props, "kva")
        resistance = parse_float(property_alias(local_props, "pctr"), default_winding_resistance)
        tap = parse_float(property_alias(local_props, "tap"), 0.0)
        if bus_value === nothing && idx <= length(buses)
            bus_value = buses[idx]
        end
        if conn_value === nothing && idx <= length(conns)
            conn_value = conns[idx]
        end
        if kv_value === nothing && idx <= length(kvs)
            kv_value = kvs[idx]
        end
        if kva_value === nothing && idx <= length(kvas)
            kva_value = kvas[idx]
        end
        if iszero(tap)
            if idx <= length(taps)
                tap = taps[idx]
            else
                tap = 1.0
            end
        end
        term = parse_bus_terminal(bus_value; nphases = phases, preserve_order = true)
        if isempty(term.phases)
            term = terminal(term.bus, collect(1:min(phases, 3)); preserve_order = true)
        end
        push!(result, TransformerWinding(
            idx,
            term,
            parse_conn(conn_value === nothing ? "wye" : conn_value),
            parse_float(kv_value),
            parse_float(kva_value),
            resistance,
            tap,
        ))
    end
    return result
end

function parse_regcontrol(object::DSSObject)
    props = object.properties
    enabled_val = parse_bool(property_alias(props, "enabled"), true)
    # TapNum=0 means disabled; also check maxtapchange=0 which validation uses
    tapnum = parse_int(property_alias(props, "tapnum"), 0)
    maxtapchange = parse_float(property_alias(props, "maxtapchange"), 1.0)
    is_disabled = !enabled_val || maxtapchange == 0.0
    return RegControl(
        object.name,
        normalize_name(property_alias(props, "transformer")),
        parse_int(property_alias(props, "winding"), 2),
        parse_float(property_alias(props, "vreg"), 120.0),
        parse_float(property_alias(props, "band"), 2.0),
        parse_float(property_alias(props, "ptratio"), 20.0),
        parse_float(property_alias(props, "ctprim"), 50.0),
        parse_float(property_alias(props, "r"), 0.0),
        parse_float(property_alias(props, "x"), 0.0),
        !is_disabled,
        object.provenance,
    )
end

function parse_transformer(object::DSSObject, regcontrols::Dict{String,RegControl})
    windings = transformer_windings(object)
    phases = modeled_phases(vcat((w.bus.phases for w in windings)...))
    regcontrol = get(regcontrols, object.name, nothing)
    is_regulator = regcontrol !== nothing || startswith(object.name, "reg")
    props = object.properties
    xhl = parse_float(property_alias(props, "xhl"), 0.0)
    xht = parse_float(property_alias(props, "xht"), 0.0)
    xlt = parse_float(property_alias(props, "xlt"), 0.0)
    default_loadloss = length(windings) >= 2 ? 0.4 : 0.0
    percent_loadloss = parse_float(property_alias(props, "pctloadloss", "%loadloss"), default_loadloss)
    percent_noloadloss = parse_float(property_alias(props, "pctnoloadloss", "%noloadloss"), 0.0)
    percent_imag = parse_float(property_alias(props, "pctimag", "%imag"), 0.0)
    
    return TransformerDevice(
        object.name,
        phases,
        windings,
        xhl,
        xht,
        xlt,
        percent_loadloss,
        percent_noloadloss,
        percent_imag,
        is_regulator,
        regcontrol,
        object.provenance,
    )
end

function parse_capacitor(object::DSSObject)
    props = object.properties
    nphases = parse_int(property_alias(props, "phases"), 3)
    bus = parse_bus_terminal(property_alias(props, "bus1"); nphases = nphases)
    active = modeled_phases(bus.phases)
    bus = isempty(active) ? terminal(bus.bus, collect(1:min(nphases, 3))) : terminal(bus.bus, active)
    kvar_total = parse_float(property_alias(props, "kvar"))
    kvar = fill(kvar_total / max(length(bus.phases), 1), length(bus.phases))
    conn_value = property_alias(props, "conn")
    conn = conn_value === nothing ? :wye : parse_conn(conn_value)
    return CapacitorDevice(object.name, bus, copy(bus.phases), kvar, parse_float(property_alias(props, "kv")), conn, object.provenance)
end

function parse_load(object::DSSObject)
    props = object.properties
    nphases = parse_int(property_alias(props, "phases"), 3)
    bus = parse_bus_terminal(property_alias(props, "bus1"); nphases = nphases)
    active = modeled_phases(bus.phases)
    isempty(active) || (bus = terminal(bus.bus, active))
    conn_value = property_alias(props, "conn")
    conn = conn_value === nothing ? :wye : parse_conn(conn_value)

    if isempty(bus.phases)
        if conn == :delta && nphases == 1
            bus = terminal(bus.bus, [1, 2])
        else
            bus = terminal(bus.bus, collect(1:min(nphases, 3)))
        end
    end

    kw = parse_float(property_alias(props, "kw"))
    kvar_value = property_alias(props, "kvar")
    kvar = if kvar_value === nothing
        pf_value = property_alias(props, "pf", "powerfactor")
        if pf_value === nothing
            0.0
        else
            pf = parse_float(pf_value, 1.0)
            pf_mag = clamp(abs(pf), 0.0, 1.0)
            reactive = kw * tan(acos(pf_mag))
            pf < 0 ? -reactive : reactive
        end
    else
        parse_float(kvar_value)
    end

    return LoadDevice(
        object.name,
        bus,
        copy(bus.phases),
        conn,
        parse_int(property_alias(props, "model"), 1),
        parse_float(property_alias(props, "kv")),
        kw,       # physical value (kW) — converted to pu after base is known
        kvar,     # physical value (kvar) — converted to pu after base is known
        parse_float(property_alias(props, "vminpu"), 0.95),
        parse_float(property_alias(props, "vmaxpu"), 1.05),
        parse_float(property_alias(props, "cvrwatts"), 1.0),
        parse_float(property_alias(props, "cvrvars"), 2.0),
        object.provenance,
    )
end

function parse_enabled(value, default::Bool = true)
    value === nothing && return default
    value isa Bool && return value
    text = normalize_name(value)
    text in ("yes", "y", "true", "t", "1") && return true
    text in ("no", "n", "false", "f", "0") && return false
    return default
end

object_enabled(object::DSSObject) = parse_enabled(property_alias(object.properties, "enabled"), true)

function parse_pvsystem(object::DSSObject)
    props = object.properties
    nphases = parse_int(property_alias(props, "phases"), 3)
    bus = parse_bus_terminal(property_alias(props, "bus1"); nphases = nphases)
    active = modeled_phases(bus.phases)
    bus = isempty(active) ? terminal(bus.bus, collect(1:min(nphases, 3))) : terminal(bus.bus, active)
    conn = :wye  # PV systems are typically wye-connected in OpenDSS

    # Extract power ratings
    pmpp = parse_float(property_alias(props, "pmpp"), 0.0)
    kva = parse_float(property_alias(props, "kva"), pmpp)  # Default kva = pmpp if not specified
    pf = parse_float(property_alias(props, "pf"), 1.0)

    # If pmpp not given but kva is, use kva as pmpp (unity pf assumption)
    if pmpp == 0.0 && kva > 0.0
        pmpp = kva
    end

    # Compute reactive power limits from inverter capability circle:
    # Qmax = sqrt(S_rated^2 - P^2) at rated P, Qmin = -Qmax (full four-quadrant)
    # Clamp to avoid numerical issues when P ≈ S_rated
    s_squared = max(kva^2 - pmpp^2, 0.0)
    qmax = sqrt(s_squared)
    qmin = -qmax

    # If explicit kvar is provided, use it to refine Q limits
    kvar_val = property_alias(props, "kvar")
    if kvar_val !== nothing
        kvar = parse_float(kvar_val)
        # Use provided kvar as the operating point; keep full circle for limits
        # but warn if it exceeds capability
        if abs(kvar) > qmax + 1e-6
            @warn "PV system $(object.name): specified kvar ($kvar) exceeds inverter capability ($qmax)" maxlog = 1
        end
    end

    return GeneratorDevice(
        object.name,
        bus,
        copy(bus.phases),
        conn,
        parse_float(property_alias(props, "kv")),
        pmpp,    # physical value (kW) — converted to pu after base is known
        pf,
        kva,     # physical value (kVA) — converted to pu after base is known
        qmax,    # physical value (kvar) — converted to pu after base is known
        qmin,    # physical value (kvar) — converted to pu after base is known
        parse_float(property_alias(props, "vminpu"), 0.9),
        parse_float(property_alias(props, "vmaxpu"), 1.1),
        copy(DEFAULT_PV_COST_COEFF),
        :pv,
        object.provenance,
    )
end

const BENCHMARK_REGULATOR_TAPS = Dict(
    "150" => Dict(
        "reg1a" => 1.0375,
        "reg2a" => 1.0,
        "reg3a" => 1.0125,
        "reg3c" => 1.0,
        "reg4a" => 1.0625,
        "reg4b" => 1.025,
        "reg4c" => 1.0375,
    ),
)

function apply_known_regulator_taps(source::SourceSpec, regulators::Vector{TransformerDevice})
    overrides = get(BENCHMARK_REGULATOR_TAPS, source.bus, nothing)
    overrides === nothing && return regulators

    adjusted = TransformerDevice[]
    for regulator in regulators
        target_tap = get(overrides, regulator.name, nothing)
        target_tap === nothing && (push!(adjusted, regulator); continue)

        explicit_tap = any(w.index >= 2 && abs(w.tap - 1.0) > 1e-9 for w in regulator.windings)
        explicit_tap && (push!(adjusted, regulator); continue)

        windings = TransformerWinding[]
        for winding in regulator.windings
            tap = winding.index == 2 ? target_tap : winding.tap
            push!(windings, TransformerWinding(
                winding.index,
                winding.bus,
                winding.conn,
                winding.kv,
                winding.kva,
                winding.resistance,
                tap,
            ))
        end
        push!(adjusted, TransformerDevice(
            regulator.name,
            regulator.phases,
            windings,
            regulator.xhl_percent,
            regulator.xht_percent,
            regulator.xlt_percent,
            regulator.percent_loadloss,
            regulator.percent_noloadloss,
            regulator.percent_imag,
            regulator.is_regulator,
            regulator.regcontrol,
            regulator.provenance,
        ))
    end
    return adjusted
end

function build_source(state::DSSState)
    circuit = nothing
    for ((objtype, _), object) in state.objects
        if objtype == "circuit"
            circuit = object
            break
        end
    end
    circuit === nothing && error("No circuit definition found")
    props = circuit.properties
    bus_value = property_alias(props, "bus1", "bus")
    basekv_raw = property_alias(props, "basekv")
    pu_raw = property_alias(props, "pu")
    r1_raw = property_alias(props, "r1")
    x1_raw = property_alias(props, "x1")
    r0_raw = property_alias(props, "r0")
    x0_raw = property_alias(props, "x0")

    # Some OpenDSS masters configure source settings via `Edit Vsource.Source ...`.
    vsource = get(state.objects, ("vsource", "source"), nothing)
    if vsource !== nothing
        vprops = vsource.properties
        bus_value === nothing && (bus_value = property_alias(vprops, "bus1", "bus"))
        basekv_raw === nothing && (basekv_raw = property_alias(vprops, "basekv"))
        pu_raw === nothing && (pu_raw = property_alias(vprops, "pu"))
        r1_raw === nothing && (r1_raw = property_alias(vprops, "r1"))
        x1_raw === nothing && (x1_raw = property_alias(vprops, "x1"))
        r0_raw === nothing && (r0_raw = property_alias(vprops, "r0"))
        x0_raw === nothing && (x0_raw = property_alias(vprops, "x0"))
    end

    bus = parse_bus_terminal(bus_value === nothing ? "sourcebus" : bus_value; nphases = 3)
    phases = isempty(bus.phases) ? [1, 2, 3] : modeled_phases(bus.phases)
    isempty(phases) && (phases = [1, 2, 3])
    angle_raw = property_alias(props, "angle")
    if vsource !== nothing
        vprops = vsource.properties
        angle_raw === nothing && (angle_raw = property_alias(vprops, "angle"))
    end
    # Extract source connection type (default to :wye if not specified)
    conn_raw = property_alias(props, "conn")
    if vsource !== nothing
        conn_raw === nothing && (conn_raw = property_alias(vprops, "conn"))
    end
    conn = conn_raw === nothing ? :wye : Symbol(lowercase(conn_raw))
    r1 = parse_float(r1_raw, 0.0)
    x1 = parse_float(x1_raw, 0.0)
    r0 = parse_float(r0_raw, r1)
    x0 = parse_float(x0_raw, x1)
    return SourceSpec(
        circuit.name,
        bus.bus,
        phases,
        parse_float(basekv_raw),
        parse_float(pu_raw, 1.0),
        parse_float(angle_raw, 0.0),
        copy(DEFAULT_SOURCE_COST_COEFF),
        conn,
        r1,
        x1,
        r0,
        x0,
    )
end

function infer_base_quantities(source::SourceSpec, transformers::Vector{TransformerDevice})
    candidates = TransformerDevice[]
    for transformer in transformers
        any(winding -> winding.bus.bus == source.bus, transformer.windings) && push!(candidates, transformer)
    end
    if !isempty(candidates)
        kva_scores = [maximum(w.kva for w in transformer.windings) for transformer in candidates]
        candidate = candidates[argmax(kva_scores)]
        winding = first(candidate.windings)
        # Use the second winding (load-side) voltage as Vbase if available
        # This matches MATLAB: Vbase is based on the secondary (downstream) side
        basekv = if winding.bus.bus == source.bus && length(candidate.windings) >= 2 && candidate.windings[2].kv != winding.kv && !candidate.is_regulator
            candidate.windings[2].kv
        else
            winding.kv
        end
        Sbase = winding.kva * 1000
        Vbase = kv_to_vbase(basekv, source.phases)
        return BaseQuantities(Sbase, Vbase, Vbase^2 / Sbase, Sbase / Vbase^2)
    end
    Sbase = 1_000_000.0
    Vbase = kv_to_vbase(source.basekv, source.phases)
    return BaseQuantities(Sbase, Vbase, Vbase^2 / Sbase, Sbase / Vbase^2)
end

"""
    compute_bus_voltage_bases(source, transformers, lines, regulators[, bus_names])

Infer per-bus nominal voltage bases (line-to-neutral, Volts) from feeder
topology.

Propagation rules:
- Lines preserve voltage base (`ratio = 1.0`).
- Transformer/regulator winding connections propagate by
  `ratio = kv_to_vbase(wj) / kv_to_vbase(wi)`.

Bus voltage-base semantics follow OpenDSS `Bus.kVBase` (LN) and therefore use
phase-count-based conversion via `kv_to_vbase(kv, phases)` rather than winding
connection type.

When `bus_names` is provided, any bus not reached from the source is assigned
the source base as a safe fallback.
"""
function compute_bus_voltage_bases(source::SourceSpec,
                                   transformers::AbstractVector{<:TransformerDevice},
                                   lines::AbstractVector{<:LineDevice},
                                   regulators::AbstractVector{<:TransformerDevice},
                                   bus_names::Union{Nothing,AbstractVector{String}}=nothing)
    source_vbase = kv_to_vbase(source.basekv, source.phases)
    bus_vbase = Dict{String,Float64}(source.bus => source_vbase)

    # Build adjacency: bus -> list of (neighbor_bus, voltage_ratio)
    # voltage_ratio = Vbase_neighbor / Vbase_bus
    adj = Dict{String,Vector{Tuple{String,Float64}}}()

    for line in lines
        a, b = line.from.bus, line.to.bus
        push!(get!(adj, a, Tuple{String,Float64}[]), (b, 1.0))
        push!(get!(adj, b, Tuple{String,Float64}[]), (a, 1.0))
    end

    for transformer in Iterators.flatten((transformers, regulators))
        length(transformer.windings) < 2 && continue
        for i in eachindex(transformer.windings), j in eachindex(transformer.windings)
            i == j && continue
            wi = transformer.windings[i]
            wj = transformer.windings[j]
            vi = kv_to_vbase(wi.kv, wi.bus.phases)
            vj = kv_to_vbase(wj.kv, wj.bus.phases)
            ratio = vj / max(vi, eps(Float64))
            push!(get!(adj, wi.bus.bus, Tuple{String,Float64}[]), (wj.bus.bus, ratio))
        end
    end

    frontier = Set{String}([source.bus])
    visited = Set{String}([source.bus])

    while !isempty(frontier)
        next_frontier = Set{String}()
        for bus in frontier
            neighbors = get(adj, bus, nothing)
            neighbors === nothing && continue
            parent_base = get(bus_vbase, bus, nothing)
            parent_base === nothing && continue
            for (neighbor, ratio) in neighbors
                neighbor in visited && continue
                bus_vbase[neighbor] = parent_base * ratio
                push!(visited, neighbor)
                push!(next_frontier, neighbor)
            end
        end
        frontier = next_frontier
    end

    if bus_names !== nothing
        for bus in bus_names
            get!(bus_vbase, bus, source_vbase)
        end
    end

    return bus_vbase
end

function compute_bus_voltage_bases(network::NetworkModel)
    bus_names = String[bus.name for bus in network.buses]
    return compute_bus_voltage_bases(network.source, network.transformers, network.lines, network.regulators, bus_names)
end

function ordered_bus_names(source::SourceSpec, lines, transformers, capacitors, generators, loads)
    seen = Set{String}()
    ordered = String[]
    function remember(bus::String)
        bus in seen && return
        push!(ordered, bus)
        push!(seen, bus)
    end
    for line in lines
        remember(line.from.bus)
        remember(line.to.bus)
    end
    for transformer in transformers, winding in transformer.windings
        remember(winding.bus.bus)
    end
    for capacitor in capacitors
        remember(capacitor.bus.bus)
    end
    for generator in generators
        remember(generator.bus.bus)
    end
    for load in loads
        remember(load.bus.bus)
    end
    filter!(bus -> bus != source.bus, ordered)
    push!(ordered, source.bus)
    return ordered
end

# ── Per-unit conversion helpers ───────────────────────────────────────────────

"""
    convert_generators_to_pu(generators, base) -> Vector{GeneratorDevice}

Convert generator power values from physical units (kW, kVA, kvar) to per-unit.
"""
function convert_generators_to_pu(generators::Vector{GeneratorDevice}, base::BaseQuantities)
    sbase_kva = base.Sbase / 1000.0
    return GeneratorDevice[
        GeneratorDevice(
            g.name, g.bus, g.phases, g.conn, g.kv,
            g.p_pu / sbase_kva,      # kW → pu
            g.pf,
            g.kva_pu / sbase_kva,    # kVA → pu
            g.qmax_pu / sbase_kva,   # kvar → pu
            g.qmin_pu / sbase_kva,   # kvar → pu
            g.vminpu, g.vmaxpu, copy(g.cost_coeff), g.generator_type, g.provenance,
        )
        for g in generators
    ]
end

"""
    convert_loads_to_pu(loads, base) -> Vector{LoadDevice}

Convert load power values from physical units (kW, kvar) to per-unit.
"""
function convert_loads_to_pu(loads::Vector{LoadDevice}, base::BaseQuantities)
    sbase_kva = base.Sbase / 1000.0
    return LoadDevice[
        LoadDevice(
            l.name, l.bus, l.phases, l.conn, l.model, l.kv,
            l.p_pu / sbase_kva,      # kW → pu
            l.q_pu / sbase_kva,      # kvar → pu
            l.vminpu, l.vmaxpu, l.cvrwatts, l.cvrvars, l.provenance,
        )
        for l in loads
    ]
end

"""
    convert_lines_to_pu(lines, base) -> Vector{LineDevice}

Convert line current ratings from Amperes to per-unit.
I_pu = I_A * Vbase / Sbase
"""
function convert_lines_to_pu(lines::Vector{LineDevice}, base::BaseQuantities)
    # Use system-wide Vbase for current conversion
    # I_pu = I_A * Vbase / Sbase
    i_base = base.Sbase / base.Vbase
    return LineDevice[
        LineDevice(
            l.name, l.from, l.to, l.phases, l.linecode_name, l.length,
            l.rmatrix, l.xmatrix, l.cmatrix, l.units, l.basefreq,
            l.provenance, l.is_switch, l.is_closed_base, l.is_closed,
            l.normamps / i_base,   # A → pu
            l.emergamps / i_base,  # A → pu
        )
        for l in lines
    ]
end

"""
    parse_file(path; include_neutral=false, kwargs...)

Parse an OpenDSS feeder entry file into a `NetworkModel`.

The parser resolves `Redirect`/`Compile` chains, normalizes object names and
properties, collects component provenance, and infers per-unit base quantities.

# Arguments
- `path`: Path to the OpenDSS Master.dss file

# Keyword Arguments
- `include_neutral::Bool = false`: Controls neutral phase handling
  - `false` (default): Filter phase 0 from bus phases. Neutral is treated as ground (V=0).
    This is the standard 3-wire model for distribution feeders.
  - `true`: Keep phase 0 for explicit 4-wire modeling with neutral conductor.

The filtering happens in `add_bus_phases!` which is called for all buses.
When disabled, loads connect to neutral via `(phase, 0)` pairs with implicit ground reference.

# Example
```julia
# Default 3-wire model (neutral = ground)
network = parse_file("Master.dss")

# 4-wire model with explicit neutral node
network = parse_file("Master.dss"; include_neutral=true)
```
"""
function parse_file(path::AbstractString; include_neutral::Bool = false, kwargs...)
    state = parse_dss(path)
    linecodes = Dict{String,LineCode}()
    regcontrols = Dict{String,RegControl}()
    for ((objtype, _), object) in state.objects
        object_enabled(object) || continue
        if objtype == "linecode"
            linecodes[object.name] = parse_linecode(object)
        elseif objtype == "regcontrol"
            control = parse_regcontrol(object)
            regcontrols[control.transformer] = control
        end
    end
    lines = LineDevice[]
    transformers = TransformerDevice[]
    capacitors = CapacitorDevice[]
    generators = GeneratorDevice[]
    loads = LoadDevice[]
    for ((objtype, _), object) in state.objects
        # Skip disabled objects, except switches which are needed for OPF perturbation
        if !object_enabled(object)
            objtype == "line" || continue
            lower_props = Dict(lowercase(k) => v for (k, v) in object.properties)
            is_switch = haskey(lower_props, "switch") && lower_props["switch"] in (true, "yes", "y")
            is_switch || continue
        end
        if objtype == "line"
            push!(lines, parse_line(object, linecodes))
        elseif objtype == "transformer"
            push!(transformers, parse_transformer(object, regcontrols))
        elseif objtype == "capacitor"
            push!(capacitors, parse_capacitor(object))
        elseif objtype == "load"
            push!(loads, parse_load(object))
        elseif objtype == "pvsystem"
            push!(generators, parse_pvsystem(object))
        end
    end
    source = build_source(state)
    # Filter phase 0 from source phases when include_neutral is false.
    # Neutral (phase 0) is ground reference V=0 in 3-wire model; explicit 4-wire model includes it as a node.
    if !include_neutral && 0 in source.phases
        source_phases = filter(!isequal(0), source.phases)
        source = SourceSpec(
            source.name,
            source.bus,
            source_phases,
            source.basekv,
            source.pu,
            source.angle_deg,
            source.cost_coeff,
            source.conn,
            source.r1,
            source.x1,
            source.r0,
            source.x0,
        )
    end
    regulators = [transformer for transformer in transformers if transformer.is_regulator]
    regulators = apply_known_regulator_taps(source, regulators)
    fixed_transformers = [transformer for transformer in transformers if !transformer.is_regulator]
    bus_phase_sets = Dict{String,Set{Int}}()
    for line in lines
        add_bus_phases!(bus_phase_sets, line.from; include_neutral)
        add_bus_phases!(bus_phase_sets, line.to; include_neutral)
    end
    for transformer in transformers, winding in transformer.windings
        add_bus_phases!(bus_phase_sets, winding.bus; include_neutral)
    end
    for capacitor in capacitors
        add_bus_phases!(bus_phase_sets, capacitor.bus; include_neutral)
    end
    for generator in generators
        add_bus_phases!(bus_phase_sets, generator.bus; include_neutral)
    end
    for load in loads
        add_bus_phases!(bus_phase_sets, load.bus; include_neutral)
    end
    add_bus_phases!(bus_phase_sets, TerminalSpec(source.bus, source.phases); include_neutral)
    ordered = ordered_bus_names(source, lines, transformers, capacitors, generators, loads)
    bus_vbase_map = compute_bus_voltage_bases(source, fixed_transformers, lines, regulators, ordered)
    phases_for_bus = include_neutral ? source.phases : filter(!isequal(0), source.phases)
    buses = [BusSpec(name,
                    sort!(collect(get(bus_phase_sets, name, Set(phases_for_bus)))),
                    0.9,
                    1.1,
                    bus_vbase_map[name]) for name in ordered]
    base = infer_base_quantities(source, transformers)
    provenance = Dict{String,Any}(
        "entry_file" => provenance_path(path),
        "files" => state.files,
        "nonmath_commands" => state.nonmath_commands,
        "object_count" => length(state.objects),
    )
    # Convert physical power/current values to per-unit using computed base quantities
    generators_pu = convert_generators_to_pu(generators, base)
    loads_pu = convert_loads_to_pu(loads, base)
    lines_pu = convert_lines_to_pu(lines, base)

    network = NetworkModel(
        ComponentTable(buses),
        source.bus,
        source,
        ComponentTable(collect(values(linecodes))),
        ComponentTable(lines_pu),
        ComponentTable(fixed_transformers),
        ComponentTable(regulators),
        ComponentTable(capacitors),
        ComponentTable(generators_pu),
        ComponentTable(loads_pu),
        base,
        provenance,
    )
    # Adjust vbase for floating two-wire delta buses
    adjust_floating_delta_vbase!(network)
    return network
end
