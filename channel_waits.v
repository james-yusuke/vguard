module main

import os
import strconv

// Read only indefinite, process-private futex waits. A futex call with a
// deadline can make progress on its own.
fn private_futex_wait(line string, syscall_number string) ?u64 {
	words := line.fields()
	if words.len != 9 || words[0] != syscall_number {
		return none
	}
	address := parse_address(words[1]) or { return none }
	operation := parse_address(words[2]) or { return none }
	timeout := parse_address(words[4]) or { return none }
	// FUTEX_PRIVATE_FLAG with FUTEX_WAIT or FUTEX_WAIT_BITSET. The bitset
	// command also accepts FUTEX_CLOCK_REALTIME.
	if address == 0 || address % 4 != 0 || operation !in [u64(128), 137, 393]
		|| timeout != 0 {
		return none
	}
	return address
}

fn read_channel_wait_round(directory string, syscall_number string) !map[u64]u64 {
	tasks := os.ls(directory)!
	if tasks.len == 0 || tasks.len > 256 {
		return error('thread list is empty or exceeds the wait sampling limit')
	}
	mut waits := map[u64]u64{}
	for task in tasks {
		tid := strconv.parse_uint(task, 10, 64)!
		if tid == 0 {
			return error('invalid Linux task id')
		}
		line := os.read_file(os.join_path(directory, task, 'syscall'))!
		wait := private_futex_wait(line, syscall_number) or {
			return error('a task was outside an indefinite private futex wait')
		}
		waits[tid] = wait
	}
	return waits
}

fn sample_channel_waits(pid int) ?map[u64]u64 {
	if os.user_os() != 'linux' || pid <= 0 {
		return none
	}
	syscall_number := $if linux && amd64 { '202' } $else $if linux && arm64 { '98' } $else { '' }
	if syscall_number == '' {
		return none
	}
	directory := '/proc/${pid}/task'
	first := read_channel_wait_round(directory, syscall_number) or { return none }
	last := read_channel_wait_round(directory, syscall_number) or { return none }
	if first != last {
		return none
	}
	return last
}
