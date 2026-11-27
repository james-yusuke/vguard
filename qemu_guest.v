module main

import crypto.sha256
import json2
import os

const vm_root_limit = u64(128 * 1024 * 1024)
const vm_guest_files_limit = u64(96 * 1024 * 1024)
const vm_case_limit = 1024 * 1024
const vm_native_trace = '/vguard/native-ssa.bin'

struct VmGuestOptions {
	kernel    string
	rootfs    string
	launcher  string
	libraries string
}

fn vm_file_hash(path string, limit u64) !string {
	if !os.is_file(path) {
		return error('missing QEMU file: ${os.file_name(path)}')
	}
	length := os.file_size(path)
	if length == 0 || length > limit {
		return error('empty or oversized QEMU file: ${os.file_name(path)}')
	}
	mut file := os.open(path)!
	defer { file.close() }
	mut hash := sha256.new()
	mut buffer := []u8{len: 64 * 1024}
	mut total := u64(0)
	for total < length {
		read := file.read(mut buffer) or {
			return error('could not read QEMU file: ${os.file_name(path)}')
		}
		if read <= 0 {
			return error('the QEMU file was truncated: ${os.file_name(path)}')
		}
		hash.write(buffer[..read])!
		total += u64(read)
	}
	if total != length || os.file_size(path) != length {
		return error('the QEMU file changed while it was read: ${os.file_name(path)}')
	}
	return hash.sum([]u8{}).hex()
}

fn vm_elf_interpreter(data []u8, arch string) !string {
	machine := if arch == 'amd64' { u64(62) } else { u64(183) }
	if number(data, 0, 4)! != 0x464c457f || number(data, 4, 2)! != 0x0102
		|| number(data, 18, 2)! != machine {
		return error('the QEMU executable has a different ELF architecture')
	}
	kind := number(data, 16, 2)!
	if kind !in [u64(2), 3] || number(data, 24, 8)! == 0 {
		return error('QEMU recording requires an executable ELF image')
	}
	start := number(data, 32, 8)!
	width := number(data, 54, 2)!
	count := number(data, 56, 2)!
	if width != 56 || count == 0 {
		return error('missing executable ELF program headers')
	}
	table := view(data, start, width * count)!
	mut interpreter := ''
	for index in 0 .. int(count) {
		header := u64(index) * width
		if number(table, header, 4)! != 3 {
			continue
		}
		if interpreter != '' {
			return error('multiple ELF interpreters')
		}
		bytes := view(data, number(table, header + 8, 8)!, number(table, header + 32, 8)!)!
		if bytes.len < 2 || bytes.last() != 0 || bytes[..bytes.len - 1].contains(u8(0)) {
			return error('invalid ELF interpreter')
		}
		interpreter = bytes[..bytes.len - 1].bytestr()
		if !vm_library_path(interpreter) {
			return error('unsupported guest interpreter path')
		}
	}
	return interpreter
}

fn vm_library_path(path string) bool {
	return (path.starts_with('/lib/') || path.starts_with('/lib64/')
		|| path.starts_with('/usr/lib/') || path.starts_with('/usr/lib64/')
		|| path.starts_with('/usr/local/lib/') || path.starts_with('/vguard/lib/'))
		&& !path[1..].split('/').any(it in ['', '.', '..']) && !path.contains_any('\x00\n\r')
}

fn vm_host_arch() string {
	return $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
}

fn vm_guest_libraries(artifact string, interpreter string, arch string, library_file string) !map[string]string {
	if library_file != '' {
		if os.file_size(library_file) > u64(vm_case_limit) {
			return error('oversized QEMU library map')
		}
		return json2.decode[map[string]string](os.read_file(library_file)!)
	}
	if interpreter == '' {
		return map[string]string{}
	}
	loader := if arch == 'amd64' {
		'/lib64/ld-linux-x86-64.so.2'
	} else {
		'/lib/ld-linux-aarch64.so.1'
	}
	if os.user_os() != 'linux' || vm_host_arch() != arch || interpreter != loader
		|| !os.is_file(loader) {
		return error('this guest needs --qemu-libraries with its ELF loader and shared libraries')
	}
	result := capture(Command{
		executable: loader
		args:       ['--list', artifact]
		env:        {
			'LC_ALL': 'C'
		}
		timeout_ms: 10000
	})!
	if result.status != 'exited' || result.exit_code != 0 {
		return error('the Linux loader could not list guest libraries: ${result.stderr.trim_space()}')
	}
	mut paths := {
		interpreter: loader
	}
	for line in result.stdout.split_into_lines() {
		path := line.trim_space().all_after(' => ').all_before_last(' (')
		// The loader itself can appear without an arrow. Linux's vDSO needs no file.
		if path.starts_with('/') {
			paths[path] = path
		}
	}
	return paths
}

fn vm_case_bytes(scenario ExecutionCase, trace bool) !string {
	cwd := if scenario.cwd == '' { '/vguard' } else { scenario.cwd }
	if scenario.harness != '' || scenario.timeout_ms <= 0 || !cwd.starts_with('/')
		|| cwd.contains('\x00') || scenario.stdin.len > vm_case_limit || scenario.argv.len > 1024
		|| scenario.argv.any(it.contains('\x00')) {
		return error('invalid QEMU guest case or unsupported harness')
	}
	mut env := {
		'LANG': 'C'
		'TZ':   'UTC'
	}
	for key, value in scenario.env {
		if key == '' || key.contains_any('=\x00') || value.contains('\x00')
			|| key == 'VGUARD_SSA_TRACE_FILE' {
			return error('invalid QEMU guest environment key')
		}
		env[key] = value
	}
	if trace {
		env['VGUARD_SSA_TRACE_FILE'] = vm_native_trace
	}
	if env.len > 1024 {
		return error('too many QEMU guest environment variables')
	}
	mut fields := [cwd, scenario.argv.len.str()]
	fields << scenario.argv
	for key in env.keys().sorted() {
		fields << key + '=' + env[key]
	}
	data := fields.join('\x00') + '\x00'
	if data.len > vm_case_limit {
		return error('oversized QEMU guest arguments and environment')
	}
	return data
}

