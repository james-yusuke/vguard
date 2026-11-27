module main

import json2
import os

struct LineReduction {
	source   string
	lines    int
	attempts int
	complete bool
}

struct ReductionReport {
	version                       int    = 1
	evidence                      string = 'matching_successful_output'
	file                          string
	original_lines                int
	reduced_lines                 int
	attempts                      int
	single_line_deletions_checked bool
}

fn reduce_lines(source string, budget int, accepts fn (string) !bool) !LineReduction {
	mut lines := source.split_into_lines()
	mut best := source
	mut groups := 2
	mut attempts := 0
	for lines.len > 0 {
		chunk := (lines.len + groups - 1) / groups
		mut changed := false
		for start := 0; start < lines.len; start += chunk {
			end := if start + chunk < lines.len { start + chunk } else { lines.len }
			if attempts >= budget {
				return LineReduction{ source: best, lines: lines.len, attempts: attempts }
			}
			mut candidate := lines[..start].clone()
			candidate << lines[end..]
			body := if candidate.len > 0 { candidate.join('\n') + '\n' } else { '' }
			attempts++
			if accepts(body)! {
				lines = candidate.clone()
				best = body
				groups = if groups > 2 { groups - 1 } else { 2 }
				changed = true
				break
			}
		}
		if changed {
			continue
		}
		if chunk == 1 {
			break
		}
		groups = if groups * 2 > lines.len { lines.len } else { groups * 2 }
	}
	return LineReduction{ source: best, lines: lines.len, attempts: attempts, complete: true }
}

fn check_reduction(source string, filename string, builds []BuildOptions, expected []Outcome, scenario ExecutionCase, repeats int, include_exits bool) !bool {
	work := temp_directory()!
	defer { os.rmdir_all(work) or {} }
	input := os.join_path(work, filename)
	os.write_file(input, source)!
	for index, options in builds {
		manifest := build(BuildOptions{ ...options, source: input }, os.join_path(work, 'build-${index}'), false) or {
			return false
		}
		bundle := open_bundle(manifest) or { return false }
		for _ in 0 .. repeats {
			outcome := run_for_comparison(bundle, scenario) or { return false }
			if outcome.status != 'exited' || (!include_exits && outcome.exit_code != 0) {
				return error('source reduction stopped after a candidate reported ${outcome.status} (${outcome.exit_code})')
			}
			if !same_outcome(expected[index], outcome) {
				return false
			}
		}
	}
	return true
}

fn minimize_output_difference(target Bundle, reference Bundle, scenario ExecutionCase, out string, attempts int, mode ExitComparisonOptions) !string {
	if attempts <= 0 {
		return error('--attempts must be positive')
	}
	if os.exists(out) {
		return error('minimize requires a new output directory')
	}
	if scenario.harness != '' {
		return error('minimize requires standalone builds')
	}
	options := target.manifest.options
	reference_options := reference.manifest.options
	if options.source != reference_options.source || target.manifest.source_sha256 != reference.manifest.source_sha256
		|| !os.is_file(options.source) || os.file_ext(options.source) != '.v' {
		return error('minimize requires two builds of the same recorded .v file')
	}
	mut expected := []Outcome{}
	for bundle in [target, reference] {
		if bundle.manifest.options.memory || bundle.manifest.options.trace_hangs || bundle.image.relocatable
			|| !bundle.image.runnable {
			return error('minimize requires standalone runnable builds without sanitizer instrumentation')
		}
		validate_comparison_inputs(bundle)!
		observation := observe_regression_build(bundle, scenario, mode)
		if observation.reason != '' {
			required := if mode.include_exits {
				'repeatable executions'
			} else {
				'two repeatable successful executions'
			}
			return error('minimize requires ${required}: ${observation.reason}')
		}
		expected << observation.outcome
	}
	if same_outcome(expected[0], expected[1]) {
		return error(if mode.include_exits {
			'the two builds have identical output and exit codes'
		} else {
			'the two builds have identical output'
		})
	}
	input := os.read_file(options.source)!
	filename := os.file_name(options.source)
	builds := [options, reference_options]
	if !check_reduction(input, filename, builds, expected, scenario, 1, mode.include_exits)! {
		return error('the output difference does not reproduce from a staged copy of the source')
	}

	reduced := reduce_lines(input, attempts, fn [filename, builds, expected, scenario, mode] (candidate string) !bool {
		return check_reduction(candidate, filename, builds, expected, scenario, 1, mode.include_exits)
	})!
	if !check_reduction(reduced.source, filename, builds, expected, scenario, 2, mode.include_exits)! {
		matched := if mode.include_exits { 'results' } else { 'successful outputs' }
		return error('the final reduction did not reproduce both ${matched} on repeat runs')
	}
	return save_reduction(out, filename, input, reduced, if mode.include_exits {
		'matching_output_and_exit_status'
	} else {
		'matching_successful_output'
	})
}

