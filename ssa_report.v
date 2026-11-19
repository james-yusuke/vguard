module main

import json2
import os
import rand

struct SsaExcerpt {
	original  string
	annotated string
}

fn (bundle &Bundle) with_crash_ssa(report Diagnosis) Diagnosis {
	if report.kind != 'crash' {
		return report
	}
	location := report.location or { return report }
	if location.ssa_value < 0 || location.ssa_opcode == '' {
		return report
	}
	excerpt := bundle.read_crash_ssa(location) or {
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

fn (bundle &Bundle) read_crash_ssa(location Location) !SsaExcerpt {
	if bundle.ssa_sha256 == '' {
		return error('build has no SSA snapshot; rebuild with a compiler that supports SSA snapshots')
	}
	data := os.read_bytes(bundle.ssa_path)!
	if digest(data) != bundle.ssa_sha256 {
		return error('SSA snapshot SHA-256 does not match the source map')
	}
	return crash_ssa_excerpt(data.bytestr(), location)
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
	header := '; VGuard crash SSA\n; Stop: ${json2.encode(report.reason)}\n' +
		'; Stopped at: ${report.address}\n; V source: ${location_text(location)}\n\n'
	os.write_file(original_path, excerpt.original)!
	os.write_file(annotated_path, header + excerpt.annotated)!
	saved = true
	return original_path, annotated_path
}

fn crash_ssa_excerpt(snapshot string, location Location) !SsaExcerpt {
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
	return SsaExcerpt{
		original:  snapshot[start + 1..end + 3]
		annotated: snapshot[start + 1..line_end] + '  ; <<< ${label}' + snapshot[line_end..end + 3]
	}
}
