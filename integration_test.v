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
	if os.args.contains('nonzero') {
		exit(5)
	}
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
	manifest := build(options, output, false, trace_build: true, trace_ssa: true) or { panic(err) }
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
	flow := bundle.dataflow_at(loc) or { panic(err) }
	ast := flow.nodes[0].ast or { panic('native SSA lost its AST origin') }
	assert ast.kind == 'infix'
	assert ast.file == loc.file
	assert ast.line == loc.line
	assert ast.column == loc.column
	assert_ast_source(ast, os.real_path(source), 'n * 2')
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
	assert !json2.encode(report).contains('"build_comparison"')

	reference_path := build(BuildOptions{ ...options, backend: 'c' }, os.join_path(dir, 'manual-reference'), false) or { panic(err) }
	reference := open_bundle(reference_path) or { panic(err) }
	explicit := compare_recorded(bundle, reference, ExecutionCase{}) or { panic(err) }
	assert explicit.kind == 'different'
	observed := explicit.build_comparison or { panic('missing build comparison') }
	assert (observed.first_stdout_difference or { -1 }) == 1
	assert observed.reference.backend == 'c'
	assert explicit.divergence != none
	series_path := os.join_path(dir, 'series.json')
	os.write_file(series_path, json2.encode(RegressionSeries{
		builds: [
			RegressionBuildSpec{ label: 'baseline', manifest: 'target/build.json' },
			RegressionBuildSpec{ label: 'still-matching', manifest: 'target/build.json' },
			RegressionBuildSpec{ label: 'changed', manifest: 'manual-reference/build.json' },
			RegressionBuildSpec{ label: 'later', manifest: 'target/build.json' },
		]
	})) or { panic(err) }
	series := load_regression_series(series_path) or { panic(err) }
	regression := find_regression(series, ExecutionCase{}) or { panic(err) }
	assert regression.kind == 'changed'
	assert regression.last_matching == 'still-matching'
	assert regression.first_changed == 'changed'
	assert regression.samples.map(it.runs) == [2, 2, 2]
	assert (regression.first_stdout_difference or { -1 }) == 1
	stable := find_regression(RegressionSeries{ builds: series.builds[..2] }, ExecutionCase{}) or {
		panic(err)
	}
	assert stable.kind == 'unchanged'
	assert stable.last_matching == 'still-matching'
	failed_regression := find_regression(series, ExecutionCase{ argv: ['nonzero'] }) or { panic(err) }
	assert failed_regression.kind == 'inconclusive'
	assert failed_regression.reason.contains('exit code 5')
	assert failed_regression.samples.len == 1
	history_path := record_history(bundle, ExecutionCase{}, os.join_path(dir, 'history')) or { panic(err) }
	history := open_history(history_path) or { panic(err) }
	assert history.outcome.stdout == '14\n'
	assert history.events.any(it.kind == 'assignment' && it.value == 'false')
	assert format_history(history).contains('Recorded scalar checkpoints')
	assert history.evidence == scalar_history_evidence
	call_history_path := record_history(bundle, ExecutionCase{}, os.join_path(dir, 'calls'),
		calls: true
	) or { panic(err) }
	call_history := open_history(call_history_path) or { panic(err) }
	assert call_history.outcome == history.outcome
	assert call_history.evidence == call_history_evidence
	entries := call_history.events.filter(it.kind == 'function_enter')
	assert entries.map(it.value) == ['main', 'result']
	assert entries.map(it.line) == [8, 4]
	assert entries.all(it.file == os.real_path(source))

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
	assert failed_trace.stages.any(it.name in ['check', 'check (parallel)'])
	assert !failed_trace.stages.any(it.name == 'ssa build')
	compiler_error := os.read_file(os.join_path(failed_output, 'compiler.stderr.log')) or { panic(err) }
	assert compiler_error.contains('missing_api')
}

