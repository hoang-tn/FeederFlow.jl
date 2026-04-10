function matlab_export_reference(root_dir, feeder, out_path)
root_dir = char(root_dir);
feeder = lower(char(feeder));
out_path = char(out_path);

old_dir = pwd;
cleanup_obj = onCleanup(@() cd(old_dir)); %#ok<NASGU>

switch feeder
    case 'ieee37'
        feeder_dir = fullfile(root_dir, 'three-phase-modeling', 'IEEE 37-bus feeder');
        cd(feeder_dir);
        network = setupYbusIEEE37('non-ideal', 1e-6);
        network = computeNoLoadVoltage(network, [1;1;1], [0;-120;120]);
        network = setupLoadsIEEE37(network);
        network = performZBus(network, 10);
        network = obtainVoltages(network);
        fixture = build_fixture(network, feeder);
    case 'ieee123'
        feeder_dir = fullfile(root_dir, 'three-phase-modeling', 'IEEE 123-bus feeder');
        cd(feeder_dir);
        network = setupYbusIEEE123('non-ideal', 1e-6);
        network = computeNoLoadVoltage(network, [1;1;1], [0;-120;120]);
        network = setupLoadsIEEE123(network);
        network = performZBus(network, 10);
        network = obtainVoltages(network);
        fixture = build_fixture(network, feeder);
    otherwise
        error('Unsupported feeder "%s"', feeder);
end

json_text = jsonencode(fixture, PrettyPrint=true);
fid = fopen(out_path, 'w');
if fid == -1
    error('Could not open "%s" for writing.', out_path);
end
fwrite(fid, json_text, 'char');
fclose(fid);
end

function fixture = build_fixture(network, feeder)
available = network.availableBusIndices(:);
network_indices = available(1:end-3);
slack_indices = available(end-2:end);
all_indices = available;

fixture = struct();
fixture.feeder = feeder;
fixture.network_order = index_keys(network.busNames, network_indices);
fixture.slack_order = index_keys(network.busNames, slack_indices);
fixture.all_order = index_keys(network.busNames, all_indices);
fixture.y = sparse_fixture(network.Y);
fixture.y_ns = sparse_fixture(network.Y_NS);
fixture.y_ss = sparse_fixture(network.Y_SS);
fixture.yl = sparse_fixture(network.loadQuantities.YL);
fixture.noload_phase_voltages = complex_map_fixture(fixture.all_order, [network.noLoadQuantities.w; network.noLoadQuantities.v0]);
fixture.final_phase_voltages = final_voltage_fixture(network);
fixture.converged = logical(network.ZBusResults.success);
fixture.residual_history = network.ZBusResults.err(:).';
end

function keys = index_keys(bus_names, indices)
keys = cell(1, numel(indices));
for kk = 1:numel(indices)
    linear = indices(kk);
    bus_idx = floor((linear - 1) / 3) + 1;
    phase = mod(linear - 1, 3) + 1;
    keys{kk} = sprintf('%s.%d', lower(bus_names{bus_idx}), phase);
end
end

function fixture = sparse_fixture(matrix)
[rows, cols, values] = find(matrix);
if isempty(rows)
    fixture = struct('size', size(matrix), 'row', zeros(1, 0), 'col', zeros(1, 0), 're', zeros(1, 0), 'im', zeros(1, 0));
    return;
end
order = sortrows([(1:numel(rows)).', rows(:), cols(:)], [2 3]);
perm = order(:, 1);
fixture = struct();
fixture.size = size(matrix);
fixture.row = reshape(rows(perm), 1, []);
fixture.col = reshape(cols(perm), 1, []);
fixture.re = reshape(real(values(perm)), 1, []);
fixture.im = reshape(imag(values(perm)), 1, []);
end

function fixture = complex_map_fixture(keys, values)
fixture = struct();
for kk = 1:numel(keys)
    field = matlab.lang.makeValidName(strrep(keys{kk}, '.', '__'));
    fixture.(field) = struct('original_key', keys{kk}, 're', real(values(kk)), 'im', imag(values(kk)));
end
end

function fixture = final_voltage_fixture(network)
fixture = struct();
bus_names = network.busNames(:);
v3phase = network.solution.v3phase;
for kk = 1:numel(bus_names)
    for phase = 1:3
        value = v3phase(kk, phase);
        if ~isnan(value)
            key = sprintf('%s.%d', lower(bus_names{kk}), phase);
            field = matlab.lang.makeValidName(strrep(key, '.', '__'));
            fixture.(field) = struct('original_key', key, 're', real(value), 'im', imag(value));
        end
    end
end

reg_names = setdiff(lower(network.busNamesWithRegs(:)), lower(network.busNames(:)), 'stable');
for kk = 1:numel(reg_names)
    for phase = 1:3
        value = network.solution.v3phaseRegs(kk, phase);
        if ~isnan(value)
            key = sprintf('%s.%d', reg_names{kk}, phase);
            field = matlab.lang.makeValidName(strrep(key, '.', '__'));
            fixture.(field) = struct('original_key', key, 're', real(value), 'im', imag(value));
        end
    end
end
end