fn vm_stage_launcher(options VmGuestOptions, arch string, work string, dest string) ! {
	if options.launcher != '' {
		if !os.is_file(options.launcher) || os.file_size(options.launcher) > u64(capture_limit) {
			return error('missing or oversized QEMU guest launcher')
		}
		data := os.read_bytes(options.launcher)!
		if vm_elf_interpreter(data, arch)! != '' {
			return error('the QEMU guest launcher must be statically linked')
		}
		os.write_file_array(dest, data)!
	} else {
		if os.user_os() != 'linux' || vm_host_arch() != arch {
			return error('a different OS or architecture needs --qemu-launcher with the compiled Linux guest launcher')
		}
		source := os.join_path(work, 'guest.c')
		os.write_file(source, $embed_file('compiler/qemu_guest.c').to_string())!
		result := capture(Command{
			executable: executable('cc')!
			args:       ['-std=c11', '-Os', '-static', source, '-o', dest]
		})!
		if result.status != 'exited' || result.exit_code != 0 {
			return error('compiling the static QEMU guest launcher failed: ${result.stderr.trim_space()}')
		}
	}
	os.chmod(dest, 0o755)!
}

fn vm_archive_entry(mut archive os.File, name string, index int, mode int, links int, data []u8) ! {
	mut header := '070701'
	for value in [index, mode, 0, 0, links, 0, data.len, 0, 0, 0, 0, name.len + 1, 0] {
		header += '${value:08x}'
	}
	archive.write_string(header + name + '\x00')!
	archive.write([]u8{len: (4 - (110 + name.len + 1) % 4) % 4})!
	archive.write(data)!
	archive.write([]u8{len: (4 - data.len % 4) % 4})!
}

fn vm_archive_dir(mut archive os.File, root string, relative string, index int) !int {
	mut inode := index
	for name in os.ls(os.join_path(root, relative))!.sorted() {
		path := if relative == '' { name } else { relative + '/' + name }
		host := os.join_path(root, path)
		inode++
		if os.is_dir(host) {
			vm_archive_entry(mut archive, path, inode, 0o40755, 2, []u8{})!
			inode = vm_archive_dir(mut archive, root, path, inode)!
		} else {
			mode := if os.is_executable(host) { 0o100755 } else { 0o100644 }
			vm_archive_entry(mut archive, path, inode, mode, 1, os.read_bytes(host)!)!
		}
	}
	return inode
}

fn stage_vm_guest(bundle Bundle, scenario ExecutionCase, options VmGuestOptions, arch string, work string, image_path string) ! {
	root := os.join_path(work, 'guest')
	program_dir := os.join_path(root, 'vguard')
	for name in ['dev', 'proc', 'vguard', 'tmp'] {
		os.mkdir_all(os.join_path(root, name))!
	}
	if os.file_size(bundle.artifact) > vm_guest_files_limit {
		return error('the QEMU guest executable exceeds the image limit')
	}
	artifact := os.read_bytes(bundle.artifact)!
	if digest(artifact) != bundle.artifact_sha256 {
		return error('the executable changed after its manifest was opened')
	}
	interpreter := vm_elf_interpreter(artifact, arch)!
	libraries := vm_guest_libraries(bundle.artifact, interpreter, arch, options.libraries)!
	if interpreter != '' && interpreter !in libraries {
		return error('the QEMU library map does not include ${interpreter}')
	}
	mut total := u64(artifact.len)
	for guest in libraries.keys().sorted() {
		host := libraries[guest]
		if !vm_library_path(guest) || !os.is_file(host) {
			return error('invalid guest shared library: ${guest}')
		}
		size := os.file_size(host)
		if size == 0 || size > vm_guest_files_limit - total {
			return error('the QEMU guest libraries exceed the image limit')
		}
		total += size
		dest := os.join_path(root, guest[1..])
		os.mkdir_all(os.dir(dest))!
		os.cp(host, dest, fail_if_exists: true)!
		os.chmod(dest, if guest == interpreter { 0o755 } else { 0o644 })!
	}
	program := os.join_path(program_dir, 'program')
	os.write_file_array(program, artifact)!
	os.chmod(program, 0o755)!
	os.write_file(os.join_path(program_dir, 'case'), vm_case_bytes(scenario,
		bundle.manifest.options.trace_runtime)!)!
	os.write_file(os.join_path(program_dir, 'stdin'), scenario.stdin)!
	if bundle.manifest.options.trace_runtime {
		os.write_file(os.join_path(root, vm_native_trace[1..]), '')!
	}
	vm_stage_launcher(options, arch, work, os.join_path(root, 'init'))!
	if options.rootfs == 'ext4' {
		result := capture(Command{
			executable: executable('mke2fs')!
			args:       ['-q', '-t', 'ext4', '-O', '^has_journal', '-b', '4096', '-d', root,
				image_path, '32768']
		})!
		if result.status != 'exited' || result.exit_code != 0 {
			return error('building the QEMU ext4 image failed: ${result.stderr.trim_space()}')
		}
	} else {
		mut archive := os.create(image_path)!
		defer { archive.close() }
		vm_archive_dir(mut archive, root, '', 0)!
		vm_archive_entry(mut archive, 'TRAILER!!!', 0, 0, 1, []u8{})!
	}
}
