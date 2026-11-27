module main

import os
import strconv

struct MemoryAccess {
	address             string
	image_return_offset string
	size_bytes          int
	process_id          string
	thread_id           string
}

fn memory_history_build_options(options BuildOptions, work string) !BuildOptions {
	host_arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	if options.backend !in ['c', 'fastc'] || os.user_os() !in ['linux', 'macos'] || host_arch == ''
		|| options.target != os.user_os() + '/' + host_arch || options.object
		|| options.args.any(it in ['-shared', '--shared']) {
		return error('--memory-accesses requires a standalone C or FastC executable for the Linux or macOS host')
	}
	mut args := options.args.clone()
	index := args.index('-cc')
	cc := if index >= 0 {
		if index + 1 >= args.len || !os.file_name(args[index + 1]).contains('clang') {
			return error('--memory-accesses requires Clang')
		}
		args[index + 1]
	} else {
		args << ['-cc', 'clang']
		'clang'
	}
	runtime := os.join_path(work, 'history_memory.c')
	object := os.join_path(work, 'history_memory.o')
	os.write_file(runtime, $embed_file('compiler/history_memory.c').to_string())!
	compiled := capture(Command{
		executable: executable(cc)!
		args:       ['-std=c11', '-O2', '-c', runtime, '-o', object]
	})!
	if compiled.status != 'exited' || compiled.exit_code != 0 {
		return error('compiling the memory history callbacks failed: ${compiled.stderr}')
	}
	args << ['-d', 'vguard_access_trace', '-cflags',
		'-fsanitize-coverage=trace-pc,trace-loads,trace-stores', '-ldflags', shell_argument(object)!]
	return BuildOptions{ ...options, args: args }
}

fn read_memory_access(fields []string) !TraceEvent {
	if fields.len != 7 || fields[1] !in ['r', 'w'] || fields[2] !in ['1', '2', '4', '8', '16']
		|| !fields[3].starts_with('0x') || !fields[4].starts_with('0x') {
		return error('malformed VGuard memory access event')
	}
	address := parse_address(fields[3])!
	offset := parse_address(fields[4])!
	pid := strconv.parse_uint(fields[5], 10, 64)!
	tid := strconv.parse_uint(fields[6], 10, 64)!
	if pid == 0 || tid == 0 {
		return error('invalid process or thread in VGuard memory access event')
	}
	return TraceEvent{
		kind:   if fields[1] == 'r' { 'memory_read' } else { 'memory_write' }
		memory: MemoryAccess{
			address:             hex_address(address)
			image_return_offset: hex_address(offset)
			size_bytes:          fields[2].int()
			process_id:          pid.str()
			thread_id:           tid.str()
		}
	}
}
