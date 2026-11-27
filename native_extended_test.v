module main

import os

const native_channel_fixture = 'module main

@[noinline]
fn send(ch chan u64, value u64) {
	ch <- value + 1
}

fn main() {
	buffered := chan u64{cap: 1}
	buffered <- u64(53)
	println(<-buffered)
	shared := chan u64{}
	handle := spawn send(shared, 81)
	println(<-shared)
	handle.wait()
	buffered <- u64(117)
	select {
		value := <-buffered { println(value) }
		else { panic("buffered value was unavailable") }
	}
	buffered.close()
	println(<-buffered)
}
'

fn test_linux_native_channel_receives_values_with_and_without_shadow_checks() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	if compiler == '' || arch == '' || os.user_os() != 'linux' {
		return
	}
	work := temp_directory() or { panic(err) }
	defer { os.rmdir_all(work) or {} }
	source := os.join_path(work, 'channel_values.v')
	os.write_file(source, native_channel_fixture) or { panic(err) }
	for memory in [false, true] {
		for prod in [false, true] {
			path := build(BuildOptions{
				source:   source
				compiler: os.real_path(compiler)
				backend:  arch
				target:   'linux/' + arch
				prod:     prod
				memory:   memory
				args:     if memory { []string{} } else { ['-gc', 'none'] }
			}, os.join_path(work, 'build-${memory}-${prod}'), false,
				trace_ssa: true
			) or { panic(err) }
			bundle := open_bundle(path) or { panic(err) }
			out := if memory {
				bundle.run(ExecutionCase{}) or { panic(err) }
			} else {
				ordinary_diagnosis((ExecutionCase{}).run_binary(bundle.artifact) or { panic(err) })
			}
			assert out.kind == 'exited' && out.outcome.exit_code == 0, out.outcome.stderr
			assert out.outcome.stdout == '53\n82\n117\n0\n'
			assert out.memory_errors.len == 0
		}
	}
}

fn test_native_memory_checks_aggregate_copies_and_atomic_accesses() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	target := os.user_os() + '/' + arch
	if compiler == '' || target !in ['linux/amd64', 'linux/arm64', 'macos/arm64'] {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'accesses.v')
	os.write_file(source, "module main

import os

fn C.malloc(size u64) voidptr
fn C.free(pointer voidptr)
fn C.__asan_poison_memory_region(pointer voidptr, size u64)
fn C.atomic_load_u64(pointer voidptr) u64
fn C.atomic_store_u64(pointer voidptr, value u64)
fn C.atomic_exchange_u64(pointer voidptr, value u64) u64
fn C.atomic_fetch_sub_u64(pointer voidptr, delta u64) u64
fn C.atomic_compare_exchange_strong_u64(pointer voidptr, expected voidptr, desired u64) bool
fn C.atomic_fetch_add_u64(pointer voidptr, delta u64) u64

struct Triple {
	a u64
	b u64
	c u64
}

@[noinline]
fn load_value(p &Triple) Triple {
	return unsafe { *p }
}

@[noinline]
fn store_value(p &Triple, v Triple) {
	unsafe { *p = v }
}

fn main() {
	p := &Triple(C.malloc(32))
	value := Triple{ a: 3, b: 5, c: 7 }
	store_value(p, value)
	mode := if os.args.len > 1 { os.args[1] } else { '' }
	if mode == 'atomic' {
		C.__asan_poison_memory_region(p, 8)
		C.atomic_fetch_add_u64(p, 1)
	} else if mode != '' {
		C.__asan_poison_memory_region(voidptr(unsafe { usize(p) + 16 }), 8)
		if mode == 'write' {
			store_value(p, value)
		} else {
			println(load_value(p).c)
		}
	}
	assert C.atomic_fetch_add_u64(p, 2) == 3
	assert C.atomic_load_u64(p) == 5
	C.atomic_store_u64(p, 9)
	assert C.atomic_exchange_u64(p, 11) == 9
	assert C.atomic_fetch_sub_u64(p, 3) == 11
	mut expected := u64(8)
	assert C.atomic_compare_exchange_strong_u64(p, &expected, 12)
	expected = 1
	assert !C.atomic_compare_exchange_strong_u64(p, &expected, 4)
	assert expected == 12
	assert C.atomic_load_u64(p) == 12
	println(load_value(p).c)
	C.free(p)
}
") or { panic(err) }
	manifest := build(BuildOptions{
		source:   os.real_path(source)
		compiler: os.real_path(compiler)
		backend:  arch
		target:   target
		memory:   true
	}, os.join_path(dir, 'target'), false) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	clean := bundle.run(ExecutionCase{}) or { panic(err) }
	assert clean.kind == 'exited', '${clean.kind} ${clean.reason} ${clean.outcome.stderr}'
	assert clean.outcome.exit_code == 0
	assert clean.outcome.stdout == '7\n'
	for mode in ['read', 'write', 'atomic'] {
		report := bundle.run(ExecutionCase{ argv: [mode] }) or { panic(err) }
		assert report.kind == 'memory_error', '${mode}: ${report.kind} ${report.reason}'
		assert report.memory_errors.len == 1
		finding := report.memory_errors[0]
		assert finding.kind == 'use-after-poison'
		assert finding.access == if mode == 'read' { 'read' } else { 'write' }
		assert finding.size_bytes == if mode == 'atomic' { 8 } else { 24 }
	}
}
