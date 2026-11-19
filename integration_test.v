module main

import json2
import os

fn test_companion_compiler_resolves_ssa_and_traces_the_first_difference() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	if compiler == '' || os.user_os() !in ['macos', 'linux'] {
		return
	}
	mut backend := 'amd64'
	$if arm64 {
		backend = 'arm64'
	} $else $if amd64 {
		if os.user_os() != 'linux' {
			return
		}
	} $else {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	source := os.join_path(dir, 'sample.v')
	os.write_file(source, "import os

@[noinline]
fn result(n int) int {
	return n * 2
}

fn main() {
	base := 7
	selected := os.executable().contains('reference')
	mut value := base
	if selected {
		value = base + 1
	}
	println(result(value))
}
") or {
		panic(err)
	}
	options := BuildOptions{
		source:   os.real_path(source)
		compiler: os.real_path(compiler)
		backend:  backend
		target:   os.user_os() + '/' + backend
		args:     ['-gc', 'none']
	}
	output := os.join_path(dir, 'target')
	manifest := build(options, output, false, trace_build: true) or { panic(err) }
	trace := read_test_compile_trace(output) or { panic(err) }
	assert trace.backend == backend
	assert trace.target == options.target
	assert trace.artifact == 'program'
	assert trace.status == 'exited'
	assert trace.exit_code == 0
	assert trace.stages.any(it.name == 'ssa build')
	assert trace.stages.any(it.name == '${backend} gen')
	assert trace.stages.any(it.name == 'link')
	assert os.exists(os.join_path(output, 'compiler.stdout.log'))
	assert os.exists(os.join_path(output, 'compiler.stderr.log'))
	bundle := open_bundle(manifest) or { panic(err) }
	multiply := bundle.ranges.filter(it.location.function == 'result'
		&& it.location.ssa_opcode == 'mul')
	assert multiply.len > 0
	loc := bundle.resolve_section(multiply[0].section, multiply[0].start) or { panic(err) }
	assert loc.file == os.real_path(source)
	assert loc.line == 5
	report := compare(bundle, ExecutionCase{}) or { panic(err) }
	assert report.kind == 'different'
	assert report.target.stdout == '14\n'
	assert report.reference.stdout == '16\n'
	diff := report.divergence or { panic(report.location_error) }
	first := diff.target or { panic('missing target event') }
	assert first.kind == 'assignment'
	assert first.line == 10
	assert first.value == 'false'
	text := bundle.format_comparison(report)
	assert text.contains('error[comparison]: target and reference results differ')
	assert text.contains('^ first differing trace event')
	assert text.contains("selected := os.executable().contains('reference')")
	assert text.contains('= target: assignment = false')
	assert text.contains('= reference: assignment = true')

	rejected := os.join_path(dir, 'rejected.v')
	os.write_file(rejected, 'fn main() { missing_api() }\n') or { panic(err) }
	failed_output := os.join_path(dir, 'rejected')
	build(BuildOptions{ ...options, source: rejected }, failed_output, false, trace_build: true) or {
		assert err.msg().contains('V build failed')
	}
	assert !os.exists(os.join_path(failed_output, 'build.json'))
	failed_trace := read_test_compile_trace(failed_output) or { panic(err) }
	assert failed_trace.status == 'exited'
	assert failed_trace.exit_code != 0
	assert failed_trace.stages.any(it.name == 'check')
	assert !failed_trace.stages.any(it.name == 'ssa build')
	compiler_error := os.read_file(os.join_path(failed_output, 'compiler.stderr.log')) or { panic(err) }
	assert compiler_error.contains('missing_api')
}

fn read_test_compile_trace(out string) !CompileTrace {
	return json2.decode[CompileTrace](os.read_file(os.join_path(out, 'compile-trace.json'))!)
}

fn test_companion_compiler_resolves_the_wasmtime_crash_examples() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	if compiler == '' {
		return
	}
	executable('wasmtime') or { return }
	dir := temp_directory() or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	for example in [
		WasmCrashExample{
			name:     'rounded_divisor'
			reason:   'integer divide by zero'
			function: 'credits_per_batch'
			line:     6
		},
		WasmCrashExample{
			name:     'division_overflow'
			reason:   'integer overflow'
			function: 'account_units'
			line:     5
		},
	] {
		source := os.real_path(os.join_path(@VMODROOT, 'examples', 'crashes', example.name + '.v'))
		manifest := build(BuildOptions{
			source:   source
			compiler: os.real_path(compiler)
			backend:  'wasm'
			target:   'wasm32_emscripten/wasm32'
		}, os.join_path(dir, example.name), false) or { panic(err) }
		bundle := open_bundle(manifest) or { panic(err) }
		diagnosis := bundle.run(ExecutionCase{}) or { panic(err) }
		assert diagnosis.kind == 'crash'
		assert diagnosis.reason.contains(example.reason)
		location := diagnosis.location or { panic(diagnosis.location_error) }
		assert location.file == source
		assert location.line == example.line
		assert location.function == example.function
		assert location.ssa_opcode == 'sdiv'
		assert location.precision == 'source_span'
		assert diagnosis.ssa_error == ''
		assert os.dir(os.dir(diagnosis.ssa_file)) == os.join_path(os.dir(manifest), 'diagnostics')
		assert os.dir(diagnosis.ssa_original_file) == os.dir(diagnosis.ssa_file)
		original := os.read_file(diagnosis.ssa_original_file) or { panic(err) }
		ssa_report := os.read_file(diagnosis.ssa_file) or { panic(err) }
		marker := '  ; <<< stop mapped here'
		assert original.starts_with('fn "${example.function}"(')
		assert !original.contains(marker)
		assert ssa_report.contains('fn "${example.function}"(')
		assert ssa_report.split_into_lines().any(it.starts_with('  %${location.ssa_value} = sdiv ')
			&& it.ends_with(marker))
		assert ssa_report.all_after('\n\n').replace(marker, '') == original
		assert !ssa_report.contains('fn "main"(')
		text := bundle.format_diagnosis(diagnosis)
		assert text.contains('^ stop mapped here')
		assert text.contains('= SSA: %${location.ssa_value} sdiv')
		assert text.contains('SSA (original)\n${original}\nSSA (annotated)\n')
	}
}

struct WasmCrashExample {
	name     string
	reason   string
	function string
	line     int
}
