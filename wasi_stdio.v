module main

import json2
import os

const wasi_stdio_imports = ['args_get', 'args_sizes_get', 'environ_get', 'environ_sizes_get', 'fd_read',
	'fd_write', 'proc_exit']

fn validate_wasi_stdio(data []u8) ! {
	if data.len < 8 || data[..8] != [u8(0), 0x61, 0x73, 0x6d, 1, 0, 0, 0] {
		return error('WASI stdio replay requires a core Wasm module')
	}
	mut cursor := 8
	for cursor < data.len {
		kind := data[cursor]
		length, start := leb(data, cursor + 1)!
		section := view(data, u64(start), u64(length))!
		match kind {
			2 { check_wasi_stdio_imports(section)! }
			5 { check_unshared_wasm_memories(section)! }
			else {}
		}
		cursor = start + length
	}
}

fn wasm_replay_name(data []u8, offset int) !(string, int) {
	length, start := leb(data, offset)!
	return view(data, u64(start), u64(length))!.bytestr(), start + length
}

fn check_wasi_stdio_imports(section []u8) ! {
	count, start := leb(section, 0)!
	if count > section.len {
		return error('invalid Wasm import count')
	}
	mut offset := start
	for _ in 0 .. count {
		module_name, field_start := wasm_replay_name(section, offset)!
		field, kind_offset := wasm_replay_name(section, field_start)!
		if kind_offset >= section.len || section[kind_offset] != 0
			|| module_name != 'wasi_snapshot_preview1' || field !in wasi_stdio_imports {
			return error('WASI stdio replay does not supply the import ${module_name}.${field}')
		}
		_, end := leb(section, kind_offset + 1)!
		offset = end
	}
	if offset != section.len {
		return error('invalid Wasm import section')
	}
}

fn check_unshared_wasm_memories(section []u8) ! {
	count, start := leb(section, 0)!
	if count > section.len {
		return error('invalid Wasm memory count')
	}
	mut offset := start
	for _ in 0 .. count {
		flags, minimum := leb(section, offset)!
		if flags !in [0, 1] {
			return error('WASI stdio replay requires unshared 32-bit Wasm memories')
		}
		_, after_minimum := leb(section, minimum)!
		offset = after_minimum
		if flags == 1 {
			_, after_maximum := leb(section, after_minimum)!
			offset = after_maximum
		}
	}
	if offset != section.len {
		return error('invalid Wasm memory section')
	}
}

struct WasiStdioInput {
	argv       []string
	stdin      string
	env        map[string]string
	timeout_ms int
}

struct WasiStdioHistory {
	artifact_sha256 string
	wasmtime_sha256 string
	input           WasiStdioInput
}

const wasi_stdio_history_evidence = 'recorded_wasi_stdio'
const wasi_replay_artifact = 'program.wasm'

fn run_wasi_stdio(wasmtime string, artifact []u8, input WasiStdioInput) !Outcome {
	if input.timeout_ms <= 0 {
		return error('WASI stdio replay requires a positive timeout')
	}
	if input.argv.any(it.contains('\x00')) {
		return error('WASI arguments cannot contain NUL')
	}
	work := temp_directory()!
	defer { os.rmdir_all(work) or {} }
	os.write_file_array(os.join_path(work, wasi_replay_artifact), artifact)!
	stdin := os.join_path(work, 'stdin')
	os.write_file(stdin, input.stdin)!
	mut args := ['run', '-C', 'cache=n', '-W', 'threads=n', '-W', 'relaxed-simd=n', '-W',
		'nan-canonicalization=y']
	for key in input.env.keys().sorted() {
		if key == '' || key.contains_any('=\x00') || input.env[key].contains('\x00') {
			return error('invalid WASI environment key')
		}
		args << ['--env', key + '=' + input.env[key]]
	}
	args << ['--', wasi_replay_artifact]
	args << input.argv
	return capture(Command{
		executable: wasmtime
		args:       args
		env:        {
			'LANG': 'C'
			'TZ':   'UTC'
		}
		cwd:        work
		stdin_path: stdin
		timeout_ms: input.timeout_ms
	})
}

fn record_wasi_stdio(bundle Bundle, scenario ExecutionCase, out string) !string {
	if scenario.harness != '' || bundle.image.format != 'wasm' || !bundle.image.runnable {
		return error('record --wasi-stdio requires an executable Wasm module')
	}
	artifact := os.read_bytes(bundle.artifact)!
	if digest(artifact) != bundle.artifact_sha256 {
		return error('the Wasm artifact has changed since its manifest was opened')
	}
	validate_wasi_stdio(artifact)!
	wasmtime := executable('wasmtime')!
	runtime_hash := digest(os.read_bytes(wasmtime)!)
	input := WasiStdioInput{
		argv:       scenario.argv
		stdin:      scenario.stdin
		env:        scenario.env
		timeout_ms: scenario.timeout_ms
	}
	first := run_wasi_stdio(wasmtime, artifact, input)!
	if first.status != 'exited' || first.exit_code != 0 {
		return error('record --wasi-stdio requires a successful execution (${first.status}, ${first.exit_code})')
	}
	second := run_wasi_stdio(wasmtime, artifact, input)!
	if second.status != 'exited' || !same_outcome(first, second) {
		return error('the WASI stdio recording did not reproduce on a second run')
	}
	history := ExecutionHistory{
		evidence:    wasi_stdio_history_evidence
		build:       compared_build(bundle.manifest)
		source_hash: bundle.manifest.source_sha256
		outcome:     first
		wasi_stdio:  WasiStdioHistory{
			artifact_sha256: bundle.artifact_sha256
			wasmtime_sha256: runtime_hash
			input:           input
		}
	}
	encoded := json2.encode(history) + '\n'
	if encoded.len > capture_limit * 4 {
		return error('the execution history exceeds the 64 MiB replay limit')
	}
	os.mkdir(out)!
	mut saved := false
	defer {
		if !saved {
			os.rmdir_all(out) or {}
		}
	}
	os.write_file_array(os.join_path(out, wasi_replay_artifact), artifact)!
	path := os.join_path(out, 'history.json')
	os.write_file(path, encoded)!
	saved = true
	return path
}

fn replay_wasi_stdio(path string, history ExecutionHistory) !ReexecutionReport {
	stdio := history.wasi_stdio or { return error('replay --reexecute requires a WASI stdio recording') }
	artifact := os.read_bytes(os.join_path(os.dir(os.abs_path(path)), wasi_replay_artifact))!
	if digest(artifact) != stdio.artifact_sha256 {
		return error('the recorded Wasm artifact SHA-256 does not match')
	}
	validate_wasi_stdio(artifact)!
	wasmtime := executable('wasmtime')!
	if digest(os.read_bytes(wasmtime)!) != stdio.wasmtime_sha256 {
		return error('the Wasmtime executable SHA-256 does not match the recording')
	}
	actual := run_wasi_stdio(wasmtime, artifact, stdio.input)!
	return ReexecutionReport{
		kind:     if actual.status != 'exited' {
			'inconclusive'
		} else if same_outcome(history.outcome, actual) {
			'matched'
		} else {
			'different'
		}
		evidence: 'wasmtime_reexecution_compared_to_recorded_stdio'
		expected: history.outcome
		actual:   actual
	}
}
