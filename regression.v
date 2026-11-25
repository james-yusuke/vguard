module main

import json2
import os
import strings

struct RegressionBuildSpec {
	label    string
	manifest string
}

struct RegressionSeries {
	builds []RegressionBuildSpec
}

struct RegressionSample {
	label         string
	build         ComparedBuild
	runs          int
	result        string
	stdout_sha256 string @[omitempty]
	stderr_sha256 string @[omitempty]
}

struct RegressionReport {
	evidence                string = 'ordered_repeated_output'
	kind                    string
	reason                  string @[omitempty]
	baseline                string
	last_matching           string @[omitempty]
	first_changed           string @[omitempty]
	first_stdout_difference ?int   @[omitempty]
	first_stderr_difference ?int   @[omitempty]
	samples                 []RegressionSample
}

struct RegressionObservation {
	outcome Outcome
	runs    int
	reason  string
}

fn load_regression_series(path string) !RegressionSeries {
	series := json2.decode[RegressionSeries](os.read_file(path)!)!
	if series.builds.len < 2 {
		return error('regress requires at least two ordered build manifests')
	}
	dir := os.dir(os.abs_path(path))
	mut labels := map[string]bool{}
	mut builds := []RegressionBuildSpec{cap: series.builds.len}
	for item in series.builds {
		if item.label.trim_space() == '' || item.label.contains_any('\r\n\x00')
			|| item.manifest == '' || item.manifest.contains('\x00') {
			return error('each regression entry requires a one-line label and a manifest path')
		}
		if item.label in labels {
			return error('duplicate regression label: ${item.label}')
		}
		labels[item.label] = true
		builds << RegressionBuildSpec{
			label:    item.label
			manifest: if os.is_abs_path(item.manifest) {
				item.manifest
			} else {
				os.join_path(dir, item.manifest)
			}
		}
	}
	return RegressionSeries{
		builds: builds
	}
}

fn observe_regression_build(bundle Bundle, scenario ExecutionCase) RegressionObservation {
	mut runs := 0
	first := run_for_comparison(bundle, scenario) or {
		return RegressionObservation{ reason: err.msg() }
	}
	runs++
	if first.status != 'exited' || first.exit_code != 0 {
		return RegressionObservation{
			runs:   runs
			reason: 'first execution reported ${first.status} (exit code ${first.exit_code})'
		}
	}
	second := run_for_comparison(bundle, scenario) or {
		return RegressionObservation{ runs: runs, reason: err.msg() }
	}
	runs++
	if second.status != 'exited' || second.exit_code != 0 {
		return RegressionObservation{
			runs:   runs
			reason: 'second execution reported ${second.status} (exit code ${second.exit_code})'
		}
	}
	if !same_outcome(first, second) {
		return RegressionObservation{
			runs:   runs
			reason: 'the two executions produced different output'
		}
	}
	return RegressionObservation{ outcome: first, runs: runs }
}

fn find_regression(series RegressionSeries, scenario ExecutionCase) !RegressionReport {
	if scenario.harness != '' {
		return error('regress requires standalone builds')
	}
	mut baseline := Outcome{}
	mut source_hash := ''
	mut last_matching := ''
	mut samples := []RegressionSample{}
	for index, item in series.builds {
		bundle := open_bundle(item.manifest) or { return error('${item.label}: ${err.msg()}') }
		if bundle.manifest.options.memory || bundle.image.relocatable || !bundle.image.runnable {
			return error('${item.label}: regress requires a standalone runnable build without sanitizer instrumentation')
		}
		hash := bundle.manifest.source_sha256
		if index == 0 {
			source_hash = hash
		}
		if hash == '' || hash != source_hash {
			return error('${item.label}: regress requires a common recorded source fingerprint')
		}
		observed := observe_regression_build(bundle, scenario)
		identity := compared_build(bundle.manifest)
		if observed.reason != '' {
			samples << RegressionSample{
				label:  item.label
				build:  identity
				runs:   observed.runs
				result: 'inconclusive'
			}
			return RegressionReport{
				kind:          'inconclusive'
				reason:        observed.reason
				baseline:      series.builds[0].label
				last_matching: last_matching
				samples:       samples
			}
		}
		if index == 0 {
			baseline = observed.outcome
		}
		matches := same_outcome(baseline, observed.outcome)
		samples << RegressionSample{
			label:         item.label
			build:         identity
			runs:          observed.runs
			result:        if index == 0 {
				'baseline'
			} else if matches {
				'matches'
			} else {
				'changed'
			}
			stdout_sha256: digest(observed.outcome.stdout.bytes())
			stderr_sha256: digest(observed.outcome.stderr.bytes())
		}
		if !matches {
			return RegressionReport{
				kind:                    'changed'
				baseline:                series.builds[0].label
				last_matching:           last_matching
				first_changed:           item.label
				first_stdout_difference: first_byte_difference(baseline.stdout, observed.outcome.stdout)
				first_stderr_difference: first_byte_difference(baseline.stderr, observed.outcome.stderr)
				samples:                 samples
			}
		}
		last_matching = item.label
	}
	return RegressionReport{
		kind:          'unchanged'
		baseline:      series.builds[0].label
		last_matching: last_matching
		samples:       samples
	}
}

fn format_regression(report RegressionReport) string {
	mut out := strings.new_builder(256)
	out.writeln(match report.kind {
		'changed' { 'First observed output change' }
		'unchanged' { 'All recorded builds matched the baseline output' }
		else { 'Output comparison is inconclusive' }
	})
	for sample in report.samples {
		out.writeln('  ${sample.label} (${sample.build.backend}, ${sample.build.target}, prod=${sample.build.prod}): ${sample.result} after ${sample.runs} executions')
	}
	if report.reason != '' {
		out.writeln('  = reason: ${report.reason}')
	}
	if offset := report.first_stdout_difference {
		out.writeln('  = first stdout difference at byte ${offset}')
	}
	if offset := report.first_stderr_difference {
		out.writeln('  = first stderr difference at byte ${offset}')
	}
	return out.str()
}
