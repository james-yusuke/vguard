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

fn test_memory_build_rejects_uninstrumented_backends() {
	memory_compiler_args(BuildOptions{ backend: 'arm64' }) or {
		assert err.msg().contains('arm64 has no memory instrumentation')
		return
	}
	assert false
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
