module main

import crypto.sha256
import json2
import os

fn test_fuel_option_requires_positive_u64() {
	assert (parse_fuel('100000') or { panic(err) }) == u64(100000)
	assert (parse_fuel('18446744073709551615') or { panic(err) }) == u64(18446744073709551615)
	for invalid in ['0', '', '-1', '1.5', '18446744073709551616'] {
		parse_fuel(invalid) or { continue }
		assert false, invalid
	}
}

fn test_wasm_fuel_limit_requires_the_final_trap_cause() {
	base := Diagnosis{
		kind:    'crash'
		address: '0x23'
		outcome: Outcome{
			status:    'exited'
			exit_code: 1
			stderr:    '2: wasm trap: all fuel consumed by WebAssembly\n'
		}
	}
	assert with_wasm_limit(base, 0, 500).kind == 'crash'
	assert !json2.encode(with_wasm_limit(base, 0, 500)).contains('"execution_limit"')
	limited := with_wasm_limit(base, 1000, 500)
	assert limited.kind == 'fuel_exhausted'
	assert limited.address == '0x23'
	trap := Diagnosis{
		...base
		outcome: Outcome{ ...base.outcome, stderr: base.outcome.stderr + '3: wasm trap: unreachable\n' }
	}
	assert with_wasm_limit(trap, 1000, 500).kind == 'crash'
	timed := with_wasm_limit(Diagnosis{ kind: 'timeout' }, 1000, 500)
	limit := timed.execution_limit or { panic('missing wall time limit') }
	assert timed.kind == 'timeout'
	assert limit.kind == 'wall_time_ms'
	assert limit.limit == 500
}

fn test_terminal_diagnosis_places_the_caret_after_tabs_and_wide_characters() {
	dir := temp_directory() or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'sample.v')
	line := '\tprintln("幅"); stop()'
	os.write_file(path, 'fn main() {\n${line}\n}\n') or { panic(err) }
	column := (line.index('stop') or { panic('missing test token') }) + 1
	report := Diagnosis{
		kind:     'crash'
		reason:   'signal SIGABRT'
		address:  '0x1234'
		location: Location{
			file:       path
			function:   'main'
			line:       2
			column:     column
			ssa_value:  5
			ssa_opcode: 'call'
			precision:  'caller_frame'
		}
	}
	text := Bundle{}.format_diagnosis(report)
	assert text.starts_with('error[crash]: signal SIGABRT\n')
	assert text.contains('${path}:2:${column}')
	assert text.contains(' 2 |     println("幅"); stop()\n   | ' + ' '.repeat(19) +
		'^ first mapped V caller frame')
	assert text.contains('  = SSA: %5 call << signal SIGABRT (first mapped V caller frame)\n')
	assert text.contains('  = stop address: 0x1234')
}

fn test_terminal_resolution_keeps_the_location_when_source_is_stale_or_missing() {
	dir := temp_directory() or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'sample.v')
	new_source := 'fn changed() {}\n'
	os.write_file(path, new_source) or { panic(err) }
	location := Location{ file: path, line: 1, column: 1 }
	stale := Bundle{
		manifest: Manifest{
			options:       BuildOptions{ source: path }
			source_sha256: digest('fn original() {}\n'.bytes())
		}
	}.format_resolution(location)
	assert stale.contains('${path}:1:1')
	assert stale.contains('the source has changed since the build')
	assert !stale.contains('fn changed()')
	os.rm(path) or { panic(err) }
	missing := Bundle{}.format_resolution(location)
	assert missing.contains('${path}:1:1')
	assert missing.contains('source file is unavailable')
}

fn test_raw_code_range_uses_half_open_offsets() {
	img := image([]u8{len: 12}, 'raw-arm64') or { panic(err) }
	ranges := placed_ranges(img, [
		RawRange{
			start:    4
			end:      8
			function: 'compute'
			op:       'add'
			value:    7
			file:     'a.v'
			line:     3
			column:   9
		},
	]) or { panic(err) }
	bundle := Bundle{
		image:  img
		ranges: ranges
	}
	location := bundle.resolve_address(4) or { panic(err) }
	assert location.file == 'a.v'
	assert location.ssa_value == 7
	assert bundle.match_range(1, 7) != none
	assert bundle.match_range(1, 8) == none
}

fn test_wasm_offsets_include_section_and_local_declaration_lengths() {
	wasm := [u8(0), 97, 115, 109, 1, 0, 0, 0, 10, 7, 1, 5, 1, 1, 127, 0, 11]
	img := image(wasm, 'wasm') or { panic(err) }
	assert img.wasm_bodies[0].address == 15
	assert img.wasm_code_offset == 10
	ranges := placed_ranges(img, [
		RawRange{ body: 0, start: 0, end: 1, op: 'unreachable' },
	]) or { panic(err) }
	bundle := Bundle{
		image:  img
		ranges: ranges
	}
	location := bundle.resolve_address(15) or { panic(err) }
	assert location.ssa_opcode == 'unreachable'
}

