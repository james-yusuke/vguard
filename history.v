module main

import json2
import os
import strings

const scalar_history_evidence = 'instrumented_scalar_checkpoints'
const call_history_evidence = 'instrumented_function_entries_and_scalar_checkpoints'
const memory_history_evidence = 'instrumented_scalar_checkpoints_and_memory_accesses'
const call_memory_history_evidence = 'instrumented_function_entries_scalar_checkpoints_and_memory_accesses'
const native_history_evidence = 'recorded_native_ssa_events'

struct ReexecutionReport {
	kind               string
	evidence           string
	expected           Outcome
	actual             Outcome
	native_trace_match ?bool            @[omitempty]
	expected_binary    ?VmBinaryStreams @[omitempty]
	actual_binary      ?VmBinaryStreams @[omitempty]
	detail             string           @[omitempty]
}

struct ExecutionHistory {
	version                      int    = 1
	evidence                     string = scalar_history_evidence
	build                        ComparedBuild
	source_hash                  string
	outcome                      Outcome
	events                       []TraceEvent
	instrumented_artifact_sha256 string            @[omitempty]
	native                       ?NativeHistory    @[omitempty]
	wasi_stdio                   ?WasiStdioHistory @[omitempty]
	qemu_linux                   ?VmHistory        @[omitempty]
}

@[params]
struct RecordOptions {
	calls           bool
	memory_accesses bool
}

fn record_history(bundle Bundle, scenario ExecutionCase, directory string, options RecordOptions) !string {
	if bundle.manifest.options.memory || bundle.manifest.options.trace_hangs || scenario.harness != '' {
		return error('record requires a standalone build without other instrumentation')
	}
	mut build_options := bundle.manifest.options
	validate_comparison_inputs(bundle)!
	work := temp_directory()!
	defer {
		os.rmdir_all(work) or {}
	}
	if options.memory_accesses {
		build_options = memory_history_build_options(build_options, work)!
	}
	baseline := run_for_comparison(bundle, scenario)!
	if baseline.status != 'exited' || baseline.exit_code != 0 {
		return error('record requires a successful baseline execution (${baseline.status}, ${baseline.exit_code})')
	}
	traced_path := build(build_options, os.join_path(work, 'instrumented'), true,
		trace_calls: options.calls
	)!
	traced_bundle := open_bundle(traced_path)!
	traced := run_for_comparison(traced_bundle, scenario)!
	stderr, events := split_trace(traced.stderr, memory_accesses: options.memory_accesses)!
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
	if options.memory_accesses && !events.any(it.memory != none) {
		return error('the instrumented execution produced no memory access events')
	}
	evidence := if options.memory_accesses {
		if options.calls { call_memory_history_evidence } else { memory_history_evidence }
	} else if options.calls {
		call_history_evidence
	} else {
		scalar_history_evidence
	}
	history := ExecutionHistory{
		evidence:                     evidence
		build:                        compared_build(bundle.manifest)
		source_hash:                  bundle.manifest.source_sha256
		outcome:                      outcome
		events:                       events
		instrumented_artifact_sha256: if options.memory_accesses {
			traced_bundle.artifact_sha256
		} else {
			''
		}
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
	if history.version != 1 || history.evidence !in [scalar_history_evidence, call_history_evidence,
		memory_history_evidence, call_memory_history_evidence, native_history_evidence,
		wasi_stdio_history_evidence, vm_history_evidence]
		|| (history.evidence == native_history_evidence && history.native == none)
		|| (history.native != none && history.evidence !in [native_history_evidence,
			vm_history_evidence])
		|| (history.evidence == wasi_stdio_history_evidence) != (history.wasi_stdio != none)
		|| (history.evidence == vm_history_evidence) != (history.qemu_linux != none) {
		return error('unsupported execution history')
	}
	return history
}

fn format_history(history ExecutionHistory) string {
	if vm := history.qemu_linux {
		mut result := 'Recorded Linux VM (${history.build.backend}, linux/${vm.arch})\n'
		if native := history.native {
			result += 'Recorded ${native.events} native SSA events\n'
		}
		return result
	}
	if native := history.native {
		return 'Recorded ${native.events} native SSA events (${history.build.backend}, ${history.build.target})\n'
	}
	if history.wasi_stdio != none {
		return 'Recorded WASI stdio (${history.build.backend}, ${history.build.target})\n'
	}
	mut out := strings.new_builder(1024)
	label := match history.evidence {
		call_history_evidence { 'function entries and scalar checkpoints' }
		memory_history_evidence { 'scalar checkpoints and memory accesses' }
		call_memory_history_evidence { 'function entries, scalar checkpoints and memory accesses' }
		else { 'scalar checkpoints' }
	}
	out.writeln('Recorded ${label} (${history.build.backend}, ${history.build.target})')
	for i, event in history.events {
		if access := event.memory {
			out.writeln('  ${i + 1} ${event.kind} of ${access.size_bytes} byte(s) at ${access.address}, image return offset ${access.image_return_offset}, process ${access.process_id}, thread ${access.thread_id}')
			continue
		}
		out.writeln('  ${i + 1} ${json2.encode(event.file)}:${event.line}:${event.column} ${event.kind} = ${json2.encode(event.value)}')
	}
	return out.str()
}