struct FailureObservation {
	status    string
	exit_code int
	message   string
	function  string
	opcode    string
	statement string
	column    int
}

fn observe_v_panic(bundle Bundle, scenario ExecutionCase) !FailureObservation {
	outcome := run_for_comparison(bundle, scenario)!
	if outcome.status != 'exited' || outcome.exit_code != 1 {
		return error('the run did not report a V panic exit')
	}
	for stream in [outcome.stderr, outcome.stdout] {
		mut framed := false
		for line in stream.split_into_lines() {
			if line.starts_with('V panic: ') && line.len > 'V panic: '.len {
				return FailureObservation{ status: outcome.status, exit_code: outcome.exit_code, message: line.all_after('V panic: ') }
			}
			if line.starts_with('===') && line.trim('= ') == 'V panic' {
				framed = true
			}
			if framed && line.trim_space().starts_with('message: ') {
				return FailureObservation{ status: outcome.status, exit_code: outcome.exit_code, message: line.trim_space().all_after('message: ') }
			}
		}
	}
	return error('the run did not report a V panic message')
}

fn check_observed_reduction(source string, filename string, options BuildOptions, expected FailureObservation, scenario ExecutionCase, repeats int, observe fn (Bundle, ExecutionCase) !FailureObservation) !bool {
	work := temp_directory()!
	defer { os.rmdir_all(work) or {} }
	path := os.join_path(work, filename)
	os.write_file(path, source)!
	manifest := build(BuildOptions{ ...options, source: path }, os.join_path(work, 'build'), false) or { return false }
	bundle := open_bundle(manifest) or { return false }
	for _ in 0 .. repeats {
		observed := observe(bundle, scenario) or { return false }
		if observed != expected {
			return false
		}
	}
	return true
}

fn minimize_v_panic(bundle Bundle, scenario ExecutionCase, out string, attempts int) !string {
	options := bundle.manifest.options
	if attempts <= 0 || os.exists(out) {
		return error('minimize --panic requires a positive attempt budget and a new output directory')
	}
	if scenario.harness != '' || options.memory || options.trace_hangs || options.trace_runtime
		|| !bundle.image.runnable || bundle.image.relocatable || bundle.image.format == 'wasm'
		|| !os.is_file(options.source) || os.file_ext(options.source) != '.v' {
		return error('minimize --panic requires a standalone executable built from one V file')
	}
	validate_comparison_inputs(bundle)!
	expected := observe_v_panic(bundle, scenario)!
	if observe_v_panic(bundle, scenario)! != expected {
		return error('the original V panic was not repeatable')
	}
	input := os.read_file(options.source)!
	filename := os.file_name(options.source)
	if !check_observed_reduction(input, filename, options, expected, scenario, 1, observe_v_panic)! {
		return error('the panic did not reproduce from a staged copy of the original file')
	}
	reduced := reduce_lines(input, attempts, fn [filename, options, expected, scenario] (candidate string) !bool {
		return check_observed_reduction(candidate, filename, options, expected, scenario, 1,
			observe_v_panic)
	})!
	if !check_observed_reduction(reduced.source, filename, options, expected, scenario, 2, observe_v_panic)! {
		return error('the reduced file did not reproduce the V panic twice')
	}
	return save_reduction(out, filename, input, reduced, 'matching_v_panic_message_and_exit_status')
}

