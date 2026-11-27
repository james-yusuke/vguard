module main

import json2
import os

struct NativeHistory {
	events       int
	trace_sha256 string
	graph_sha256 string
	truncated    bool
}

struct NativeHistoryState {
	evidence string = 'replayed_native_ssa_samples'
	event    int
	ssa      RuntimeSsaReport
}

fn record_native_history(bundle Bundle, scenario ExecutionCase, directory string) !string {
	if scenario.harness != '' || bundle.manifest.options.memory || bundle.manifest.options.trace_hangs || os.exists(directory) {
		return error('record --runtime-ssa requires a standalone executable and a new output directory')
	}
	validate_comparison_inputs(bundle)!
	baseline := run_for_comparison(bundle, scenario)!
	if baseline.status != 'exited' || baseline.exit_code != 0 {
		return error('record --runtime-ssa requires a successful baseline execution')
	}
	work := temp_directory()!
	defer { os.rmdir_all(work) or {} }
	manifest := build(BuildOptions{ ...bundle.manifest.options, trace_runtime: true }, os.join_path(work, 'instrumented'), false)!
	instrumented := open_bundle(manifest)!
	trace := os.join_path(work, 'native-ssa.bin')
	os.write_file(trace, '')!
	mut env := scenario.env.clone()
	env['VGUARD_SSA_TRACE_FILE'] = trace
	outcome := run_for_comparison(instrumented, ExecutionCase{ ...scenario, env: env })!
	if !same_outcome(baseline, outcome) {
		return error('the recorded native execution differs from the baseline')
	}
	raw := read_native_history_trace(trace)!
	graph := native_history_graph(instrumented)!
	history := ExecutionHistory{
		evidence:                     native_history_evidence
		build:                        compared_build(bundle.manifest)
		source_hash:                  bundle.manifest.source_sha256
		outcome:                      outcome
		instrumented_artifact_sha256: instrumented.artifact_sha256
		native:                       describe_native_history(raw, graph)!
	}
	os.mkdir(directory)!
	mut saved := false
	defer {
		if !saved {
			os.rmdir_all(directory) or {}
		}
	}
	os.write_file_array(os.join_path(directory, 'native-ssa.bin'), raw)!
	os.write_file_array(os.join_path(directory, 'native-ssa.graph.json'), graph)!
	path := os.join_path(directory, 'history.json')
	os.write_file(path, json2.encode(history) + '\n')!
	saved = true
	return path
}

fn native_history_graph(bundle Bundle) ![]u8 {
	path := bundle.ssa_path.trim_string_right('.ssa') + '.passes.jsonl.graph.json'
	if os.file_size(path) > u64(capture_limit * 4) {
		return error('oversized recorded native SSA graph')
	}
	graph := os.read_bytes(path)!
	if digest(graph) != bundle.manifest.ssa_graph_sha256 {
		return error('invalid recorded native SSA graph')
	}
	return graph
}

fn describe_native_history(raw []u8, graph []u8) !NativeHistory {
	events, truncated := decode_runtime_events(raw)!
	_ = runtime_event_root(events, -1)!
	return NativeHistory{
		events:       events.len
		trace_sha256: digest(raw)
		graph_sha256: digest(graph)
		truncated:    truncated
	}
}

fn read_native_history_trace(path string) ![]u8 {
	if os.file_size(path) > u64(runtime_record_size * (runtime_event_limit + 1)) {
		return error('the recorded native SSA trace exceeds its size limit')
	}
	return os.read_bytes(path)
}

fn replay_native_history(path string, history ExecutionHistory, event int) !NativeHistoryState {
	native := history.native or { return error('--at-event requires an execution recorded with --runtime-ssa') }
	if event < 1 || event > native.events {
		return error('--at-event is outside the recorded event range 1 to ${native.events}')
	}
	directory := os.dir(path)
	trace := read_native_history_trace(os.join_path(directory, 'native-ssa.bin'))!
	graph_path := os.join_path(directory, 'native-ssa.graph.json')
	if os.file_size(graph_path) > u64(capture_limit * 4) {
		return error('the recorded native SSA graph exceeds its size limit')
	}
	graph := os.read_bytes(graph_path)!
	if digest(trace) != native.trace_sha256 || digest(graph) != native.graph_sha256 {
		return error('native history files do not match their recorded SHA-256 digests')
	}
	events, truncated := decode_runtime_events(trace)!
	if events.len != native.events || truncated != native.truncated {
		return error('native history event count or limit marker does not match its metadata')
	}
	decoded := json2.decode[SsaGraph](graph.bytestr())!
	if decoded.version != 1 {
		return error('unsupported SSA graph version in execution history')
	}
	return NativeHistoryState{
		event: event
		ssa:   runtime_ssa_slice(decoded, events[..event], -1, event == events.len && truncated)!
	}
}
