module main

import encoding.hex
import encoding.utf8
import json2
import os
import strconv

const vm_history_evidence = 'recorded_qemu_linux'
const vm_kernel_name = 'kernel'
const vm_root_name = 'rootfs'
const vm_events_name = 'qemu-events.bin'
const vm_event_limit = u64(512 * 1024 * 1024)
const vm_bounded_output = 6 * 1024 * 1024

struct VmHistory {
	arch            string
	rootfs          string
	timeout_ms      int
	artifact_sha256 string
	qemu_sha256     string
	kernel_sha256   string
	root_sha256     string
	events_sha256   string
	binary_streams  ?VmBinaryStreams @[omitempty]
}

struct VmBinaryStreams {
	stdout_hex string @[omitempty]
	stderr_hex string @[omitempty]
}

struct VmGuestResult {
	outcome Outcome
	trace   []u8
}

fn vm_output_for_json(output Outcome) (Outcome, ?VmBinaryStreams) {
	text_stdout := utf8.validate_str(output.stdout)
	text_stderr := utf8.validate_str(output.stderr)
	if text_stdout && text_stderr {
		return output, none
	}
	return Outcome{
		...output
		stdout: if text_stdout { output.stdout } else { output.stdout.runes().string() }
		stderr: if text_stderr { output.stderr } else { output.stderr.runes().string() }
	}, VmBinaryStreams{
		stdout_hex: if text_stdout { '' } else { output.stdout.bytes().hex() }
		stderr_hex: if text_stderr { '' } else { output.stderr.bytes().hex() }
	}
}

fn (streams VmBinaryStreams) restore(output Outcome) !Outcome {
	if streams.stdout_hex.len + streams.stderr_hex.len > 2 * vm_bounded_output {
		return error('oversized binary output in the QEMU history')
	}
	return Outcome{
		...output
		stdout: if streams.stdout_hex == '' {
			output.stdout
		} else {
			hex.decode(streams.stdout_hex)!.bytestr()
		}
		stderr: if streams.stderr_hex == '' {
			output.stderr
		} else {
			hex.decode(streams.stderr_hex)!.bytestr()
		}
	}
}

fn vm_executable(arch string) !string {
	return executable(match arch {
		'amd64' { 'qemu-system-x86_64' }
		'arm64' { 'qemu-system-aarch64' }
		else { return error('unsupported QEMU Linux architecture') }
	})
}

fn vm_result_bytes(lines []string, index int, key string) ![]u8 {
	prefix := 'VGUARD_VM_${key} '
	if index >= lines.len || !lines[index].starts_with(prefix) {
		return error('the QEMU guest report is incomplete')
	}
	return hex.decode(lines[index][prefix.len..])
}

fn read_vm_guest_result(qemu Outcome) !VmGuestResult {
	if !runtime_result(qemu) {
		return error('QEMU execution ended with ${qemu.status}')
	}
	if qemu.status != 'exited' || qemu.exit_code != 0 {
		detail := qemu.stderr.trim_space()
		return error('QEMU execution failed (${qemu.exit_code}): ${detail[..int_min(detail.len, 800)]}')
	}
	lines := qemu.stdout.split_into_lines().filter(it.starts_with('VGUARD_VM_')).map(it.trim_right('\r'))
	if lines.len == 1 && lines[0].starts_with('VGUARD_VM_ERROR ') {
		return error('QEMU guest launcher failed: ${lines[0].all_after('VGUARD_VM_ERROR ')}')
	}
	if lines.len != 5 || lines[4] != 'VGUARD_VM_END' {
		return error('QEMU stopped before a complete guest result was observed')
	}
	status := lines[0].fields()
	if status.len != 3 || status[0] != 'VGUARD_VM_RESULT' || status[1] !in ['exited', 'signal'] {
		return error('invalid status in the QEMU guest result')
	}
	code := strconv.atoi(status[2])!
	if code < 0 || code > 255 || (status[1] == 'signal' && code == 0) {
		return error('invalid exit code in the QEMU guest result')
	}
	out := vm_result_bytes(lines, 1, 'STDOUT')!
	err := vm_result_bytes(lines, 2, 'STDERR')!
	trace := vm_result_bytes(lines, 3, 'TRACE')!
	if out.len + err.len + trace.len > vm_bounded_output {
		return error('the QEMU guest output exceeds its limit')
	}
	return VmGuestResult{
		outcome: Outcome{
			status:    status[1]
			exit_code: code
			stdout:    out.bytestr()
			stderr:    err.bytestr()
		}
		trace:   trace
	}
}

