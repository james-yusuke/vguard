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
	for lines.len > 1 {
		chunk := (lines.len + groups - 1) / groups
		mut changed := false
		for start := 0; start < lines.len; start += chunk {
			end := if start + chunk < lines.len { start + chunk } else { lines.len }
			if attempts >= budget {
				return LineReduction{ source: best, lines: lines.len, attempts: attempts }
			}
			mut candidate := lines[..start].clone()
			candidate << lines[end..]
			body := candidate.join('\n') + '\n'
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

fn check_reduction(source string, filename string, builds []BuildOptions, expected []Outcome, scenario ExecutionCase, repeats int) !bool {
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
			if outcome.status != 'exited' || outcome.exit_code != 0 {
				return error('source reduction stopped after a candidate reported ${outcome.status} (${outcome.exit_code})')
			}
			if !same_outcome(expected[index], outcome) {
				return false
			}
		}
	}
	return true
}

fn minimize_output_difference(target Bundle, reference Bundle, scenario ExecutionCase, out string, attempts int) !string {
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
		if bundle.manifest.options.memory || bundle.image.relocatable || !bundle.image.runnable {
			return error('minimize requires standalone runnable builds without sanitizer instrumentation')
		}
		validate_comparison_inputs(bundle)!
		observation := observe_regression_build(bundle, scenario)
		if observation.reason != '' {
			return error('minimize requires two repeatable successful executions: ${observation.reason}')
		}
		expected << observation.outcome
	}
	if same_outcome(expected[0], expected[1]) {
		return error('the two builds have identical output')
	}
	input := os.read_file(options.source)!
	filename := os.file_name(options.source)
	builds := [options, reference_options]
	if !check_reduction(input, filename, builds, expected, scenario, 1)! {
		return error('the output difference does not reproduce from a staged copy of the source')
	}

	reduced := reduce_lines(input, attempts, fn [filename, builds, expected, scenario] (candidate string) !bool {
		return check_reduction(candidate, filename, builds, expected, scenario, 1)
	})!
	if !check_reduction(reduced.source, filename, builds, expected, scenario, 2)! {
		return error('the final reduction did not reproduce both successful outputs on repeat runs')
	}

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
		file:                          filename
		original_lines:                input.split_into_lines().len
		reduced_lines:                 reduced.lines
		attempts:                      reduced.attempts
		single_line_deletions_checked: reduced.complete
	}, prettify: true) + '\n')!
	saved = true
	return path
}