fn test_truncated_and_overlapping_binary_ranges_are_rejected() {
	image([u8(0x7f), 0x45, 0x4c, 0x46], 'elf') or { assert err.msg().contains('outside') }
	img := image([]u8{len: 12}, 'raw-arm64') or { panic(err) }
	placed_ranges(img, [RawRange{ start: 4, end: 8 }, RawRange{ start: 5, end: 9 }]) or {
		assert err.msg().contains('overlapping')
		return
	}
	assert false
}

fn test_manifest_rejects_a_stale_source_map() {
	dir := temp_directory() or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	artifact := os.join_path(dir, 'program.code')
	source_map := os.join_path(dir, 'program.vgmap.json')
	bytes := [u8(0), 0, 0, 0]
	os.write_file_array(artifact, bytes) or { panic(err) }
	os.write_file(source_map, json2.encode(SourceMap{
		version: 1
		sha256:  sha256.sum256([u8(0), 0, 0, 1]).hex()
	})) or { panic(err) }
	read_bundle(Manifest{
		artifact:   'program.code'
		source_map: 'program.vgmap.json'
	}, dir) or {
		assert err.msg().contains('SHA-256')
		return
	}
	assert false
}

fn test_crash_ssa_marks_one_instruction_and_rejects_a_changed_snapshot() {
	dir := temp_directory() or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'program.vgmap.json.ssa')
	snapshot := '; VGuard SSA v1
fn "crash_here"() : t1 {
bb1:
  %11 = call t1 @"abort"
  %12 = ret t1
}
fn "other"() : t1 {
bb2:
  %111 = call t1 @"other"
}
'
	os.write_file(path, snapshot) or { panic(err) }
	bundle := Bundle{
		ssa_path:   path
		ssa_sha256: digest(snapshot.bytes())
	}
	report := Diagnosis{
		kind:     'crash'
		reason:   'signal SIGABRT'
		location: Location{
			function:   'crash_here'
			file:       'sample.v'
			line:       7
			column:     2
			ssa_opcode: 'call'
			ssa_value:  11
			precision:  'caller_frame'
		}
	}
	output := bundle.with_crash_ssa(report)
	assert output.ssa_error == ''
	assert os.dir(output.ssa_original_file) == os.dir(output.ssa_file)
	original := os.read_file(output.ssa_original_file) or { panic(err) }
	assert original == 'fn "crash_here"() : t1 {\nbb1:\n  %11 = call t1 @"abort"\n  %12 = ret t1\n}\n'
	marker := '  ; <<< first mapped V caller frame. error[crash]: signal SIGABRT'
	ssa_report := os.read_file(output.ssa_file) or { panic(err) }
	assert ssa_report.contains('; error[crash]: signal SIGABRT\n')
	assert ssa_report.contains('sample.v:7:2')
	assert ssa_report.contains('  %11 = call t1 @"abort"${marker}\n')
	assert ssa_report.count(marker) == 1
	assert ssa_report.all_after('\n\n').replace(marker, '') == original
	assert !ssa_report.contains('fn "other"')
	text := bundle.format_diagnosis(output)
	assert text.contains('SSA (original)\n${original}\nSSA (annotated)\n${ssa_report.all_after('\n\n')}')
	assert bundle.format_ssa_diagnosis(output) == ssa_report
	encoded := json2.encode(output)
	assert encoded.contains('"ssa_original_file"')
	assert encoded.contains('"ssa_file"')
	assert !encoded.contains('"ssa_excerpt"')

	diagnostics := os.join_path(dir, 'diagnostics')
	os.rmdir_all(diagnostics) or { panic(err) }
	os.write_file(diagnostics, 'prevents the creation of a report directory') or { panic(err) }
	unsaved := bundle.with_crash_ssa(report)
	assert unsaved.ssa_error != ''
	assert unsaved.ssa_file == ''
	assert unsaved.ssa_original_file == ''
	assert bundle.format_diagnosis(unsaved).contains('SSA (original)\n${original}\nSSA (annotated)\n')

	os.write_file(path, snapshot.replace('@"abort"', '@"other"')) or { panic(err) }
	stale := bundle.with_crash_ssa(report)
	assert stale.kind == 'crash'
	assert stale.ssa_file == ''
	assert stale.ssa_original_file == ''
	assert stale.ssa_error.contains('SHA-256')
	ssa_error := bundle.format_ssa_diagnosis(stale)
	assert ssa_error.split_into_lines().all(it.starts_with('; '))
	assert ssa_error.contains('SSA snapshot SHA-256 does not match')
}