fn test_wasmtime_fuel_budget_reports_the_stop_with_available_precision() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	if compiler == '' {
		return
	}
	executable('wasmtime') or { return }
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.real_path(os.join_path(@VMODROOT, 'examples', 'hangs', 'spin.v'))
	manifest := build(BuildOptions{
		source:   source
		compiler: os.real_path(compiler)
		backend:  'wasm'
		target:   'wasm32_emscripten/wasm32'
	}, os.join_path(dir, 'spin'), false, trace_ssa: true) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	report := bundle.run(ExecutionCase{ timeout_ms: 10000 }, fuel: 100000) or { panic(err) }
	assert report.kind == 'fuel_exhausted', report.outcome.stderr
	limit := report.execution_limit or { panic('missing execution limit') }
	assert limit.kind == 'wasm_fuel'
	assert limit.limit == 100000
	assert limit.evidence == 'wasmtime_cli_trap'
	assert report.address.starts_with('0x')
	location := report.location or { panic(report.location_error) }
	assert location.function == 'main'
	assert location.file == source
	flow_report := bundle.with_dataflow(report)
	if location.precision == 'function_body' {
		assert location.line == 0
		assert location.ssa_value == -1
		assert flow_report.ssa_dataflow == none
		assert report.location_error.contains('no SSA range')
	} else {
		assert location.line == 3
		assert location.ssa_value >= 0
		analysis := flow_report.ssa_dataflow or { panic(flow_report.ssa_dataflow_error) }
		assert analysis.root == location.ssa_value
	}
	assert bundle.format_diagnosis(report).contains('wasm_fuel = 100000')
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
			prod:     example.name == 'rounded_divisor'
		}, os.join_path(dir, example.name), false,
			trace_ssa: example.name == 'rounded_divisor'
		) or { panic(err) }
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
		compiler_snapshot := os.read_file(bundle.ssa_path) or { panic(err) }
		ssa_report := os.read_file(diagnosis.ssa_file) or { panic(err) }
		marker := ' << ${diagnosis.reason}'
		assert original == compiler_snapshot
		assert original.split_into_lines().all(it.starts_with('SSA ') || it == '; VGuard SSA v2')
		assert original.contains('SSA function ${example.function} ret=')
		assert original.contains('SSA function main ret=')
		assert !original.contains(marker)
		assert ssa_report.split_into_lines().any(it.starts_with('SSA ${location.ssa_value} sdiv typ=')
			&& it.ends_with(marker))
		assert ssa_report.count(marker) == 1
		assert ssa_report.all_after('\n\n').replace(marker, '') == original
		text := bundle.format_diagnosis(diagnosis)
		assert text.contains('^ stop mapped here')
		assert text.contains('= SSA: %${location.ssa_value} sdiv << ${diagnosis.reason}\n')
		assert text.contains('SSA (original)\nSSA function ${example.function} ret=')
		assert text.contains('SSA (annotated)\nSSA function ${example.function} ret=')
		assert !text.contains('SSA function main ret=')
		assert bundle.format_ssa_diagnosis(diagnosis) == ssa_report
		if example.name == 'rounded_divisor' {
			assert_pass_log_matches_graph(bundle) or { panic(err) }
			traced := bundle.with_dataflow(diagnosis)
			flow := traced.ssa_dataflow or { panic(traced.ssa_dataflow_error) }
			assert flow.root == location.ssa_value
			assert flow.evidence == 'static_ssa_candidates'
			assert flow.nodes[0].op == 'sdiv'
			ast := flow.nodes[0].ast or { panic('crashing SSA lost its AST origin') }
			assert ast.kind == 'infix'
			assert ast.file == location.file
			assert ast.line == location.line
			assert ast.column == location.column
			assert ast.copied_from == none
			assert_ast_source(ast, source, 'credits / completed_batches')
			prior := flow.nodes.filter(it.id != flow.root && it.op == 'sdiv')
			assert prior.len == 1
			input := prior[0].ast or { panic('upstream SSA lost its AST origin') }
			assert_ast_source(input, source, 'items / batch_size')
			assert bundle.format_diagnosis(traced).contains('AST node ${ast.node} (infix)')
			encoded := json2.encode(traced)
			assert encoded.contains('"ast":')
			assert !encoded.contains('"copied_from"')
		} else {
			assert bundle.manifest.ssa_graph_sha256 == ''
			assert !json2.encode(bundle.manifest).contains('"ssa_graph_sha256"')
			encoded := json2.encode(diagnosis)
			assert !encoded.contains('"ssa_dataflow"')
			assert !encoded.contains('"stack_trace"')
		}
	}
}

fn assert_ast_source(ast SsaAst, source string, expression string) {
	assert ast.source_file == source
	bytes := os.read_file(source) or { panic(err) }
	assert ast.start_byte >= 0
	assert ast.end_byte <= bytes.len
	assert ast.end_byte >= ast.start_byte
	assert bytes[ast.start_byte..ast.end_byte] == expression
}

