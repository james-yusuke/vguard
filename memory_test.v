module main

import os

fn test_memory_report_types_do_not_depend_on_exit_status() {
	log := "==42==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x1010
READ of size 4 at 0x1010 thread T0
==42==ERROR: AddressSanitizer: dynamic-stack-buffer-overflow on address 0x2020
WRITE of size 8 at 0x2020 thread T0
==42== ERROR: AddressSanitizer: global-buffer-overflow on address 0x3030
READ of size 1 at 0x3030 thread T0
==42==ERROR: AddressSanitizer: heap-use-after-free on address 0x4040
WRITE of size 1 at 0x4040 thread T0
==42==ERROR: AddressSanitizer: attempting double-free on 0x4040 in thread T0:
==42==ERROR: AddressSanitizer: attempting free on address which was not malloc()-ed: 0x4041 in thread T0
/example/source with spaces.v:14:5: runtime error: store to null pointer of type 'int'
/example/source with spaces.v:17:8: runtime error: index 4 out of bounds for type 'int[4]'
"
	outcome := Outcome{ status: 'exited', exit_code: 0 }
	report := Bundle{}.diagnose_memory(outcome, parse_sanitizer_log(log))
	assert report.kind == 'memory_error'
	assert report.outcome.exit_code == 0
	assert report.memory_errors.map(it.kind) == [
		'heap-buffer-overflow',
		'stack-buffer-overflow',
		'global-buffer-overflow',
		'heap-use-after-free',
		'double-free',
		'invalid-free',
		'null-pointer-dereference',
		'out-of-bounds',
	]
	assert report.memory_errors.map(it.access) == ['read', 'write', 'read', 'write', 'free', 'free',
		'write', '']
	assert report.memory_errors[0].size_bytes == 4
	assert report.memory_errors[1].address == '0x2020'
	assert report.memory_errors[5].address == '0x4041'
	assert report.memory_errors[6].address == '0x0'
	location := report.memory_errors[6].location or { panic('missing UBSan source line') }
	assert location.file == '/example/source with spaces.v'
	assert location.line == 14
	assert location.ssa_value == -1
}

fn test_memory_stack_sections_and_unknown_signal() {
	events := parse_sanitizer_log('==123==ERROR: AddressSanitizer: heap-use-after-free on address 0x1200
READ of size 1 at 0x1200 thread T0
    #0 0x4001 (/test/program+0x10)
freed by thread T1 here:
    #0 0x4002 (/test/program+0x20)
previously allocated by thread T1 here:
    #0 0x4003 (/test/program+0x30)
Thread T1 created by T0 here:
    #0 0x4004 (/test/program+0x40)
SUMMARY: AddressSanitizer: heap-use-after-free
')
	assert events.len == 1
	assert events[0].stack == ['#0 0x4001 (/test/program+0x10)']
	assert events[0].free_stack == ['#0 0x4002 (/test/program+0x20)']
	assert events[0].alloc_stack == ['#0 0x4003 (/test/program+0x30)']
	outcome := Outcome{ status: 'exited', exit_code: 86 }
	stop := parse_sanitizer_log('==123==ERROR: AddressSanitizer: SEGV on unknown address 0x0')
	crash := Bundle{}.diagnose_memory(outcome, stop)
	assert crash.kind == 'crash'
	assert crash.memory_errors.len == 0
	assert Bundle{}.diagnose_memory(outcome, []).kind == 'exited'
}

fn test_native_null_report_requires_an_exact_mapped_access_and_zero_address() {
	bundle := Bundle{
		artifact: '/test/program'
		image:    Image{
			format:         'elf'
			preferred_base: 0x400000
			sections:       [Section{ index: 1, address: 0x400100, size: 8 }]
		}
		ranges:   [
			PlacedRange{
				section:  1
				start:    0
				end:      4
				location: Location{ function: 'source', ssa_opcode: 'load', ssa_value: 12 }
			},
		]
	}
	log := '==123==ERROR: AddressSanitizer: SEGV on unknown address 0x0 (pc 0x400101)
The signal is caused by a READ memory access.
    #0 0x400101 (/test/program+0x101)
'
	outcome := Outcome{ status: 'exited', exit_code: 86 }
	report := bundle.diagnose_memory(outcome, parse_sanitizer_log(log))
	assert report.kind == 'memory_error'
	assert report.memory_errors[0].kind == 'null-pointer-dereference'
	location := report.location or { panic('missing native SSA location') }
	assert location.ssa_value == 12
	near_null := bundle.diagnose_memory(outcome, parse_sanitizer_log(log.replace('address 0x0',
		'address 0x8')))
	assert near_null.kind == 'crash'
	unknown := bundle.diagnose_memory(outcome, parse_sanitizer_log(log.replace('READ', 'WRITE')))
	assert unknown.kind == 'crash'
}

fn test_memory_build_rejects_uninstrumented_backends() {
	memory_compiler_args(BuildOptions{ backend: 'js' }) or {
		assert err.msg().contains('js has no --memory instrumentation')
		return
	}
	assert false
}

fn test_wasm_memory_reports_the_actual_linear_memory_boundary_trap() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	if compiler == '' {
		return
	}
	executable('wasmtime') or { return }
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	file := os.join_path(dir, 'linear_memory.v')
	os.write_file(file, 'fn main() {
	unsafe {
		address := &u64(u32(0x1000_0000))
		println(*address)
	}
}
') or { panic(err) }
	for enabled in [false, true] {
		manifest := build(BuildOptions{
			source:   file
			compiler: os.real_path(compiler)
			target:   'wasm32_emscripten/wasm32'
			backend:  'wasm'
			memory:   enabled
		}, os.join_path(dir, 'build-${enabled}'), false) or { panic(err) }
		bundle := open_bundle(manifest) or { panic(err) }
		report := bundle.run(ExecutionCase{}) or { panic(err) }
		if enabled {
			assert report.kind == 'memory_error', report.outcome.stderr
			assert report.memory_errors.len == 1
			finding := report.memory_errors[0]
			assert finding.kind == 'wasm-linear-memory-out-of-bounds'
			assert finding.sanitizer == 'wasmtime'
			assert finding.address == '0x10000000'
		} else {
			assert report.kind == 'crash'
			assert report.memory_errors.len == 0
		}
	}
}

