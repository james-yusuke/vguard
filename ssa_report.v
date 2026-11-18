module main

import json2
import os
import rand

fn (bundle &Bundle) with_crash_ssa(report Diagnosis) Diagnosis {
	if report.kind != 'crash' {
		return report
	}
	location := report.location or { return report }
	if location.ssa_value < 0 || location.ssa_opcode == '' {
		return report
	}
	path := bundle.write_crash_ssa(report, location) or {
		return Diagnosis{
			...report
			ssa_error: err.msg()
		}
	}
	return Diagnosis{
		...report
		ssa_file: path
	}
}

fn (bundle &Bundle) write_crash_ssa(report Diagnosis, location Location) !string {
	if bundle.ssa_sha256 == '' {
		return error('build has no SSA snapshot; rebuild with a compiler that supports SSA snapshots')
	}
	data := os.read_bytes(bundle.ssa_path)!
	if digest(data) != bundle.ssa_sha256 {
		return error('SSA snapshot SHA-256 does not match the source map')
	}
	body := mark_ssa_instruction(data.bytestr(), location)!
	base := os.join_path(os.dir(bundle.ssa_path), 'diagnostics')
	os.mkdir(base) or {
		if !os.is_dir(base) {
			return err
		}
	}
	dir := os.join_path(base, 'crash-' + rand.uuid_v4())
	os.mkdir(dir)!
	path := os.join_path(dir, 'crash.ssa')
	header := '; VGuard crash SSA\n; Stop: ${json2.encode(report.reason)}\n' +
		'; Stopped at: ${report.address}\n; V source: ${location_text(location)}\n\n'
	os.write_file(path, header + body) or {
		os.rm(path) or {}
		os.rmdir(dir) or {}
		return err
	}
	return path
}

fn mark_ssa_instruction(snapshot string, location Location) !string {
	// ValueIDs are unique across the module and shared with the byte ranges.
	prefix := '\n  %${location.ssa_value} = ${location.ssa_opcode} '
	hit := snapshot.index(prefix) or { return error('mapped instruction is missing from the SSA snapshot') }
	start := snapshot[..hit].last_index('\nfn ') or { return error('SSA function header is missing') }
	end := snapshot.index_after('\n}\n', hit) or { return error('SSA function body is incomplete') }
	return snapshot[start + 1..hit + 1] + '  ; >>> SSA instruction mapped from the crash (${location.precision})\n' +
		snapshot[hit + 1..end + 3]
}