fn observe_wasm_arithmetic(bundle Bundle, scenario ExecutionCase) !FailureObservation {
	outcome := run_for_comparison(bundle, scenario)!
	lines := outcome.stderr.trim_space().split_into_lines()
	if lines.len == 0 {
		return error('Wasmtime did not report an arithmetic trap')
	}
	cause := wasm_cause_line(lines.last())
	if cause !in ['wasm trap: integer divide by zero', 'wasm trap: integer overflow'] {
		return error('Wasmtime did not report a supported integer arithmetic trap')
	}
	report := bundle.wasm_diagnosis(outcome)
	location := report.location or { return error('the arithmetic trap has no V source mapping') }
	if report.kind != 'crash' || location.precision == 'caller_frame'
		|| location.ssa_opcode !in ['sdiv', 'udiv', 'srem', 'urem']
		|| os.real_path(location.file) != bundle.manifest.options.source {
		return error('the arithmetic trap did not originate at a mapped integer operation in the input file')
	}
	source := os.read_lines(location.file)!
	if location.line < 1 || location.line > source.len {
		return error('the arithmetic trap source line is unavailable')
	}
	return FailureObservation{
		status:    outcome.status
		exit_code: outcome.exit_code
		message:   cause
		function:  location.function
		opcode:    location.ssa_opcode
		statement: source[location.line - 1].trim_space()
		column:    location.column
	}
}

fn minimize_wasm_arithmetic(bundle Bundle, scenario ExecutionCase, out string, attempts int) !string {
	options := bundle.manifest.options
	if attempts <= 0 || os.exists(out) {
		return error('minimize --arithmetic-trap requires a positive attempt budget and a new output directory')
	}
	if scenario.harness != '' || options.memory || options.trace_hangs || options.trace_runtime
		|| !bundle.image.runnable || bundle.image.relocatable || bundle.image.format != 'wasm'
		|| !os.is_file(options.source) || os.file_ext(options.source) != '.v' {
		return error('minimize --arithmetic-trap requires a standalone Wasm build of one V file')
	}
	validate_comparison_inputs(bundle)!
	expected := observe_wasm_arithmetic(bundle, scenario)!
	if observe_wasm_arithmetic(bundle, scenario)! != expected {
		return error('the original arithmetic trap was not repeatable')
	}
	input := os.read_file(options.source)!
	filename := os.file_name(options.source)
	if !check_observed_reduction(input, filename, options, expected, scenario, 1, observe_wasm_arithmetic)! {
		return error('the arithmetic trap did not reproduce from a staged copy of the original file')
	}
	reduced := reduce_lines(input, attempts, fn [filename, options, expected, scenario] (candidate string) !bool {
		return check_observed_reduction(candidate, filename, options, expected, scenario, 1,
			observe_wasm_arithmetic)
	})!
	if !check_observed_reduction(reduced.source, filename, options, expected, scenario, 2, observe_wasm_arithmetic)! {
		return error('the reduced file did not reproduce the arithmetic trap twice')
	}
	return save_reduction(out, filename, input, reduced, 'matching_wasmtime_integer_trap_and_ssa_source')
}

fn save_reduction(out string, filename string, input string, reduced LineReduction, evidence string) !string {
	os.mkdir(out)!
	mut saved := false
	defer {
		if !saved {
			os.rmdir_all(out) or {}
		}
	}
	path := os.join_path(out, filename)
	os.write_file(path, reduced.source)!
	os.write_file(os.join_path(out, 'reduction.json'), json2.encode(ReductionReport{
		evidence:                      evidence
		file:                          filename
		original_lines:                input.split_into_lines().len
		reduced_lines:                 reduced.lines
		attempts:                      reduced.attempts
		single_line_deletions_checked: reduced.complete
	}, prettify: true) + '\n')!
	saved = true
	return path
}
