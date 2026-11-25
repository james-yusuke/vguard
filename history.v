module main

import json2
import os
import strings

const scalar_history_evidence = 'instrumented_scalar_checkpoints'
const call_history_evidence = 'instrumented_function_entries_and_scalar_checkpoints'

struct ExecutionHistory {
	version     int    = 1
	evidence    string = scalar_history_evidence
	build       ComparedBuild
	source_hash string
	outcome     Outcome
	events      []TraceEvent
}

@[params]
struct RecordOptions {
	calls bool
}

fn record_history(bundle Bundle, scenario ExecutionCase, directory string, options RecordOptions) !string {
	if bundle.manifest.options.memory || scenario.harness != '' {
		return error('record requires a standalone build without sanitizer instrumentation')
	}
	validate_comparison_inputs(bundle)!
	baseline := run_for_comparison(bundle, scenario)!
	if baseline.status != 'exited' || baseline.exit_code != 0 {
		return error('record requires a successful baseline execution (${baseline.status}, ${baseline.exit_code})')
	}

	work := temp_directory()!
	defer {
		os.rmdir_all(work) or {}
	}
	traced_path := build(bundle.manifest.options, os.join_path(work, 'instrumented'), true,
		trace_calls: options.calls
	)!
	traced := run_for_comparison(open_bundle(traced_path)!, scenario)!
	stderr, events := split_trace(traced.stderr)!
	outcome := Outcome{ ...traced, stderr: stderr }
	if !same_outcome(baseline, outcome) {
		return error('the instrumented execution differs from the baseline execution')
	}
	if events.len == 0 {
		return error(if options.calls {
			'this execution produced no trace events'
		} else {
			'this execution produced no scalar checkpoints'
		})
	}
	if options.calls && !events.any(it.kind == 'function_enter') {
		return error('the instrumented execution produced no function entry events')
	}
	history := ExecutionHistory{
		evidence:    if options.calls { call_history_evidence } else { scalar_history_evidence }
		build:       compared_build(bundle.manifest)
		source_hash: bundle.manifest.source_sha256
		outcome:     outcome
		events:      events
	}
	encoded := json2.encode(history) + '\n'
	if encoded.len > capture_limit * 4 {
		return error('the execution history exceeds the 64 MiB replay limit')
	}
	os.mkdir(directory)!
	path := os.join_path(directory, 'history.json')
	os.write_file(path, encoded) or {
		os.rmdir_all(directory) or {}
		return err
	}
	return path
}

fn open_history(path string) !ExecutionHistory {
	if os.file_size(path) > u64(capture_limit * 4) {
		return error('the execution history exceeds the 64 MiB replay limit')
	}
	history := json2.decode[ExecutionHistory](os.read_file(path)!)!
	if history.version != 1 || history.evidence !in [scalar_history_evidence, call_history_evidence] {
		return error('unsupported execution history')
	}
	return history
}

fn format_history(history ExecutionHistory) string {
	mut out := strings.new_builder(1024)
	label := if history.evidence == call_history_evidence {
		'function entries and scalar checkpoints'
	} else {
		'scalar checkpoints'
	}
	out.writeln('Recorded ${label} (${history.build.backend}, ${history.build.target})')
	for i, event in history.events {
		out.writeln('  ${i + 1} ${json2.encode(event.file)}:${event.line}:${event.column} ${event.kind} = ${json2.encode(event.value)}')
	}
	return out.str()
}
