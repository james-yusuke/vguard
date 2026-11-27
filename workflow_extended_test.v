module main

import os

fn test_wasi_stdio_reexecutes_recorded_input_from_the_bundled_artifact() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	if compiler == '' {
		return
	}
	executable('wasmtime') or { return }
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'input.wasm.v')
	os.write_file(source, "module main

struct FixtureIoVec {
	buf &u8
	len uint
}

@[wasm_import_namespace: 'wasi_snapshot_preview1']
fn WASM.fd_read(fd int, iovs &FixtureIoVec, iovs_len uint, nread &uint) u16

fn main() {
	mut input := u8(0)
	mut nread := uint(0)
	vec := FixtureIoVec{buf: &input, len: 1}
	result := WASM.fd_read(0, &vec, 1, &nread)
	assert result == 0 && nread == 1
	println(input)
}
") or { panic(err) }
	path := build(BuildOptions{
		source:   source
		compiler: os.real_path(compiler)
		backend:  'wasm'
		target:   'wasm32_emscripten/wasm32'
	}, os.join_path(dir, 'wasm'), false) or { panic(err) }
	bundle := open_bundle(path) or { panic(err) }
	recorded := os.join_path(dir, 'stdio')
	stored := record_wasi_stdio(bundle, ExecutionCase{ stdin: 'Z' }, recorded) or { panic(err) }
	history := open_history(stored) or { panic(err) }
	assert history.evidence == wasi_stdio_history_evidence
	assert history.outcome.stdout == '90\n'
	os.rm(bundle.artifact) or { panic(err) }
	report := replay_wasi_stdio(stored, history) or { panic(err) }
	assert report.kind == 'matched'
	assert report.actual.stdout == '90\n'
	os.write_file(os.join_path(recorded, wasi_replay_artifact), 'changed') or { panic(err) }
	tampered := replay_wasi_stdio(stored, history) or {
		assert err.msg().contains('artifact SHA-256')
		ReexecutionReport{}
	}
	assert tampered.kind == ''
}

fn test_wasi_stdio_imports_exclude_other_host_services() {
	mut imports := [u8(1), 22]
	imports << 'wasi_snapshot_preview1'.bytes()
	imports << [u8(7)]
	imports << 'fd_read'.bytes()
	imports << [u8(0), 0]
	check_wasi_stdio_imports(imports) or { panic(err) }
	mut disallowed := imports.clone()
	disallowed[25] = `x`
	check_wasi_stdio_imports(disallowed) or {
		assert err.msg().contains('does not supply')
		return
	}
	assert false
}

fn test_wasi_stdio_rejects_shared_memory() {
	check_unshared_wasm_memories([u8(1), 3, 1, 3]) or {
		assert err.msg().contains('unshared')
		return
	}
	assert false
}

fn test_wasm_arithmetic_reduction_preserves_the_observed_operation() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	if compiler == '' {
		return
	}
	executable('wasmtime') or { return }
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	for cause, arguments in {
		'integer divide by zero': '20, 0'
		'integer overflow':       'i64(-9223372036854775807) - 1, -1'
	} {
		case_dir := os.join_path(dir, cause.replace(' ', '-'))
		os.mkdir(case_dir) or { panic(err) }
		source := os.join_path(case_dir, 'arithmetic.v')
		os.write_file(source, "module main

@[noinline]
fn quotient(dividend i64, divisor i64) i64 {
	return dividend / divisor
}

fn main() {
	println('unrelated')
	println(quotient(${arguments}))
}
") or { panic(err) }
		path := build(BuildOptions{
			source:   source
			compiler: os.real_path(compiler)
			backend:  'wasm'
			target:   'wasm32_emscripten/wasm32'
		}, os.join_path(case_dir, 'build'), false) or { panic(err) }
		bundle := open_bundle(path) or { panic(err) }
		report := observe_wasm_arithmetic(bundle, ExecutionCase{}) or { panic(err) }
		assert report.message == 'wasm trap: ${cause}'
		assert report.function.ends_with('quotient') && report.opcode == 'sdiv'
		out := os.join_path(case_dir, 'reduced')
		file := minimize_wasm_arithmetic(bundle, ExecutionCase{}, out, 20) or { panic(err) }
		body := os.read_file(file) or { panic(err) }
		assert body.contains('return dividend / divisor') && !body.contains('unrelated')
		assert (os.read_file(os.join_path(out, 'reduction.json')) or { panic(err) }).contains('matching_wasmtime_integer_trap_and_ssa_source')
	}
}

fn test_panic_reduction_preserves_the_message_and_removes_unrelated_lines() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	if compiler == '' || os.user_os() !in ['linux', 'macos'] || arch == '' {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'panic_example.v')
	os.write_file(source, "fn main() {
	println('unrelated')
	panic('fixed panic signature')
}
") or { panic(err) }
	path := build(BuildOptions{
		source:   source
		compiler: os.real_path(compiler)
		backend:  'c'
		target:   os.user_os() + '/' + arch
		args:     ['-cc', 'clang', '-gc', 'none']
	}, os.join_path(dir, 'build'), false) or { panic(err) }
	bundle := open_bundle(path) or { panic(err) }
	out := os.join_path(dir, 'reduced')
	file := minimize_v_panic(bundle, ExecutionCase{}, out, 10) or { panic(err) }
	body := os.read_file(file) or { panic(err) }
	assert body.contains('fixed panic signature') && !body.contains('unrelated')
	assert (os.read_file(os.join_path(out, 'reduction.json')) or { panic(err) }).contains('matching_v_panic_message_and_exit_status')
}

fn test_compiler_series_rebuilds_and_bisects_repeatable_output_changes() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	if compiler == '' || os.user_os() !in ['linux', 'macos'] || arch == '' {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'version.v')
	os.write_file(source, "fn main() {
	\$if regression_fixture ? {
		println('changed')
	} \$else {
		println('base')
	}
}
") or { panic(err) }
	mut versions := []RegressionCompiler{}
	command := shell_argument(os.real_path(compiler)) or { panic(err) }
	for i in 0 .. 5 {
		path := os.join_path(dir, 'compiler-${i}')
		flag := if i < 3 { '' } else { ' -d regression_fixture' }
		os.write_file(path, '#!/bin/sh\nexec ${command}${flag} "$@"\n') or { panic(err) }
		os.chmod(path, 0o755) or { panic(err) }
		versions << RegressionCompiler{ label: i.str(), path: path }
	}
	result := find_compiler_regression(CompilerRegressionSeries{
		build:     BuildOptions{
			source:  source
			backend: 'c'
			target:  os.user_os() + '/' + arch
			args:    ['-cc', 'clang', '-gc', 'none']
		}
		compilers: versions
	}, ExecutionCase{}) or { panic(err) }
	assert result.kind == 'changed', result.reason
	assert result.first_changed == '3' && result.last_matching == '2'
	assert result.method == 'compiler_bisection' && result.assumption != ''
	assert result.samples.len == 4 && result.samples.all(it.runs == 2)
}
