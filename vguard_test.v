module main

import crypto.sha256
import json2
import os

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
	ssa_report := os.read_file(output.ssa_file) or { panic(err) }
	assert ssa_report.contains('sample.v:7:2')
	assert ssa_report.contains('>>> SSA instruction mapped from the crash (caller_frame)\n  %11 = call')
	assert !ssa_report.contains('fn "other"')

	os.write_file(path, snapshot.replace('@"abort"', '@"other"')) or { panic(err) }
	stale := bundle.with_crash_ssa(report)
	assert stale.kind == 'crash'
	assert stale.ssa_file == ''
	assert stale.ssa_error.contains('SHA-256')
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