fn test_ssa_crash_annotation_keeps_multiline_errors_in_one_comment() {
	snapshot := '; VGuard SSA v1\nfn "main"() : t0 {\nbb1:\n  %5 = unreachable t0\n}\n'
	report := Diagnosis{ kind: 'crash', reason: 'stop\r\nnew line' }
	location := Location{ ssa_value: 5, ssa_opcode: 'unreachable' }
	excerpt := crash_ssa_excerpt(snapshot, location, report.crash_reason()) or { panic(err) }
	assert excerpt.annotated.split_into_lines().len == excerpt.original.split_into_lines().len
	assert excerpt.annotated.contains('  %5 = unreachable t0  ; <<< stop mapped here. error[crash]: stop\\r\\nnew line\n')
}

fn test_native_ssa_dump_marks_one_value_without_changing_other_functions() {
	snapshot := "; VGuard SSA v2
SSA function choose_value ret=1
SSA param 16004 typ=1 kind=argument type_kind=int_t size=8 elem=0 fields=[] names=[]
SSA block 2151
SSA 16005 alloca typ=127 ops=[]
SSA 16006 store typ=0 ops=['16004:argument:1:x', '16005:instruction:127:']
SSA function main ret=0
SSA block 2155
SSA 16485 call typ=0 ops=['16484:func_ref:0:__ssa_init']
SSA 16030 ret typ=0 ops=[]
SSA function another ret=0
SSA block 2160
SSA 16486 call typ=0 ops=['16484:func_ref:0:__ssa_init']
"
	location := Location{ ssa_value: 16485, ssa_opcode: 'call', precision: 'caller_frame' }
	excerpt := crash_ssa_excerpt(snapshot, location, 'signal SIGABRT') or { panic(err) }
	marker := ' << signal SIGABRT (first mapped V caller frame)'
	assert excerpt.original.starts_with('SSA function main ret=0\n')
	assert excerpt.original.ends_with('SSA 16030 ret typ=0 ops=[]\n')
	assert excerpt.annotated.contains("SSA 16485 call typ=0 ops=['16484:func_ref:0:__ssa_init']${marker}\n")
	assert excerpt.dump == snapshot
	assert excerpt.annotated_dump.count(marker) == 1
	assert excerpt.annotated_dump.replace(marker, '') == excerpt.dump
}

fn test_debugger_parsers_keep_only_the_bundle_module_base() {
	lldb := parse_lldb('thread #1, stop reason = signal SIGABRT
pc = 0x180008888
[  0] 0x100008000 /private/tmp/foo bar/program
[  1] 0x180000000 /System/lib.dylib
frame #1: 0x100008a00 program`abort_here',
		'/private/tmp/foo bar/program')
	assert lldb.reason == 'signal SIGABRT'
	assert lldb.load_base or { 0 } == 0x100008000
	assert lldb.pcs == [u64(0x180008888), 0x100008a00]
	bundle := Bundle{
		image: Image{
			format:         'macho'
			preferred_base: 0x100000000
		}
	}
	address := bundle.address_from_load_base(lldb.pcs[1], 0x100008000) or { panic(err) }
	assert address == 0x100000a00

	gdb := parse_gdb('Program received signal SIGABRT, Aborted.
VGUARD_PC 0x7ffff000
0x55555000 0x55556000 0x1000 0x0 r--p /tmp/test program
0x55556000 0x55558000 0x2000 0x1000 r-xp /tmp/test program
#1  0x55556a00 in main ()',
		'/tmp/test program')
	assert gdb.reason.starts_with('SIGABRT')
	assert gdb.load_base or { 0 } == 0x55555000
	assert gdb.pcs == [u64(0x7ffff000), 0x55556a00]
}

fn test_trace_preserves_stderr_and_identifies_first_value_difference() {
	target_stderr := 'before' + trace_prefix + '612e76\t3\t4\tassignment\t7\n' + trace_prefix +
		'612e76\t4\t8\treturn\t15\n' + 'after\n'
	ref_stderr := target_stderr.replace('\treturn\t15\n', '\treturn\t14\n')
	out, target := split_trace(target_stderr) or { panic(err) }
	_, reference := split_trace(ref_stderr) or { panic(err) }
	assert out == 'beforeafter\n'
	diff := first_divergence(target, reference) or { panic(err) }
	first := diff.target or { panic('expected a target event') }
	last := diff.last_common or { panic('expected a common event') }
	assert first.file == 'a.v'
	assert first.line == 4
	assert first.value == '15'
	assert last.line == 3
}
