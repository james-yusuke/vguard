module main

import encoding.hex
import os

const trace_prefix = '\x1eVGUARD\t'

struct TraceEvent {
	file   string
	line   int
	column int
	kind   string
	value  string
}

struct Divergence {
	target      ?TraceEvent
	reference   ?TraceEvent
	last_common ?TraceEvent
}

struct Comparison {
	kind             string
	target           Outcome
	reference        Outcome
	divergence       ?Divergence
	location_error   string
	build_comparison ?BuildComparison @[omitempty]
}

struct ComparedBuild {
	backend         string
	target          string
	prod            bool
	compiler_sha256 string
}

struct BuildComparison {
	target                  ComparedBuild
	reference               ComparedBuild
	first_stdout_difference ?int @[omitempty]
	first_stderr_difference ?int @[omitempty]
}

fn compared_build(manifest Manifest) ComparedBuild {
	return ComparedBuild{
		backend:         manifest.options.backend
		target:          manifest.options.target
		prod:            manifest.options.prod
		compiler_sha256: manifest.compiler_sha256
	}
}

fn first_byte_difference(a string, b string) ?int {
	mut i := 0
	for i < a.len && i < b.len && a[i] == b[i] {
		i++
	}
	if i == a.len && i == b.len {
		return none
	}
	return i
}

fn run_for_comparison(bundle Bundle, scenario ExecutionCase) !Outcome {
	if bundle.image.format == 'wasm' {
		return bundle.run_wasm(scenario)
	}
	if scenario.harness != '' {
		mut env := scenario.env.clone()
		env['VGUARD_ARTIFACT'] = bundle.artifact
		return ExecutionCase{
			...scenario
			env: env
		}.run_binary(scenario.harness)
	}
	if !bundle.image.runnable {
		return error('compare requires a runnable executable or a shared-library harness')
	}
	return scenario.run_binary(bundle.artifact)
}

fn same_outcome(a Outcome, b Outcome) bool {
	return a.exit_code == b.exit_code && a.status == b.status && a.stdout == b.stdout
		&& a.stderr == b.stderr
}

fn runtime_result(result Outcome) bool {
	return result.status in ['exited', 'signal']
}

fn validate_comparison_inputs(bundle Bundle) ! {
	options := bundle.manifest.options
	if digest(os.read_bytes(options.compiler)!) != bundle.manifest.compiler_sha256 {
		return error('the V compiler used for this build has changed')
	}
	if source_digest(options.source, os.dir(bundle.artifact))! != bundle.manifest.source_sha256 {
		return error('the V source has changed since the build')
	}
}

fn compare(bundle Bundle, scenario ExecutionCase) !Comparison {
	validate_comparison_inputs(bundle)!
	options := bundle.manifest.options

	work := temp_directory()!
	defer {
		os.rmdir_all(work) or {}
	}
	mut reference_args := options.args.clone()
	if bundle.image.format == 'wasm' && '-cc' !in options.args {
		reference_args << ['-cc', 'emcc']
	}
	reference_opts := BuildOptions{
		...options
		backend: 'c'
		prod:    options.backend != 'c' && options.prod
		args:    reference_args
	}
	reference_path := build(reference_opts, os.join_path(work, 'reference'), false)!
	ref_bundle := open_bundle(reference_path)!
	initial := observe_comparison(bundle, ref_bundle, scenario)!
	return finish_comparison(initial, options, reference_opts, scenario, work)
}

fn observe_comparison(bundle Bundle, ref_bundle Bundle, scenario ExecutionCase) !Comparison {
	target := run_for_comparison(bundle, scenario)!
	reference := run_for_comparison(ref_bundle, scenario)!
	initial := Comparison{
		kind:      if same_outcome(target, reference) { 'equal' } else { 'different' }
		target:    target
		reference: reference
	}
	if !runtime_result(target) || !runtime_result(reference) {
		return Comparison{
			...initial
			kind:           'inconclusive'
			location_error: 'at least one execution did not complete within the capture limits'
		}
	}
	return initial
}

