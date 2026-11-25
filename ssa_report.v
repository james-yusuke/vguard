module main

import json2
import os
import rand

struct SsaExcerpt {
	original       string
	annotated      string
	dump           string
	annotated_dump string
}

fn (report Diagnosis) crash_reason() string {
	return if report.reason == '' { 'program stopped unexpectedly' } else { report.reason }
}

fn (report Diagnosis) crash_error() string {
	return 'error[crash]: ${report.crash_reason()}'
}

fn ssa_issue_reason(location Location, reason string) string {
	return if location.precision == 'caller_frame' {
		'${reason} (first mapped V caller frame)'
	} else {
		reason
	}
}

fn ssa_comment_text(text string) string {
	// Use the same escaping as SSA string operands to keep a diagnostic on one line.
	quoted := json2.encode(text)
	return quoted[1..quoted.len - 1]
}

fn (bundle &Bundle) with_crash_ssa(report Diagnosis) Diagnosis {
	if report.kind != 'crash' {
		return report
	}
	location := report.location or { return report }
	if location.ssa_value < 0 || location.ssa_opcode == '' {
		return report
	}
	excerpt := bundle.read_crash_ssa(location, report.crash_reason()) or {
		return Diagnosis{
			...report
			ssa_error: err.msg()
		}
	}
	original_path, annotated_path := bundle.write_crash_ssa(report, location, excerpt) or {
		return Diagnosis{
			...report
			ssa_error:   err.msg()
			ssa_excerpt: excerpt
		}
	}
	return Diagnosis{
		...report
		ssa_file:          annotated_path
		ssa_original_file: original_path
		ssa_excerpt:       excerpt
	}
}

fn (bundle &Bundle) read_crash_ssa(location Location, reason string) !SsaExcerpt {
	if bundle.ssa_sha256 == '' {
		return error('build has no SSA snapshot; rebuild with a compiler that supports SSA snapshots')
	}
	data := os.read_bytes(bundle.ssa_path)!
	if digest(data) != bundle.ssa_sha256 {
		return error('SSA snapshot SHA-256 does not match the source map')
	}
	return crash_ssa_excerpt(data.bytestr(), location, reason)
}

fn (bundle &Bundle) write_crash_ssa(report Diagnosis, location Location, excerpt SsaExcerpt) !(string, string) {
	base := os.join_path(os.dir(bundle.ssa_path), 'diagnostics')
	os.mkdir(base) or {
		if !os.is_dir(base) {
			return err
		}
	}
	dir := os.join_path(base, 'crash-' + rand.uuid_v4())
	os.mkdir(dir)!
	mut saved := false
	defer {
		if !saved {
			os.rmdir_all(dir) or {}
		}
	}
	original_path := os.join_path(dir, 'original.ssa')
	annotated_path := os.join_path(dir, 'crash.ssa')
	os.write_file(original_path, if excerpt.dump != '' { excerpt.dump } else { excerpt.original })!
	os.write_file(annotated_path, format_crash_ssa(report, location, excerpt))!
	saved = true
	return original_path, annotated_path
}

fn format_crash_ssa(report Diagnosis, location Location, excerpt SsaExcerpt) string {
	mut header := '; VGuard crash SSA\n; ${ssa_comment_text(report.crash_error())}\n'
	if report.address != '' {
		header += '; Stopped at: ${ssa_comment_text(report.address)}\n'
	}
	header += '; V source: ${ssa_comment_text(location_text(location))}\n'
	if report.ssa_error != '' {
		header += '; SSA report: ${ssa_comment_text(report.ssa_error)}\n'
	}
	body := if excerpt.annotated_dump != '' { excerpt.annotated_dump } else { excerpt.annotated }
	return header + '\n' + body
}

fn (bundle &Bundle) format_ssa_diagnosis(report Diagnosis) string {
	if location := report.location {
		if report.ssa_excerpt.annotated != '' {
			return format_crash_ssa(report, location, report.ssa_excerpt)
		}
	}
	// Preserve the available diagnosis as comments when there is no mapped IR.
	return bundle.format_diagnosis(report).trim_right('\n').split('\n').map('; ${ssa_comment_text(it)}').join('\n') + '\n'
}

fn crash_ssa_excerpt(snapshot string, location Location, reason string) !SsaExcerpt {
	if snapshot.starts_with('; VGuard SSA v2\n') {
		return crash_ssa_dump_excerpt(snapshot, location, reason)
	}
	// ValueIDs are unique across the module and shared with the byte ranges.
	prefix := '\n  %${location.ssa_value} = ${location.ssa_opcode} '
	hit := snapshot.index(prefix) or { return error('mapped instruction is missing from the SSA snapshot') }
	start := snapshot[..hit].last_index('\nfn ') or { return error('SSA function header is missing') }
	end := snapshot.index_after('\n}\n', hit) or { return error('SSA function body is incomplete') }
	line_end := snapshot.index_after('\n', hit + 1) or { return error('SSA instruction line is incomplete') }
	label := if location.precision == 'caller_frame' {
		'first mapped V caller frame'
	} else {
		'stop mapped here'
	}
	annotation := '  ; <<< ${label}. error[crash]: ${ssa_comment_text(reason)}'
	return SsaExcerpt{
		original:  snapshot[start + 1..end + 3]
		annotated: snapshot[start + 1..line_end] + annotation + snapshot[line_end..end + 3]
	}
}

fn crash_ssa_dump_excerpt(snapshot string, location Location, reason string) !SsaExcerpt {
	prefix := '\nSSA ${location.ssa_value} ${location.ssa_opcode} typ='
	hit := snapshot.index(prefix) or { return error('mapped instruction is missing from the SSA snapshot') }
	start := snapshot[..hit].last_index('\nSSA function ') or { return error('SSA function header is missing') }
	line_end := snapshot.index_after('\n', hit + 1) or { return error('SSA instruction line is incomplete') }
	next_function := snapshot.index_after('\nSSA function ', line_end) or { snapshot.len - 1 }
	end := next_function + 1
	marker := ' << ${ssa_comment_text(ssa_issue_reason(location, reason))}'
	return SsaExcerpt{
		original:       snapshot[start + 1..end]
		annotated:      snapshot[start + 1..line_end] + marker + snapshot[line_end..end]
		dump:           snapshot
		annotated_dump: snapshot[..line_end] + marker + snapshot[line_end..]
	}
}