fn test_wasm_shadow_reports_allocation_bounds_and_lifetime() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	if compiler == '' {
		return
	}
	executable('wasmtime') or { return }
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	preamble := 'fn C.malloc(size uint) voidptr
fn C.calloc(count uint, size uint) voidptr
fn C.realloc(ptr voidptr, size uint) voidptr
fn C.free(ptr voidptr)
'
	samples := {
		'valid':                                'unsafe {
	mut p := &u8(C.malloc(17))
	p[16] = 42
	p = &u8(C.realloc(p, 131072))
	println(p[16])
	p[131071] = 19
	println(p[131071])
	p = &u8(C.realloc(p, 17))
	println(p[16])
	C.free(p)
	first := C.malloc(0)
	last := C.malloc(0)
	assert first != last
	C.free(first)
	C.free(last)
}'
		'wasm-heap-out-of-bounds':              'unsafe {
	p := &u8(C.malloc(17))
	println(p[17])
}'
		'wasm-heap-use-after-free':             'unsafe {
	mut p := &u8(C.malloc(17))
	p[16] = 42
	C.free(p)
	println(p[16])
}'
		'wasm-invalid-heap-lifetime-operation': 'unsafe {
	p := C.malloc(17)
	C.free(p)
	C.free(p)
}'
		'wasm-heap-capacity-exceeded':          'unsafe {
	C.calloc(65536, 65536)
}'
	}
	for expected, body in samples {
		source := os.join_path(dir, '${expected}.v')
		os.write_file(source, preamble + '\nfn main() {\n${body}\n}\n') or { panic(err) }
		manifest := build(BuildOptions{
			source:    source
			compiler:  os.real_path(compiler)
			target:    'wasm32_emscripten/wasm32'
			backend:   'wasm'
			memory:    true
			wasm_heap: true
		}, os.join_path(dir, 'checked-${expected}'), false) or { panic(err) }
		bundle := open_bundle(manifest) or { panic(err) }
		report := bundle.run(ExecutionCase{}) or { panic(err) }
		if expected == 'valid' {
			assert report.kind == 'exited', report.outcome.stderr
			assert report.outcome.stdout == '42\n19\n42\n'
			continue
		}
		assert report.kind == 'memory_error', report.outcome.stderr
		assert report.memory_errors.len == 1
		finding := report.memory_errors[0]
		assert finding.kind == expected
		assert finding.sanitizer == 'vguard-wasm-shadow'
		location := finding.location or { panic('the heap trap does not have a caller location') }
		assert location.file == source
		assert location.line >= 6
		if expected in ['wasm-heap-out-of-bounds', 'wasm-heap-use-after-free'] {
			assert finding.access == 'read'
		}
	}
}