fn test_ssa_inlining_records_the_source_of_each_copied_instruction() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	if compiler == '' {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.real_path(os.join_path(dir, 'inline_example.v'))
	os.write_file(source, 'fn twice(n int) int {\n\t#line 90 "generated.dsl"\n\treturn n * 2\n}\n\nfn main() {\n\tprintln(twice(7))\n}\n') or {
		panic(err)
	}
	manifest := build(BuildOptions{
		source:   source
		compiler: os.real_path(compiler)
		backend:  'wasm'
		target:   'wasm32_emscripten/wasm32'
		prod:     true
	}, os.join_path(dir, 'build'), false, trace_ssa: true) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	pass_path := bundle.ssa_path.trim_string_right('.ssa') + '.passes.jsonl'
	lines := os.read_lines(pass_path) or { panic(err) }
	assert lines.len > 1
	baseline := json2.decode[TestPass](lines[0]) or { panic(err) }
	inlining := json2.decode[TestPass](lines[1]) or { panic(err) }
	assert baseline.pass == 'input'
	assert inlining.pass == 'inline'
	original := baseline.created.filter(it.function == 'twice' && it.op == 'mul')
	cloned := inlining.created.filter(it.function == 'main' && it.op == 'mul')
	assert original.len == 1
	assert cloned.len == 1
	original_ast := original[0].ast or { panic('missing original AST') }
	cloned_ast := cloned[0].ast or { panic('missing inlined AST') }
	assert (cloned_ast.copied_from or { -1 }) == original[0].id
	assert original_ast.copied_from == none
	assert original_ast.node == cloned_ast.node
	assert cloned_ast.file == 'generated.dsl'
	assert cloned_ast.line == 90
	assert_ast_source(cloned_ast, source, 'n * 2')
	jumps := inlining.created.filter(it.function == 'main' && it.op == 'jmp' && it.ast == none)
	assert jumps.len > 0
}

fn test_minimize_preserves_a_successful_wasmtime_output_difference() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	if compiler == '' {
		return
	}
	executable('wasmtime') or { return }
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'example.v')
	input := '// A removable comment.\n\nfn main() {\n\t$if reduction_variant ? {\n\t\tprintln(16)\n\t} $else {\n\t\tprintln(14)\n\t}\n}\n'
	os.write_file(source, input) or { panic(err) }
	options := BuildOptions{
		source:   os.real_path(source)
		compiler: os.real_path(compiler)
		backend:  'wasm'
		target:   'wasm32_emscripten/wasm32'
	}
	target_manifest := build(options, os.join_path(dir, 'target'), false) or { panic(err) }
	reference_manifest := build(BuildOptions{ ...options, args: ['-d', 'reduction_variant'] },
		os.join_path(dir, 'reference'), false) or { panic(err) }
	target := open_bundle(target_manifest) or { panic(err) }
	reference := open_bundle(reference_manifest) or { panic(err) }
	out := os.join_path(dir, 'minimized')
	result := minimize_output_difference(target, reference, ExecutionCase{}, out, 16) or { panic(err) }
	assert (os.read_file(source) or { panic(err) }) == input
	reduced := os.read_file(result) or { panic(err) }
	assert !reduced.contains('removable comment')
	assert reduced.contains('println(14)') && reduced.contains('println(16)')
	report := json2.decode[ReductionReport](os.read_file(os.join_path(out, 'reduction.json')) or { panic(err) }) or {
		panic(err)
	}
	assert report.reduced_lines < report.original_lines
	assert report.evidence == 'matching_successful_output'
}

struct TestPassRewrite {
	from int
	to   int
	user int
}

struct TestPassChange {
	before SsaInstruction
	after  SsaInstruction
}

struct TestPass {
	pass         string
	verifier_ran bool
	created      []SsaInstruction
	removed      []SsaInstruction
	changed      []TestPassChange
	rewrites     []TestPassRewrite
}

fn assert_pass_log_matches_graph(bundle Bundle) ! {
	path := bundle.ssa_path.trim_string_right('.ssa') + '.passes.jsonl'
	data := os.read_bytes(path)!
	assert digest(data) == bundle.manifest.ssa_passes_sha256
	mut state := map[int]SsaInstruction{}
	mut removed := 0
	mut rewrites := 0
	mut last := ''
	for line in data.bytestr().split_into_lines() {
		pass := json2.decode[TestPass](line)!
		last = pass.pass
		if pass.pass == 'mem2reg' {
			assert pass.verifier_ran
			assert pass.created.any(it.op == 'phi')
			assert pass.created.all(it.ast == none)
		}
		for instruction in pass.removed {
			assert instruction.id in state
			state.delete(instruction.id)
			removed++
		}
		for change in pass.changed {
			assert change.before.id in state
			assert state[change.before.id].op == change.before.op
			assert change.before.id == change.after.id
			state[change.after.id] = change.after
		}
		for instruction in pass.created {
			assert instruction.id !in state
			state[instruction.id] = instruction
		}
		rewrites += pass.rewrites.len
	}
	assert last == 'final'
	assert removed > 0
	assert rewrites > 0
	graph := bundle.read_ssa_graph()!
	assert state.len == graph.instructions.len
	for instruction in graph.instructions {
		assert instruction.id in state
		assert state[instruction.id] == instruction
	}
}

struct WasmCrashExample {
	name     string
	reason   string
	function string
	line     int
}
