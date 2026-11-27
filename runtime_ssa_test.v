module main

import json2
import os

fn runtime_identity_bytes(words []u64) []u8 {
	mut data := []u8{cap: words.len * 8}
	for word in words {
		for byte in 0 .. 8 {
			data << u8(word >> (byte * 8))
		}
	}
	return data
}

fn test_runtime_stop_uses_the_observed_thread_lifetime_and_frame() {
	data := runtime_identity_bytes([u64(42), 80, 1, 1, 42, 81, 2, 2, 42, 80, 1, 3])
	raw := runtime_identity_bytes([u64(42)])
	events := [
		RuntimeSsaEvent{ kind: runtime_thread_start, thread_id: 1, thread_generation: 1 },
		RuntimeSsaEvent{ kind: 3, id: 100, thread_id: 1, thread_generation: 1, frame: 0x2000 },
		RuntimeSsaEvent{ kind: runtime_thread_start, thread_id: 2, thread_generation: 2 },
		RuntimeSsaEvent{ kind: runtime_thread_start, thread_id: 1, thread_generation: 3 },
		RuntimeSsaEvent{ kind: 3, id: 100, thread_id: 1, thread_generation: 3, frame: 0x2000 },
		RuntimeSsaEvent{ kind: 3, id: 100, thread_id: 1, thread_generation: 3, frame: 0x1000 },
		RuntimeSsaEvent{ kind: 3, id: 100, thread_id: 2, thread_generation: 2, frame: 0x2000 },
	]
	anchor := RuntimeStopAnchor{ process: 42, lwp: 80, frame: 0x2000 }
	binding := bind_runtime_stop(anchor, data, raw, events) or { panic(err) }
	assert binding.generation == 3
	assert binding.event_root(events, 100) or { -1 } == 4
	assert bind_runtime_stop(RuntimeStopAnchor{ ...anchor, process: 43 }, data, raw,
		events) or {
		assert err.msg().contains('debugger inferior')
		RuntimeStopBinding{}
	} == RuntimeStopBinding{}
	mut later := events.clone()
	later << RuntimeSsaEvent{ kind: 1, thread_id: 1, thread_generation: 3, frame: 0x2000 }
	assert binding.event_root(later, 100) or { -1 } == -1
}

const runtime_stopped_threads_fixture = 'module main

fn C.raise(signal int) int

@[noinline]
fn visit(marker u64, signal int) {
	amount := marker + 1
	C.raise(signal)
	println(amount)
}

fn warmup() {
	visit(100, 0)
}

fn stop_worker() {
	visit(200, 6)
}

fn main() {
	first := spawn warmup()
	first.wait()
	second := spawn stop_worker()
	second.wait()
}
'

fn test_linux_gdb_correlates_a_crash_with_the_stopped_worker() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	if compiler == '' || arch == '' || os.user_os() != 'linux' {
		return
	}
	gdb := executable('gdb') or { return }
	probe := capture(Command{
		executable: gdb
		args:       ['--nx', '--batch', '-ex', 'set disable-randomization off', '-ex', 'starti',
			'-ex', 'python print(gdb.selected_thread().ptid)', '--args', '/bin/true']
	}) or { return }
	if !probe.stdout.contains('Program stopped.') || probe.stdout.split_into_lines().all(!it.starts_with('(')) {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'workers.v')
	os.write_file(source, runtime_stopped_threads_fixture) or { panic(err) }
	manifest := build(BuildOptions{
		source:        source
		compiler:      os.real_path(compiler)
		backend:       arch
		target:        'linux/' + arch
		trace_runtime: true
		args:          ['-gc', 'none']
	}, os.join_path(dir, 'build'), false) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	report := bundle.run(ExecutionCase{}, runtime_ssa: true, recover_ssa: true, stack: true) or {
		panic(err)
	}
	assert report.kind == 'crash' && report.reason.contains('SIGABRT'), json2.encode(report)
	assert report.outcome.stdout == '101\n'
	location := report.location or { panic(report.location_error) }
	assert location.function == 'visit' && location.precision == 'caller_frame'
	observed := report.runtime_ssa or { panic(report.runtime_ssa_error) }
	binding := observed.stop_correlation or { panic('missing GDB correlation') }
	assert binding.evidence == 'debugger_thread_and_frame_at_stop' && binding.lwp > 0
	assert binding.frame.starts_with('0x')
	assert observed.root_value == location.ssa_value && observed.function == 'visit'
	assert observed.values.any(it.bits == '0xc9' && it.bytes == 8)
	assert !observed.values.any(it.bits == '0x65')
	assert observed.stop_inputs.any(it.bits == '0x6' && it.bytes == 4
		&& it.evidence == 'native_ssa_sample_before_instruction'
		&& it.event < observed.root_event), json2.encode(report)
	assert !json2.encode(report).contains('"runtime_stop"')
	assert !json2.encode(report).contains('"stop_inputs"')
}

fn test_runtime_ssa_recovers_real_values_branches_and_alias_edges() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	target := os.user_os() + '/' + arch
	if compiler == '' || target !in ['linux/amd64', 'linux/arm64', 'macos/arm64'] {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'observed.v')
	os.write_file(source, 'module main

import os

fn C.malloc(size u64) voidptr
fn C.free(pointer voidptr)
fn C.__asan_poison_memory_region(pointer voidptr, size u64)

@[noinline]
fn traced(dest &u64, alias &u64, poison &u64, choice bool) {
	if choice {
		unsafe { *dest = 7 }
	} else {
		unsafe { *dest = 99 }
	}
	current := unsafe { *alias }
	if current == 7 {
		println(unsafe { *poison })
	}
}

fn main() {
	p := &u64(C.malloc(16))
	q := &u64(C.malloc(16))
	C.__asan_poison_memory_region(q, 16)
	traced(p, p, q, os.args.len > 1)
	C.free(q)
	C.free(p)
}
') or { panic(err) }
	for prod in [false, true] {
		path := build(BuildOptions{
			source:        os.real_path(source)
			compiler:      os.real_path(compiler)
			target:        target
			backend:       arch
			memory:        true
			trace_runtime: true
			prod:          prod
		}, os.join_path(dir, 'build-' + prod.str()), false) or { panic(err) }
		bundle := open_bundle(path) or { panic(err) }
		old := bundle.run(ExecutionCase{}) or { panic(err) }
		assert old.kind == 'exited'
		assert old.runtime_ssa == none
		assert !json2.encode(old).contains('"runtime_ssa"')
		report := bundle.run(ExecutionCase{ argv: ['branch'] }, runtime_ssa: true) or { panic(err) }
		assert report.kind == 'memory_error', '${report.kind} ${report.reason}'
		location := report.location or { panic(report.location_error) }
		assert location.function == 'traced'
		observed := report.runtime_ssa or { panic(report.runtime_ssa_error) }
		assert observed.function == 'traced'
		assert observed.root_value == location.ssa_value
		assert observed.values.any(it.bits == '0x7' && it.bytes == 8)
		assert !observed.values.any(it.bits == '0x63' && it.bytes == 8)
		assert observed.branches.len >= 2
		assert observed.dependencies.any(it.kind == 'executed_cfg_edge')
		assert observed.dependencies.any(it.kind == 'observed_same_thread_address_overlap' && it.overlap_bytes == 8)
	}
}