fn vm_arguments(history VmHistory, mode string) ![]string {
	if history.arch !in ['amd64', 'arm64'] || history.rootfs !in ['initramfs', 'ext4']
		|| history.timeout_ms <= 0 || mode !in ['record', 'replay'] {
		return error('invalid Linux VM replay configuration')
	}
	mut args := ['-accel', 'tcg,thread=single', '-nodefaults', '-m', '512', '-smp', '1', '-net',
		'none', '-serial', 'stdio', '-display', 'none', '-monitor', 'none', '-no-reboot']
	if history.arch == 'arm64' {
		args << ['-machine', 'virt', '-cpu', 'cortex-a57']
	} else {
		args << ['-machine', 'pc']
	}
	args << ['-icount', 'shift=auto,rr=${mode},rrfile=${vm_events_name}', '-kernel', vm_kernel_name]
	console := if history.arch == 'amd64' { 'ttyS0' } else { 'ttyAMA0' }
	mut boot := 'quiet console=${console} panic=-1'
	if history.rootfs == 'ext4' {
		device := if history.arch == 'amd64' { 'virtio-blk-pci' } else { 'virtio-blk-device' }
		args << ['-drive', 'file=${vm_root_name},format=raw,if=none,snapshot=on,id=source', '-drive',
			'driver=blkreplay,if=none,image=source,id=replayed', '-device', '${device},drive=replayed']
		boot += ' root=/dev/vda rw init=/init'
	} else {
		args << ['-initrd', vm_root_name]
		boot += ' rdinit=/init'
	}
	args << ['-append', boot]
	return args
}

fn run_qemu_linux(qemu string, directory string, history VmHistory, mode string) !VmGuestResult {
	result := capture(Command{
		executable:         qemu
		args:               vm_arguments(history, mode)!
		env:                {
			'LC_ALL': 'C'
			'TZ':     'UTC'
		}
		cwd:                directory
		timeout_ms:         history.timeout_ms
		watched_file:       os.join_path(directory, vm_events_name)
		watched_file_limit: if mode == 'record' { vm_event_limit } else { u64(0) }
	})!
	return read_vm_guest_result(result)
}

