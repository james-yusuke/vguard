module main

import encoding.utf8.east_asian
import json2
import os
import strings

fn (bundle &Bundle) diagnostic_source_error() string {
	expected := bundle.manifest.source_sha256
	if expected == '' {
		return ''
	}
	actual := source_digest(bundle.manifest.options.source, os.dir(bundle.ssa_path)) or {
		return 'the source used for this build is unavailable'
	}
	return if actual != expected { 'the source has changed since the build' } else { '' }
}

fn diagnostic_path(file string) string {
	prefix := os.getwd().trim_string_right(os.path_separator) + os.path_separator
	return file.trim_string_left(prefix)
}

fn diagnostic_location_text(location Location) string {
	mut result := diagnostic_path(location.file)
	if location.line > 0 {
		result += ':${location.line}'
		if location.column > 0 {
			result += ':${location.column}'
		}
	}
	return result
}

fn diagnostic_source_lines(location Location, source_error string) ![]string {
	if source_error != '' {
		return error(source_error)
	}
	if !os.is_file(location.file) {
		return error('source file is unavailable')
	}
	if os.file_size(location.file) > u64(capture_limit) {
		return error('source file exceeds the excerpt size limit')
	}
	source := os.read_file(location.file)!
	lines := source.split_into_lines()
	if location.line > lines.len {
		return error('the reported line is outside the source file')
	}
	return lines
}

@[params]
struct DiagnosticLocationOptions {
	ssa_issue string
}

fn write_diagnostic_location(mut out strings.Builder, location Location, label string, source_error string, options DiagnosticLocationOptions) {
	if location.file != '' {
		address := diagnostic_location_text(location)
		if location.line <= 0 {
			out.writeln(' --> ${address}')
		} else {
			if source := diagnostic_source_lines(location, source_error) {
				write_diagnostic_excerpt(mut out, source, location, address, label)
			} else {
				out.writeln(' --> ${address}')
				out.writeln('  = ${label}')
				out.writeln('  = note: source excerpt unavailable (${err.msg()})')
			}
		}
	}
	if location.function != '' {
		out.writeln('  = function: ${location.function}')
	}
	if location.ssa_value >= 0 {
		out.write_string('  = SSA: %${location.ssa_value} ${location.ssa_opcode}'.trim_right(' '))
		if location.ssa_opcode != '' && options.ssa_issue != '' {
			out.write_string(' << ${ssa_comment_text(options.ssa_issue)}')
		}
		out.writeln('')
	}
}

fn write_diagnostic_excerpt(mut out strings.Builder, lines []string, location Location, address string, label string) {
	first := if location.line > 2 { location.line - 2 } else { 1 }
	last := if location.line + 2 < lines.len { location.line + 2 } else { lines.len }
	width := last.str().len
	gutter := ' '.repeat(width + 2) + '|'
	line := lines[location.line - 1]
	offset := if location.column > 0 { location.column - 1 } else { -1 }
	// The map stores one-based byte columns, so measure display cells only after slicing.
	has_column := location.column > 0 && offset <= line.len
		&& (offset == line.len || line[offset] & 0xc0 != 0x80)
	out.writeln('${' '.repeat(width)}--> ${address}')
	out.writeln(gutter)
	for number in first .. last + 1 {
		active := number == location.line
		marker := if active && !has_column { '>' } else { ' ' }
		source := lines[number - 1].normalize_tabs(4)
		out.writeln('${marker}${strings.pad_left(number.str(), width, ' ')} | ${source}'.trim_right(' '))
		if active {
			if has_column {
				cells := east_asian.display_width(line[..offset].normalize_tabs(4), 1)
				out.writeln('${gutter} ${' '.repeat(cells)}^ ${label}')
			} else {
				out.writeln('${gutter} ${label}')
			}
		}
	}
}

fn (bundle &Bundle) format_resolution(location Location) string {
	mut out := strings.new_builder(256)
	out.writeln('note: instruction resolved')
	write_diagnostic_location(mut out, location, 'instruction mapped here', bundle.diagnostic_source_error())
	return out.str()
}

