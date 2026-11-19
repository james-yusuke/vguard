module main

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
	manifest := build(BuildOptions{
		source:   os.real_path(source)
		compiler: os.real_path(compiler)
		backend:  backend
		target:   os.user_os() + '/' + backend
		args:     ['-gc', 'none']
	}, os.join_path(dir, 'target'), false) or { panic(err) }
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
		ssa_report := os.read_file(diagnosis.ssa_file) or { panic(err) }
		assert ssa_report.contains('fn "${example.function}"(')
		assert ssa_report.contains('>>> SSA instruction mapped from the crash')
		assert ssa_report.contains('  %${location.ssa_value} = sdiv ')
		assert !ssa_report.contains('fn "main"(')
		text := bundle.format_diagnosis(diagnosis)
		assert text.contains('^ stop mapped here')
		assert text.contains('= SSA: %${location.ssa_value} sdiv')
	}
}

struct WasmCrashExample {
	name     string
	reason   string
	function string
	line     int
}
