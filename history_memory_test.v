module main

import os

fn test_memory_access_records_are_opt_in_and_keep_event_order() {
	log := '\x1eVGUARD\tmemory\tr\t4\t0x123\t0x456\t9\t10\n' +
		'\x1eVGUARD\t78\t1\t2\tassignment\t7\n' +
		'\x1eVGUARD\tmemory\tw\t8\t0xabc\t0xdef\t9\t10\n'
	remaining, events := split_trace('keep\n' + log, memory_accesses: true) or { panic(err) }
	assert remaining == 'keep\n'
	assert events.map(it.kind) == ['memory_read', 'assignment', 'memory_write']
	load := events[0].memory or { panic('missing read') }
	assert load.size_bytes == 4
	assert load.address == '0x123'
	assert load.image_return_offset == '0x456'
	assert load.process_id == '9'
	assert load.thread_id == '10'
	assert events[1].value == '7'
	assert events[1].memory == none
	split_trace(log) or { return }
	assert false
}

fn test_record_and_replay_c_memory_accesses_from_the_instrumented_execution() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	host := os.user_os()
	arch := $if arm64 { 'arm64' } $else $if amd64 { 'amd64' } $else { '' }
	if compiler == '' || host !in ['linux', 'macos'] || arch == '' {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'history.v')
	os.write_file(source, 'module main

@[noinline]
fn increment(mut value []int) int {
	value[0] = value[0] + 5
	return value[0]
}

fn main() {
	mut values := [7]
	result := increment(mut values)
	if result > 10 {
		println(result)
	}
}
') or { panic(err) }
	manifest := build(BuildOptions{
		source:   os.real_path(source)
		compiler: os.real_path(compiler)
		backend:  'c'
		target:   '${host}/${arch}'
		args:     ['-cc', 'clang', '-gc', 'none']
	}, os.join_path(dir, 'build'), false) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	path := record_history(bundle, ExecutionCase{}, os.join_path(dir, 'recording'),
		calls:           true
		memory_accesses: true
	) or { panic(err) }
	history := open_history(path) or { panic(err) }
	assert history.evidence == call_memory_history_evidence
	assert history.instrumented_artifact_sha256.len == 64
	assert history.outcome.stdout == '12\n'
	assert history.outcome.stderr == ''
	mut start := -1
	mut end := -1
	for i, event in history.events {
		if event.kind == 'function_enter' && event.value == 'increment' {
			start = i
		}
		if event.kind == 'return' && event.value == '12' {
			end = i
			break
		}
	}
	assert start >= 0 && end > start
	assert history.events[start..end].any(it.kind == 'memory_read')
	assert history.events[start..end].any(it.kind == 'memory_write')
	assert history.events.any(it.kind == 'branch' && it.value == 'true')
	assert format_history(history).contains('image return offset 0x')
}

fn test_fastc_records_function_entries_when_the_target_compiler_has_tcc() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	if compiler == '' || os.user_os() != 'macos' {
		return
	}
	$if !arm64 {
		return
	}
	if !os.is_file(os.join_path(os.dir(compiler), 'thirdparty', 'tcc', 'include', 'libtcc.h')) {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'fastc.v')
	os.write_file(source, 'fn increment(value int) int {
	return value + 5
}

fn main() {
	initial := 7
	if initial > 0 {
		println(increment(initial))
	}
}
') or { panic(err) }
	manifest := build(BuildOptions{
		source:   os.real_path(source)
		compiler: os.real_path(compiler)
		backend:  'fastc'
		target:   'macos/arm64'
		args:     ['-cc', 'clang', '-gc', 'none']
	}, os.join_path(dir, 'build'), false) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	path := record_history(bundle, ExecutionCase{}, os.join_path(dir, 'recording'), calls: true) or {
		panic(err)
	}
	history := open_history(path) or { panic(err) }
	assert history.outcome.stdout == '12\n'
	assert history.events.filter(it.kind == 'function_enter').map(it.value) == ['main', 'increment']
	assert history.events.any(it.kind == 'assignment' && it.value == '7')
	memory_path := record_history(bundle, ExecutionCase{}, os.join_path(dir, 'memory'),
		calls:           true
		memory_accesses: true
	) or { panic(err) }
	memory := open_history(memory_path) or { panic(err) }
	assert memory.outcome == history.outcome
	assert memory.events.any(it.kind == 'memory_read')
	assert memory.events.any(it.kind == 'memory_write')
}