fn (bundle &Bundle) format_diagnosis(report Diagnosis) string {
	mut out := strings.new_builder(512)
	if report.memory_errors.len > 0 {
		source_error := bundle.diagnostic_source_error()
		for finding in report.memory_errors {
			write_memory_diagnostic(mut out, finding, source_error)
		}
	} else {
		match report.kind {
			'crash' {
				out.writeln(report.crash_error())
			}
			'exited' {
				if report.outcome.exit_code == 0 {
					return 'VGuard: exited successfully\n'
				}
				out.writeln('error[exit]: program exited with code ${report.outcome.exit_code}')
			}
			else {
				reason := if report.reason != '' {
					report.reason
				} else {
					match report.kind {
						'timeout' { 'program exceeded the time limit' }
						'output_limit' { 'program exceeded the output capture limit' }
						else { 'could not complete the diagnosis' }
					}
				}
				out.writeln('error[${report.kind}]: ${reason}')
			}
		}
		if location := report.location {
			label := if location.precision == 'caller_frame' {
				'first mapped V caller frame'
			} else {
				'stop mapped here'
			}
			ssa_issue := if report.kind == 'crash' {
				ssa_issue_reason(location, report.crash_reason())
			} else {
				''
			}
			write_diagnostic_location(mut out, location, label, bundle.diagnostic_source_error(),
				ssa_issue: ssa_issue
			)
		}
		if report.address != '' {
			out.writeln('  = stop address: ${report.address}')
		}
	}
	if report.location_error != '' {
		out.writeln('  = note: ${report.location_error}')
	}
	if report.ssa_file != '' {
		out.writeln('  = original SSA: ${report.ssa_original_file}')
		out.writeln('  = annotated SSA: ${report.ssa_file}')
	}
	if report.ssa_error != '' {
		out.writeln('  = note: SSA report (${report.ssa_error})')
	}
	if report.ssa_excerpt.original != '' {
		out.writeln('\nSSA (original)')
		out.write_string(report.ssa_excerpt.original)
		out.writeln('\nSSA (annotated)')
		out.write_string(report.ssa_excerpt.annotated)
	}
	return out.str()
}

fn write_memory_diagnostic(mut out strings.Builder, finding MemoryViolation, source_error string) {
	detector := if finding.sanitizer == 'asan' {
		'AddressSanitizer'
	} else {
		'UndefinedBehaviorSanitizer'
	}
	size := match finding.size_bytes {
		1 { ' of 1 byte' }
		else {
			if finding.size_bytes > 0 { ' of ${finding.size_bytes} bytes' } else { '' }
		}
	}
	address := if finding.address != '' { ' at ${finding.address}' } else { '' }
	access := if finding.access != '' {
		finding.access
	} else if finding.sanitizer == 'ubsan' && finding.message != '' {
		finding.message
	} else {
		'invalid memory operation'
	}
	out.writeln('error[${finding.kind}]: ${access}${size}${address}')
	if location := finding.location {
		write_diagnostic_location(mut out, location, 'reported here', source_error)
	}
	out.writeln('  = detector: ${detector}')
	if location := finding.allocation {
		out.writeln('note: allocation site')
		write_diagnostic_location(mut out, location, 'allocated here', source_error)
	}
	if location := finding.deallocation {
		out.writeln('note: deallocation site')
		write_diagnostic_location(mut out, location, 'freed here', source_error)
	}
}

fn trace_location(event TraceEvent) Location {
	return Location{ file: event.file, line: event.line, column: event.column }
}

fn trace_description(event TraceEvent) string {
	return '${event.kind} = ${event.value}'
}

fn write_trace_difference(mut out strings.Builder, diff Divergence, source_error string) {
	if target := diff.target {
		if reference := diff.reference {
			if same_site(target, reference) {
				write_diagnostic_location(mut out, trace_location(target), 'first differing trace event',
					source_error)
				out.writeln('  = target: ${trace_description(target)}')
				out.writeln('  = reference: ${trace_description(reference)}')
				return
			}
		}
		write_diagnostic_location(mut out, trace_location(target),
			'target first differs here (${trace_description(target)})', source_error)
	}
	if reference := diff.reference {
		write_diagnostic_location(mut out, trace_location(reference),
			'reference first differs here (${trace_description(reference)})', source_error)
	}
}

fn (bundle &Bundle) format_comparison(report Comparison) string {
	if report.kind == 'equal' {
		return 'VGuard: target and reference agree\n'
	}
	mut out := strings.new_builder(512)
	out.writeln(if report.kind == 'different' {
		'error[comparison]: target and reference results differ'
	} else {
		'error[comparison]: comparison is inconclusive'
	})
	if diff := report.divergence {
		write_trace_difference(mut out, diff, bundle.diagnostic_source_error())
	}
	if report.location_error != '' {
		out.writeln('  = note: ${report.location_error}')
	}
	if report.target.stdout != report.reference.stdout {
		out.writeln('  = target stdout: ${json2.encode(report.target.stdout)}')
		out.writeln('  = reference stdout: ${json2.encode(report.reference.stdout)}')
	}
	if report.target.stderr != report.reference.stderr {
		out.writeln('  = target stderr: ${json2.encode(report.target.stderr)}')
		out.writeln('  = reference stderr: ${json2.encode(report.reference.stderr)}')
	}
	if report.target.exit_code != report.reference.exit_code || report.target.status != report.reference.status {
		out.writeln('  = target status: ${report.target.status} (${report.target.exit_code})')
		out.writeln('  = reference status: ${report.reference.status} (${report.reference.exit_code})')
	}
	return out.str()
}
