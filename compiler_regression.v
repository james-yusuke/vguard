module main

import json2
import os

struct RegressionCompiler {
	label string
	path  string
}

struct CompilerRegressionSeries {
	build     BuildOptions
	compilers []RegressionCompiler
}

struct CompilerRegressionProbe {
	sample  RegressionSample
	outcome Outcome
	reason  string
}

fn compiler_regression_path(root string, path string) !string {
	if path == '' || path.contains_any('\x00\r\n') {
		return error('missing or invalid path in compiler regression series')
	}
	return os.real_path(if os.is_abs_path(path) { path } else { os.join_path(root, path) })
}

fn load_compiler_regression(path string) !CompilerRegressionSeries {
	if os.file_size(path) > u64(capture_limit) {
		return error('compiler regression series exceeds the input limit')
	}
	series := json2.decode[CompilerRegressionSeries](os.read_file(path)!)!
	root := os.dir(os.abs_path(path))
	if series.compilers.len < 2 || series.build.memory || series.build.trace_runtime
		|| series.build.trace_hangs || series.build.hot_fn != '' || series.build.object
		|| series.build.args.any(it in ['-shared', '--shared']) {
		return error('compiler regression needs two or more compiler versions and one standalone build configuration')
	}
	mut labels := map[string]bool{}
	mut compilers := []RegressionCompiler{cap: series.compilers.len}
	for item in series.compilers {
		if item.label.trim_space() == '' || item.label.contains_any('\x00\r\n') || item.label in labels {
			return error('compiler regression labels must be nonempty, unique and on a single line')
		}
		labels[item.label] = true
		compilers << RegressionCompiler{ label: item.label, path: compiler_regression_path(root, item.path)! }
	}
	return CompilerRegressionSeries{
		build:     BuildOptions{ ...series.build, source: compiler_regression_path(root, series.build.source)! }
		compilers: compilers
	}
}

fn probe_compiler_regression(series CompilerRegressionSeries, index int, scenario ExecutionCase, work string, source_hash string, options ExitComparisonOptions) !CompilerRegressionProbe {
	item := series.compilers[index]
	path := build(BuildOptions{ ...series.build, compiler: item.path }, os.join_path(work, '${index}'), false) or {
		return CompilerRegressionProbe{ sample: RegressionSample{ label: item.label, result: 'inconclusive' }, reason: err.msg() }
	}
	bundle := open_bundle(path)!
	if bundle.manifest.source_sha256 != source_hash {
		return error('V source changed during compiler regression search')
	}
	observation := observe_regression_build(bundle, scenario, options)
	return CompilerRegressionProbe{
		sample:  RegressionSample{
			label:         item.label
			build:         compared_build(bundle.manifest)
			runs:          observation.runs
			result:        if observation.reason == '' { 'observed' } else { 'inconclusive' }
			stdout_sha256: if observation.reason == '' {
				digest(observation.outcome.stdout.bytes())
			} else {
				''
			}
			stderr_sha256: if observation.reason == '' {
				digest(observation.outcome.stderr.bytes())
			} else {
				''
			}
			exit_code:     if options.include_exits && observation.reason == '' {
				?int(observation.outcome.exit_code)
			} else {
				none
			}
		}
		outcome: observation.outcome
		reason:  observation.reason
	}
}

fn find_compiler_regression(series CompilerRegressionSeries, scenario ExecutionCase, options ExitComparisonOptions) !RegressionReport {
	if scenario.harness != '' {
		return error('compiler regression requires standalone runs')
	}
	work := temp_directory()!
	defer { os.rmdir_all(work) or {} }
	source_hash := source_digest(series.build.source, work)!
	baseline := probe_compiler_regression(series, 0, scenario, work, source_hash, options)!
	initial := RegressionReport{
		evidence:   if options.include_exits {
			'ordered_repeated_output_and_exit_status'
		} else {
			'ordered_repeated_output'
		}
		method:     'compiler_bisection'
		assumption: 'the tested behavior changes once in the supplied compiler order'
		baseline:   baseline.sample.label
		samples:    [baseline.sample]
	}
	if baseline.reason != '' {
		return RegressionReport{ ...initial, kind: 'inconclusive', reason: baseline.reason }
	}
	mut lo := 0
	mut hi := series.compilers.len - 1
	mut pending := hi
	mut differences := Outcome{}
	mut samples := [RegressionSample{ ...baseline.sample, result: 'baseline' }]
	for {
		probe := probe_compiler_regression(series, pending, scenario, work, source_hash, options)!
		if probe.reason != '' {
			samples << probe.sample
			return RegressionReport{ ...initial, kind: 'inconclusive', reason: probe.reason, samples: samples }
		}
		matches := same_outcome(baseline.outcome, probe.outcome)
		samples << RegressionSample{
			...probe.sample
			result: if matches {
				'matches'
			} else {
				'changed'
			}
		}
		if matches && pending == series.compilers.len - 1 {
			return RegressionReport{ ...initial, kind: 'unchanged', last_matching: probe.sample.label, samples: samples }
		}
		if matches {
			lo = pending
		} else {
			hi = pending
			differences = probe.outcome
		}
		if hi - lo == 1 {
			break
		}
		pending = lo + (hi - lo) / 2
	}
	return RegressionReport{
		...initial
		kind:                    'changed'
		last_matching:           series.compilers[lo].label
		first_changed:           series.compilers[hi].label
		first_stdout_difference: first_byte_difference(baseline.outcome.stdout, differences.stdout)
		first_stderr_difference: first_byte_difference(baseline.outcome.stderr, differences.stderr)
		samples:                 samples
	}
}