fn compare_recorded(bundle Bundle, reference Bundle, scenario ExecutionCase) !Comparison {
	observed := observe_comparison(bundle, reference, scenario)!
	initial := Comparison{
		...observed
		build_comparison: BuildComparison{
			target:                  compared_build(bundle.manifest)
			reference:               compared_build(reference.manifest)
			first_stdout_difference: first_byte_difference(observed.target.stdout, observed.reference.stdout)
			first_stderr_difference: first_byte_difference(observed.target.stderr, observed.reference.stderr)
		}
	}
	if initial.kind != 'different' {
		return initial
	}
	if bundle.manifest.source_sha256 != reference.manifest.source_sha256
		|| bundle.manifest.options.source != reference.manifest.options.source {
		return Comparison{ ...initial, location_error: 'checkpoint comparison requires the same recorded source' }
	}
	for item in [bundle, reference] {
		validate_comparison_inputs(item) or {
			return Comparison{ ...initial, location_error: err.msg() }
		}
	}
	work := temp_directory()!
	defer { os.rmdir_all(work) or {} }
	return finish_comparison(initial, bundle.manifest.options, reference.manifest.options, scenario, work)
}

fn finish_comparison(initial Comparison, options BuildOptions, reference_opts BuildOptions, scenario ExecutionCase, work string) !Comparison {
	if initial.kind != 'different' {
		return initial
	}
	divergence := trace_difference(initial, options, reference_opts, scenario, work) or {
		return Comparison{
			...initial
			location_error: err.msg()
		}
	}
	return Comparison{
		...initial
		divergence: divergence
	}
}

fn trace_difference(initial Comparison, options BuildOptions, reference_opts BuildOptions, scenario ExecutionCase, work string) !Divergence {
	target_opts, ref_opts := if options.backend == 'fastc' || reference_opts.backend == 'fastc' {
		mut target_args := options.args.clone()
		mut reference_args := reference_opts.args.clone()
		target_args << ['-d', 'vguard_fastc_trace']
		reference_args << ['-d', 'vguard_fastc_trace']
		BuildOptions{
			...options
			args: target_args
		}, BuildOptions{
			...reference_opts
			args: reference_args
		}
	} else {
		options, reference_opts
	}
	target_path := build(target_opts, os.join_path(work, 'trace-target'), true)!
	reference_path := build(ref_opts, os.join_path(work, 'trace-reference'), true)!
	target := run_for_comparison(open_bundle(target_path)!, scenario)!
	reference := run_for_comparison(open_bundle(reference_path)!, scenario)!
	target_output, target_events := split_trace(target.stderr)!
	reference_output, reference_events := split_trace(reference.stderr)!
	if !same_outcome(initial.target, Outcome{ ...target, stderr: target_output }) || !same_outcome(initial.reference, Outcome{
		...reference
		stderr: reference_output
	}) {
		return error('the same output difference did not reproduce with instrumentation')
	}
	return first_divergence(target_events, reference_events)
}

fn split_trace(stderr string) !(string, []TraceEvent) {
	mut events := []TraceEvent{}
	mut output := []string{}
	mut next := 0
	for {
		start := stderr.index_after(trace_prefix, next) or { break }
		output << stderr[next..start]
		payload := start + trace_prefix.len
		end := stderr.index_after('\n', payload) or {
			return error('the last trace event was incomplete')
		}
		fields := stderr[payload..end].trim_right('\r').split('\t')
		if fields.len != 5 || fields[1].int() <= 0 || fields[2].int() <= 0 || fields[4] == '' {
			return error('malformed VGuard trace event')
		}
		events << TraceEvent{
			file:   hex.decode(fields[0])!.bytestr()
			line:   fields[1].int()
			column: fields[2].int()
			kind:   fields[3]
			value:  fields[4]
		}
		next = end + 1
	}
	output << stderr[next..]
	return output.join(''), events
}

fn first_divergence(target []TraceEvent, reference []TraceEvent) !Divergence {
	if target.len == 0 || reference.len == 0 {
		return error('both executions must log comparable scalar checkpoints')
	}
	mut i := 0
	for i < target.len && i < reference.len && target[i] == reference[i] {
		i++
	}
	if i == target.len && i == reference.len {
		return error('the observed scalar checkpoints agree')
	}
	if i == 0 && !same_site(target[0], reference[0]) {
		return error('the two executions began at different trace sites')
	}
	return Divergence{
		target:      if i < target.len { ?TraceEvent(target[i]) } else { none }
		reference:   if i < reference.len { ?TraceEvent(reference[i]) } else { none }
		last_common: if i > 0 { ?TraceEvent(target[i - 1]) } else { none }
	}
}

fn same_site(a TraceEvent, b TraceEvent) bool {
	return a.file == b.file && a.line == b.line && a.column == b.column && a.kind == b.kind
}
