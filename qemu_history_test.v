module main

import json2
import os

fn test_qemu_file_hash_reads_through_eof() {
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'kernel')
	contents := 'x'.repeat(64 * 1024 + 73)
	os.write_file(path, contents) or { panic(err) }
	assert vm_file_hash(path, u64(contents.len)) or { panic(err) } == digest(contents.bytes())
}

fn test_qemu_result_requires_complete_guest_status_and_keeps_exact_output() {
	output := 'guest boot\r\nVGUARD_VM_RESULT signal 6\r\nVGUARD_VM_STDOUT 000a\r\n' +
		'VGUARD_VM_STDERR 6f6b\r\nVGUARD_VM_TRACE \r\nVGUARD_VM_END\r\npower down\n'
	result := read_vm_guest_result(Outcome{ status: 'exited', stdout: output }) or { panic(err) }
	assert result.outcome.status == 'signal' && result.outcome.exit_code == 6
	assert result.outcome.stdout == '\x00\n'
	assert result.outcome.stderr == 'ok'
	assert result.trace.len == 0
	_ := read_vm_guest_result(Outcome{
		status: 'exited'
		stdout: output.replace('VGUARD_VM_END',
			'')
	}) or {
		assert err.msg().contains('complete guest result')
		return
	}
	assert false
}

fn test_qemu_binary_output_round_trips_through_json() {
	raw := Outcome{ status: 'exited', stdout: [u8(0), 10, 255].bytestr(), stderr: '日本語\n' }
	display, binary := vm_output_for_json(raw)
	assert display.stdout == '\x00\n�'
	assert display.stderr == raw.stderr
	history := ExecutionHistory{
		evidence:   vm_history_evidence
		outcome:    display
		qemu_linux: VmHistory{ binary_streams: binary }
	}
	parsed := json2.decode[ExecutionHistory](json2.encode(history)) or { panic(err) }
	vm := parsed.qemu_linux or { panic('missing VM metadata') }
	streams := vm.binary_streams or { panic('missing binary stream') }
	assert streams.stdout_hex == '000aff' && streams.stderr_hex == ''
	assert streams.restore(parsed.outcome) or { panic(err) } == raw
}

fn test_qemu_case_serializes_only_configured_environment_and_keeps_empty_arguments() {
	encoded := vm_case_bytes(ExecutionCase{
		argv: ['first', '', 'last']
		env:  {
			'PROJECT_FLAG': 'enabled'
		}
	}, true) or { panic(err) }
	assert encoded.split('\x00') == ['/vguard', '3', 'first', '', 'last', 'LANG=C',
		'PROJECT_FLAG=enabled', 'TZ=UTC', 'VGUARD_SSA_TRACE_FILE=/vguard/native-ssa.bin', '']
	_ := vm_case_bytes(ExecutionCase{ cwd: './host-relative' }, false) or { return }
	assert false
}

fn test_qemu_guest_case_does_not_resolve_paths_on_the_host() {
	assert (load_case('', guest: true) or { panic(err) }).cwd == ''
	work := temp_directory() or { panic(err) }
	defer { os.rmdir_all(work) or {} }
	case_path := os.join_path(work, 'case.json')
	os.write_file(case_path, '{"cwd":"/vguard"}') or { panic(err) }
	case_input := load_case(case_path, guest: true) or { panic(err) }
	assert case_input.cwd == '/vguard'
}

fn test_qemu_kernel_opt_in_preserves_ordinary_record_options() {
	ordinary := parse_options('record', ['--runtime-ssa', '--out', 'trace']) or { panic(err) }
	assert ordinary.switches['--runtime-ssa'] && '--qemu-kernel' !in ordinary.values
	guest := parse_options('record', ['--qemu-kernel', 'Image', '--out', 'trace', '--qemu-rootfs',
		'ext4']) or { panic(err) }
	assert guest.values['--qemu-kernel'] == 'Image'
	_ := parse_options('record', ['--qemu-kernel', 'Image', '--wasi-stdio']) or {
		assert err.msg().contains('original executable')
		return
	}
	assert false
}

fn test_qemu_linux_glibc_loader_discovers_dependencies() {
	arch := vm_host_arch()
	path := '/bin/true'
	if os.user_os() != 'linux' || arch == '' || !os.is_file(path) {
		return
	}
	bytes := os.read_bytes(path) or { panic(err) }
	interpreter := vm_elf_interpreter(bytes, arch) or { return }
	if interpreter !in ['/lib64/ld-linux-x86-64.so.2', '/lib/ld-linux-aarch64.so.1'] {
		return
	}
	libraries := vm_guest_libraries(path, interpreter, arch, '') or { panic(err) }
	assert libraries[interpreter] == interpreter
	assert libraries.keys().any(it.ends_with('/libc.so.6'))
}

fn test_qemu_guest_replays_a_linux_elf_after_the_build_is_moved() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	kernel := os.getenv('VGUARD_TEST_QEMU_KERNEL')
	arch := vm_host_arch()
	if os.user_os() != 'linux' || arch == '' || compiler == '' || kernel == '' {
		return
	}
	_ := vm_executable(arch) or { panic(err) }
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'vm.v')
	os.write_file(source, "module main

import os

fn C.read(fd int, data voidptr, count u64) i64

fn worker(ch chan u64, value u64) {
	ch <- value + 1
}

fn main() {
	assert os.args[1] == 'guest'
	assert os.getenv('VGUARD_QEMU_CASE') == 'configured'
	mut input := u8(0)
	assert C.read(0, &input, 1) == 1
	ch := chan u64{}
	handle := spawn worker(ch, u64(input))
	value := <-ch
	handle.wait()
	println(value)
	eprintln('observed on stderr')
}
") or { panic(err) }
	path := build(BuildOptions{
		source:   source
		compiler: os.real_path(compiler)
		backend:  'c'
		target:   'linux/' + arch
		args:     ['-cc', 'clang', '-gc', 'none']
	}, os.join_path(dir, 'build'), false) or { panic(err) }
	bundle := open_bundle(path) or { panic(err) }
	case_input := ExecutionCase{
		argv:       ['guest']
		stdin:      'Q'
		env:        {
			'VGUARD_QEMU_CASE': 'configured'
		}
		timeout_ms: 120000
	}
	history_path := record_qemu_linux(bundle, case_input, os.join_path(dir, 'history'),
		VmGuestOptions{
			kernel: kernel
			rootfs: os.getenv('VGUARD_TEST_QEMU_ROOTFS')
		}) or { panic(err) }
	os.mv(os.dir(path), os.join_path(dir, 'original-build')) or { panic(err) }
	history := open_history(history_path) or { panic(err) }
	assert history.outcome.stdout == '82\n' && history.outcome.stderr == 'observed on stderr\n'
	actual := replay_qemu_linux(history_path, history) or { panic(err) }
	assert actual.kind == 'matched', actual.detail
	assert actual.actual == history.outcome
}