fn record_qemu_linux(bundle Bundle, scenario ExecutionCase, out string, options VmGuestOptions) !string {
	target := bundle.manifest.options.target.split('/')
	if target.len != 2 || target[0] != 'linux' || !bundle.image.runnable
		|| bundle.image.format != 'elf' || scenario.harness != '' {
		return error('QEMU recording requires a standalone Linux ELF executable')
	}
	qemu := vm_executable(target[1])!
	profile := VmHistory{
		arch:            target[1]
		rootfs:          if options.rootfs == '' { 'initramfs' } else { options.rootfs }
		timeout_ms:      scenario.timeout_ms
		artifact_sha256: bundle.artifact_sha256
		qemu_sha256:     vm_file_hash(qemu, vm_event_limit)!
	}
	vm_arguments(profile, 'record')!
	work := temp_directory()!
	defer { os.rmdir_all(work) or {} }
	kernel := os.join_path(work, vm_kernel_name)
	if !os.is_file(options.kernel) || os.file_size(options.kernel) > vm_root_limit {
		return error('missing or oversized QEMU kernel')
	}
	os.cp(options.kernel, kernel)!
	root_image := os.join_path(work, vm_root_name)
	stage_vm_guest(bundle, scenario, VmGuestOptions{ ...options, rootfs: profile.rootfs },
		profile.arch, work, root_image)!
	recording := run_qemu_linux(qemu, work, profile, 'record')!
	events := os.join_path(work, vm_events_name)
	ev_hash := vm_file_hash(events, vm_event_limit)!
	repeated := run_qemu_linux(qemu, work, profile, 'replay')!
	if !same_outcome(recording.outcome, repeated.outcome) || recording.trace != repeated.trace {
		return error('QEMU replay did not reproduce the guest outcome and instrumentation')
	}

	mut native := ?NativeHistory(none)
	if bundle.manifest.options.trace_runtime {
		graph := native_history_graph(bundle)!
		native = describe_native_history(recording.trace, graph)!
		os.write_file_array(os.join_path(work, 'native-ssa.bin'), recording.trace)!
		os.write_file_array(os.join_path(work, 'native-ssa.graph.json'), graph)!
	}
	output, binary := vm_output_for_json(recording.outcome)
	history := ExecutionHistory{
		evidence:                     vm_history_evidence
		build:                        compared_build(bundle.manifest)
		source_hash:                  bundle.manifest.source_sha256
		outcome:                      output
		instrumented_artifact_sha256: if native != none { bundle.artifact_sha256 } else { '' }
		native:                       native
		qemu_linux:                   VmHistory{
			...profile
			kernel_sha256:  vm_file_hash(kernel, vm_root_limit)!
			root_sha256:    vm_file_hash(root_image, vm_root_limit)!
			events_sha256:  ev_hash
			binary_streams: binary
		}
	}
	encoded := json2.encode(history) + '\n'
	if encoded.len > capture_limit * 4 {
		return error('the execution history exceeds the 64 MiB replay limit')
	}
	os.mkdir(out)!
	mut saved := false
	defer {
		if !saved {
			os.rmdir_all(out) or {}
		}
	}
	mut files := [vm_kernel_name, vm_root_name, vm_events_name]
	if native != none {
		files << ['native-ssa.bin', 'native-ssa.graph.json']
	}
	for file in files {
		os.cp(os.join_path(work, file), os.join_path(out, file))!
	}
	path := os.join_path(out, 'history.json')
	os.write_file(path, encoded)!
	saved = true
	return path
}

fn replay_qemu_linux(path string, history ExecutionHistory) !ReexecutionReport {
	profile := history.qemu_linux or { return error('the history has no Linux VM recording') }
	if history.build.target != 'linux/' + profile.arch {
		return error('the Linux VM configuration disagrees with its build metadata')
	}
	qemu := vm_executable(profile.arch)!
	if vm_file_hash(qemu, vm_event_limit)! != profile.qemu_sha256 {
		return error('the QEMU executable SHA-256 does not match the recording')
	}
	directory := os.dir(os.abs_path(path))
	work := temp_directory()!
	defer { os.rmdir_all(work) or {} }
	for name, expected in {
		vm_kernel_name: profile.kernel_sha256
		vm_root_name:   profile.root_sha256
		vm_events_name: profile.events_sha256
	} {
		limit := if name == vm_events_name { vm_event_limit } else { vm_root_limit }
		source := os.join_path(directory, name)
		if !os.is_file(source) || os.file_size(source) > limit {
			return error('missing or oversized QEMU recording file: ${name}')
		}
		dest := os.join_path(work, name)
		os.cp(source, dest)!
		if vm_file_hash(dest, limit)! != expected {
			return error('the QEMU file SHA-256 does not match: ${name}')
		}
	}
	expected := if streams := profile.binary_streams {
		streams.restore(history.outcome)!
	} else {
		history.outcome
	}
	result := run_qemu_linux(qemu, work, profile, 'replay') or {
		return ReexecutionReport{
			kind:            'inconclusive'
			evidence:        'qemu_replayed_guest_outcome'
			expected:        history.outcome
			expected_binary: profile.binary_streams
			detail:          err.msg()
		}
	}
	mut trace_match := ?bool(none)
	if native := history.native {
		trace_match = digest(result.trace) == native.trace_sha256
	}
	actual, actual_binary := vm_output_for_json(result.outcome)
	return ReexecutionReport{
		kind:               if same_outcome(expected, result.outcome)
			&& (trace_match or { true }) {
			'matched'
		} else {
			'different'
		}
		evidence:           'qemu_replayed_guest_outcome'
		expected:           history.outcome
		actual:             actual
		expected_binary:    profile.binary_streams
		actual_binary:      actual_binary
		native_trace_match: trace_match
	}
}