fn test_fastc_memory_checks_an_instrumented_heap_read() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	target := os.user_os() + '/' + arch
	if compiler == '' || target !in ['linux/amd64', 'linux/arm64', 'macos/arm64'] {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	file := os.join_path(dir, 'fastc-memory.v')
	os.write_file(file, 'module main

#include <sanitizer/asan_interface.h>

fn C.getchar() int
fn C.__asan_poison_memory_region(pointer voidptr, size u64)

@[noinline]
fn read_value(values []u64) u64 {
	return values[0]
}

fn main() {
	values := [u64(42), 7]
	if C.getchar() == 112 {
		C.__asan_poison_memory_region(&values[0], 16)
	}
	println(read_value(values))
}
') or { panic(err) }
	manifest := build(BuildOptions{
		source:   file
		compiler: os.real_path(compiler)
		target:   target
		backend:  'fastc'
		memory:   true
	}, os.join_path(dir, 'build'), false) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	clean := bundle.run(ExecutionCase{}) or { panic(err) }
	assert clean.kind == 'exited' && clean.outcome.exit_code == 0 && clean.outcome.stdout == '42\n'
	checked := bundle.run(ExecutionCase{ stdin: 'p' }) or { panic(err) }
	assert checked.kind == 'memory_error', '${checked.kind}: ${checked.reason} ${checked.outcome.stderr}'
	assert checked.memory_errors.len == 1
	assert checked.memory_errors[0].kind == 'use-after-poison'
	assert checked.memory_errors[0].size_bytes == 8
}

fn test_native_memory_checks_poisoned_scalar_reads_and_writes() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	architecture := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	target := os.user_os() + '/' + architecture
	if compiler == '' || target !in ['linux/amd64', 'linux/arm64', 'macos/arm64'] {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'probe.v')
	os.write_file(source, "module main

import os

fn C.malloc(size u64) voidptr
fn C.free(p voidptr)
fn C.__asan_poison_memory_region(p voidptr, size u64)

fn main() {
	p := C.malloc(16)
	unsafe { *(&u8(p)) = 7 }
	if os.args.len > 1 {
		C.__asan_poison_memory_region(p, 16)
		if os.args[1] == 'write' {
			unsafe { *(&u8(p)) = 8 }
		}
	}
	value := unsafe { *(&u8(p)) }
	C.free(p)
	println(value)
}
") or { panic(err) }
	options := BuildOptions{
		source:   os.real_path(source)
		compiler: os.real_path(compiler)
		backend:  architecture
		target:   target
		memory:   true
	}
	manifest := build(options, os.join_path(dir, 'target'), false, trace_ssa: true) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	clean := bundle.run(ExecutionCase{}) or { panic(err) }
	assert clean.kind == 'exited', '${clean.kind} ${clean.reason}'
	assert clean.outcome.exit_code == 0
	assert clean.outcome.stdout == '7\n'
	report := bundle.run(ExecutionCase{ argv: ['poisoned'] }) or { panic(err) }
	assert report.kind == 'memory_error', '${report.kind} ${report.reason}'
	assert report.memory_errors.len == 1
	finding := report.memory_errors[0]
	assert finding.kind == 'use-after-poison'
	assert finding.access == 'read'
	assert finding.size_bytes == 1
	assert finding.address != ''
	location := finding.location or { panic('missing native memory location') }
	assert location.file == options.source
	assert location.line == 18
	assert location.ssa_opcode == 'load'
	allocation := finding.allocation or { panic('missing native allocation frame') }
	assert allocation.file == options.source
	assert allocation.line == 10
	assert allocation.ssa_opcode == 'call'
	annotated := os.read_file(report.ssa_file) or { panic(err) }
	assert annotated.split_into_lines().any(it.starts_with('SSA ${location.ssa_value} load typ=')
		&& it.ends_with(' << use-after-poison'))
	original := os.read_file(report.ssa_original_file) or { panic(err) }
	assert annotated.all_after('\n\n').replace(' << use-after-poison', '') == original

	write := bundle.run(ExecutionCase{ argv: ['write'] }) or { panic(err) }
	assert write.kind == 'memory_error', '${write.kind} ${write.reason}'
	assert write.memory_errors.len == 1
	assert write.memory_errors[0].kind == 'use-after-poison'
	assert write.memory_errors[0].access == 'write'
	assert write.memory_errors[0].size_bytes == 1
	store := write.location or { panic('missing native write location') }
	assert store.file == options.source
	assert store.line == 15
	assert store.ssa_opcode == 'store'
}

fn test_native_stack_redzones_have_reported_object_bounds() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	architecture := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	target := os.user_os() + '/' + architecture
	if compiler == '' || target !in ['linux/amd64', 'linux/arm64', 'macos/arm64'] {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'stack_probe.v')
	// The probe points into the extra frame bytes reserved by the redzone.
	os.write_file(source, "module main

import os

fn C.__asan_address_is_poisoned(p voidptr) int

@[noinline]
fn check_frame() {
	mut data := [u64(7)]!
	p := unsafe { u64(&data[0]) }
	assert C.__asan_address_is_poisoned(voidptr(p)) == 0
	assert C.__asan_address_is_poisoned(voidptr(p - 1)) != 0
	assert C.__asan_address_is_poisoned(voidptr(p + 8)) != 0
	if os.args.len > 1 {
		value := unsafe { *(&u8(p + 8)) }
		println(value)
	}
	data[0]++
	assert data[0] == 8
}

fn main() {
	check_frame()
	check_frame()
	println('stack checks passed')
}
") or { panic(err) }
	options := BuildOptions{
		source:   os.real_path(source)
		compiler: os.real_path(compiler)
		backend:  architecture
		target:   target
		memory:   true
	}
	manifest := build(options, os.join_path(dir, 'target'), false) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	clean := bundle.run(ExecutionCase{}) or { panic(err) }
	assert clean.kind == 'exited', '${clean.kind} ${clean.reason}'
	assert clean.outcome.exit_code == 0
	assert clean.outcome.stdout == 'stack checks passed\n'
	diagnosis := bundle.run(ExecutionCase{ argv: ['redzone'] }) or { panic(err) }
	assert diagnosis.kind == 'memory_error', '${diagnosis.kind} ${diagnosis.reason}'
	assert diagnosis.memory_errors.len == 1
	finding := diagnosis.memory_errors[0]
	assert finding.kind == 'stack-buffer-overflow'
	assert finding.access == 'read'
	assert finding.size_bytes == 1
	location := finding.location or { panic('missing redzone location') }
	assert location.function == 'check_frame'
	assert location.file == options.source
	assert location.line == 15
	assert location.ssa_opcode == 'load'
	allocation := finding.allocation or { panic('missing stack allocation location') }
	assert allocation.function == 'check_frame'
	assert allocation.ssa_opcode == 'alloca'
}

fn test_native_globals_register_redzones_and_preserve_adjacent_objects() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	target := os.user_os() + '/' + arch
	if compiler == '' || target !in ['linux/amd64', 'linux/arm64', 'macos/arm64'] {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'globals.v')
	os.write_file(source, 'module main

import os

fn C.__asan_address_is_poisoned(p voidptr) int

__global (
	values [2]u64
	other u64
)

fn main() {
	values[0] = 7
	values[1] = 11
	other = 13
	p := unsafe { u64(&values[0]) }
	assert C.__asan_address_is_poisoned(voidptr(p)) == 0
	assert C.__asan_address_is_poisoned(voidptr(p + 15)) == 0
	assert C.__asan_address_is_poisoned(voidptr(p + 16)) != 0
	assert C.__asan_address_is_poisoned(&other) == 0
	if os.args.len > 1 {
		value := unsafe { *(&u8(p + 16)) }
		println(value)
	}
	println(values[0] + values[1] + other)
}

') or { panic(err) }
	manifest := build(BuildOptions{
		source:   os.real_path(source)
		compiler: os.real_path(compiler)
		backend:  arch
		target:   target
		memory:   true
		args:     ['-enable-globals']
	}, os.join_path(dir, 'target'), false) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	clean := bundle.run(ExecutionCase{}) or { panic(err) }
	assert clean.kind == 'exited', '${clean.kind} ${clean.reason} ${clean.outcome.stderr}'
	assert clean.outcome.exit_code == 0
	assert clean.outcome.stdout == '31\n'
	report := bundle.run(ExecutionCase{ argv: ['redzone'] }) or { panic(err) }
	assert report.kind == 'memory_error', '${report.kind} ${report.reason}'
	assert report.memory_errors.len == 1
	assert report.memory_errors[0].kind == 'global-buffer-overflow'
	assert report.memory_errors[0].access == 'read'
	assert report.memory_errors[0].size_bytes == 1
	location := report.location or { panic('missing global access source') }
	assert location.file == os.real_path(source)
	assert location.line == 22
	assert location.ssa_opcode == 'load'
}

fn test_memory_mode_with_real_asan_shadow_and_valid_execution() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	target := $if amd64 { os.user_os() + '/amd64' } $else $if arm64 { os.user_os() + '/arm64' } $else { '' }
	if compiler == '' || target !in ['linux/amd64', 'linux/arm64', 'macos/arm64'] {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	// Query real ASan shadow memory and ask its runtime to report a simulated
	// access for the redzone and freed-region cases.
	os.write_file(os.join_path(dir, 'probe.h'), '#include <sanitizer/asan_interface.h>
#include <stdlib.h>

static unsigned char vguard_global[16];

static __attribute__((noinline)) void vguard_probe(void *p, int is_write) {
    char marker = 0;
    if (!__asan_address_is_poisoned(p)) abort();
    __asan_report_error(__builtin_return_address(0), __builtin_frame_address(0), &marker,
                        p, is_write, 1);
}

static __attribute__((noinline)) void vguard_stack_probe(void) {
    unsigned char buffer[16] = {0};
    vguard_probe(buffer + sizeof(buffer), 1);
}

static __attribute__((noinline)) void vguard_global_probe(void) {
    vguard_probe(vguard_global + sizeof(vguard_global), 0);
}

static void vguard_poison(void *p) { __asan_poison_memory_region(p, 16); }
static void vguard_unpoison(void *p) { __asan_unpoison_memory_region(p, 16); }
') or { panic(err) }
	source := os.join_path(dir, 'sample.v')
	os.write_file(source, 'import os

#include "@VMODROOT/probe.h"

fn C.malloc(size usize) voidptr
fn C.free(p voidptr)
fn C.vguard_probe(p voidptr, is_write int)
fn C.vguard_stack_probe()
fn C.vguard_global_probe()

fn main() {
    match os.args[1] {
        \'heap\' {
            p := C.malloc(16)
            C.vguard_probe(voidptr(usize(p) + 16), 0)
            C.free(p)
        }
        \'uaf\' {
            p := C.malloc(16)
            addr := usize(p)
            C.free(p)
            C.vguard_probe(voidptr(addr), 1)
        }
        \'stack\' { C.vguard_stack_probe() }
        \'global\' { C.vguard_global_probe() }
        \'poison\' {
            p := C.malloc(16)
            unsafe { *(&u8(p)) = 7 }
            C.vguard_poison(p)
            value := unsafe { *(&u8(p)) }
            C.vguard_unpoison(p)
            C.free(p)
            println(value)
        }
        else {
            p := C.malloc(16)
            C.free(p)
            eprintln(\'normal stderr\')
            println(\'ok\')
        }
    }
}

fn C.vguard_poison(p voidptr)
fn C.vguard_unpoison(p voidptr)
') or { panic(err) }
	manifest := build(BuildOptions{
		source:   os.real_path(source)
		compiler: os.real_path(compiler)
		backend:  'c'
		target:   target
		memory:   true
	}, os.join_path(dir, 'target'), false) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	clean := bundle.run(ExecutionCase{ argv: ['clean'] }) or { panic(err) }
	assert clean.kind == 'exited'
	assert clean.outcome.exit_code == 0
	assert clean.outcome.stdout == 'ok\n'
	assert clean.outcome.stderr == 'normal stderr\n'
	assert clean.memory_errors.len == 0

	for mode, kind in {
		'heap':   'heap-buffer-overflow'
		'uaf':    'heap-use-after-free'
		'stack':  'stack-buffer-overflow'
		'global': 'global-buffer-overflow'
		'poison': 'use-after-poison'
	} {
		report := bundle.run(ExecutionCase{ argv: [mode] }) or { panic(err) }
		assert report.kind == 'memory_error', '${mode} ${report}'
		assert report.memory_errors.len == 1
		finding := report.memory_errors[0]
		assert finding.kind == kind
		assert finding.address.starts_with('0x')
		loc := finding.location or { panic('${mode} ${report.location_error}') }
		assert loc.file == os.real_path(source)
		assert loc.line > 0
		match mode {
			'heap' {
				alloc := finding.allocation or { panic('missing heap allocation line') }
				assert alloc.line == 14
				assert finding.access == 'read'
			}
			'uaf' {
				alloc := finding.allocation or { panic('missing UAF allocation line') }
				freed := finding.deallocation or { panic('missing UAF free line') }
				assert alloc.line == 19
				assert freed.line == 21
				assert loc.line == 22
				assert finding.access == 'write'
				text := bundle.format_diagnosis(report)
				assert text.contains('error[heap-use-after-free]: write of 1 byte at ')
				assert text.contains('>22 |')
				assert text.contains('note: allocation site')
				assert text.contains('note: deallocation site')
				assert !text.contains('^')
			}
			'poison' {
				// The compiler-inserted check observes the shadow marker before the V load.
				assert finding.access == 'read'
				assert finding.size_bytes == 1
				assert loc.line == 30
			}
			else {}
		}
	}
}
