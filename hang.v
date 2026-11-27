module main

import encoding.hex
import strconv
import strings

const hang_prefix = '\x1eVGUARD-'

struct MutexWait {
	thread string
	mutex  string
	owner  string
}

struct ChannelWait {
	thread_id string
	resource  string
	operation string
}

struct HangFinding {
	kind           string
	evidence       string
	proof_evidence string        @[omitempty]
	cycle          []MutexWait   @[omitempty]
	iterations     u64           @[omitempty]
	thread_id      string        @[omitempty]
	channels       []ChannelWait @[omitempty]
	lock_waits     []MutexWait   @[omitempty]
}

struct LoopProgress {
	location  Location
	thread_id u64
	count     u64
}

struct HangLockRegion {
	start u64
	bytes u64
}

struct HangTrace {
mut:
	owners             map[string]u64
	waits              map[u64]string
	readers            map[string]map[u64]int
	read_waits         map[u64]bool
	loop               ?Location
	proven_form        string
	progress           map[string]LoopProgress
	channel_waits      map[u64]ChannelWait
	channel_semaphores map[u64]u64
	lock_regions       map[u64]HangLockRegion
}

fn trace_number(raw string) !u64 {
	value := strconv.parse_uint(raw, 10, 64)!
	if value == 0 {
		return error('zero in VGuard hang trace')
	}
	return value
}

fn (mut trace HangTrace) apply_event(fields []string, pid u64) ! {
	if fields.len == 6 && fields[0] == 'LOOP_PROVEN' {
		if trace_number(fields[4])! != pid {
			return
		}
		if fields[5] !in ['empty_literal_true_loop', 'empty_constant_true_loop',
			'unconditional_continue_loop', 'constant_control_loop'] {
			return error('unknown VGuard loop proof')
		}
		if trace.loop == none {
			trace.loop = read_hang_loop_location(fields)!
			trace.proven_form = fields[5]
		}
		return
	}
	if fields.len == 7 && fields[0] in ['LOOP_PROGRESS', 'LOOP_EXIT'] {
		if trace_number(fields[4])! != pid {
			return
		}
		tid := trace_number(fields[5])!
		count := trace_number(fields[6])!
		location := read_hang_loop_location(fields)!
		key := '${tid}:${fields[1]}:${location.line}:${location.column}'
		if fields[0] == 'LOOP_EXIT' {
			trace.progress.delete(key)
		} else {
			trace.progress[key] = LoopProgress{ location: location, thread_id: tid, count: count }
		}
		return
	}
	if fields.len in [5, 6] && fields[0] == 'CHANNEL' {
		trace.apply_channel_wait(fields, pid)!
		return
	}
	if fields.len != 5 && !(fields.len == 7 && fields[0] == 'MUTEX' && fields[4] in [
		'w',
		's',
	]) {
		return error('malformed VGuard hang trace record')
	}
	match fields[0] {
		'LOOP' {
			if trace_number(fields[4])! != pid {
				return
			}
			if trace.loop == none {
				trace.loop = read_hang_loop_location(fields)!
				trace.proven_form = 'empty_unconditional_loop'
			}
		}
		'MUTEX' {
			if trace_number(fields[1])! != pid {
				return
			}
			thread_id := trace_number(fields[2])!
			mutex := fields[3]
			if !mutex.starts_with('0x') || parse_address(mutex)! == 0 {
				return error('invalid VGuard mutex address')
			}
			match fields[4] {
				'w', 's' {
					if thread_id in trace.waits {
						return error('a VGuard thread already has a pending mutex wait')
					}
					trace.waits[thread_id] = mutex
					if fields.len == 7 {
						start := parse_address(fields[5])!
						bytes := trace_number(fields[6])!
						if start == 0 || start % 4 != 0 || bytes < 4 || bytes % 4 != 0 {
							return error('invalid VGuard pthread lock extent')
						}
						trace.lock_regions[thread_id] = HangLockRegion{ start: start, bytes: bytes }
					}
					if fields[4] == 's' {
						trace.read_waits[thread_id] = true
					}
				}
				'a', 'b', 'f' {
					if trace.waits[thread_id] != mutex || (fields[4] != 'f'
						&& trace.read_waits[thread_id] != (fields[4] == 'b')) {
						return error('a VGuard mutex wait completed without a matching request')
					}
					trace.waits.delete(thread_id)
					trace.read_waits.delete(thread_id)
					trace.lock_regions.delete(thread_id)
					if fields[4] == 'a' {
						trace.acquire(thread_id, mutex)!
					}
					if fields[4] == 'b' {
						trace.acquire_reader(thread_id, mutex)!
					}
				}
				't' {
					trace.acquire(thread_id, mutex)!
				}
				'u' {
					trace.acquire_reader(thread_id, mutex)!
				}
				'q' {
					mut readers := trace.readers[mutex]
					if readers[thread_id] == 0 {
						return error('a VGuard read lock was released by an unrecorded owner')
					}
					if readers[thread_id] == 1 {
						readers.delete(thread_id)
					} else {
						readers[thread_id]--
					}
					trace.readers[mutex] = readers
				}
				'r' {
					if trace.owners[mutex] != thread_id {
						return error('a VGuard mutex was released by an unrecorded owner')
					}
					trace.owners.delete(mutex)
				}
				else {
					return error('unknown VGuard mutex event')
				}
			}
		}
		else {
			return error('unknown VGuard hang trace record')
		}
	}
}

fn (mut trace HangTrace) apply_channel_wait(fields []string, pid u64) ! {
	if trace_number(fields[1])! != pid {
		return
	}
	tid := trace_number(fields[2])!
	resource := fields[3]
	if !resource.starts_with('0x') || parse_address(resource)! == 0 {
		return error('invalid VGuard channel wait resource')
	}
	semaphore := if fields.len == 6 { parse_address(fields[5])! } else { u64(0) }
	if fields.len == 6 && (semaphore == 0 || semaphore % 4 != 0) {
		return error('invalid VGuard channel semaphore address')
	}
	operation := match fields[4] {
		'S', 's' { 'send' }
		'R', 'r' { 'receive' }
		'M', 'm' { 'select' }
		else { return error('unknown VGuard channel wait action') }
	}
	if fields[4] in ['S', 'R', 'M'] {
		if tid in trace.channel_waits {
			return error('a thread already has a pending channel wait')
		}
		trace.channel_waits[tid] = ChannelWait{ thread_id: tid.str(), resource: resource, operation: operation }
		if semaphore != 0 {
			trace.channel_semaphores[tid] = semaphore
		}
	} else {
		wait := trace.channel_waits[tid]
		if wait.resource != resource || wait.operation != operation || trace.channel_semaphores[tid] != semaphore {
			return error('a channel wait completed without a matching request')
		}
		trace.channel_waits.delete(tid)
		trace.channel_semaphores.delete(tid)
	}
}

fn (trace &HangTrace) matches_channel_waits(sampled map[u64]u64) bool {
	// Require every live task and its exact semaphore word to be represented in
	// the runtime log. Stale records for other tasks also invalidate the match.
	return sampled.len > 0 && sampled == trace.channel_semaphores
		&& sampled.len == trace.channel_waits.len
}

fn (trace &HangTrace) mixed_waits(sampled map[u64]u64) ?[]MutexWait {
	if trace.waits.len == 0 || trace.channel_waits.len == 0
		|| sampled.len != trace.waits.len + trace.channel_waits.len {
		return none
	}
	mut waits := []MutexWait{}
	for tid in sampled.keys().sorted() {
		word := sampled[tid]
		if tid in trace.channel_waits {
			if tid in trace.waits || word != trace.channel_semaphores[tid] {
				return none
			}
			continue
		}
		region := trace.lock_regions[tid] or { return none }
		if word < region.start || word - region.start > region.bytes - 4 {
			return none
		}
		owners := trace.blocking_owners(tid)
		if owners.len == 0 || owners.any(it !in sampled) {
			return none
		}
		for owner in owners {
			waits << MutexWait{ thread: tid.str(), mutex: trace.waits[tid], owner: owner.str() }
		}
	}
	return waits
}

fn read_hang_loop_location(fields []string) !Location {
	line := strconv.atoi(fields[2])!
	column := strconv.atoi(fields[3])!
	file := hex.decode(fields[1])!.bytestr()
	if line < 1 || column < 1 || file == '' {
		return error('invalid VGuard loop location')
	}
	return Location{ file: file, line: line, column: column, precision: 'source' }
}

fn (mut trace HangTrace) acquire(thread_id u64, mutex string) ! {
	if mutex in trace.owners || trace.readers[mutex].len != 0 {
		return error('a VGuard mutex was acquired without a recorded release')
	}
	trace.owners[mutex] = thread_id
}

fn (mut trace HangTrace) acquire_reader(thread_id u64, mutex string) ! {
	if mutex in trace.owners {
		return error('a VGuard read lock was acquired while a writer was recorded')
	}
	mut readers := trace.readers[mutex]
	readers[thread_id]++
	trace.readers[mutex] = readers
}

fn read_hang_trace(stderr string, pid u64) !(string, HangTrace) {
	mut trace := HangTrace{}
	mut output := strings.new_builder(stderr.len)
	mut start := 0
	for {
		record := stderr.index_after(hang_prefix, start) or { break }
		output.write_string(stderr[start..record])
		payload := record + hang_prefix.len
		end := stderr.index_after('\n', payload) or {
			return error('the last VGuard hang trace record was incomplete')
		}
		trace.apply_event(stderr[payload..end].split('\t'), pid)!
		start = end + 1
	}
	output.write_string(stderr[start..])
	return output.str(), trace
}

struct HangWalk {
	thread_id u64
	blockers  []u64
mut:
	next int
}

fn (trace &HangTrace) blocking_owners(thread_id u64) []u64 {
	mutex := trace.waits[thread_id] or { return [] }
	if owner := trace.owners[mutex] {
		return [owner]
	}
	if trace.read_waits[thread_id] {
		return []
	}
	return trace.readers[mutex].keys().sorted()
}

fn (trace &HangTrace) wait_cycle() []MutexWait {
	mut visited := map[u64]bool{}
	for first in trace.waits.keys().sorted() {
		if first in visited {
			continue
		}
		mut stack := [HangWalk{ thread_id: first, blockers: trace.blocking_owners(first) }]
		mut active := {
			first: 0
		}
		for stack.len > 0 {
			last := stack.len - 1
			walk := stack[last]
			if walk.next >= walk.blockers.len {
				active.delete(walk.thread_id)
				visited[walk.thread_id] = true
				stack.delete_last()
				continue
			}
			owner := walk.blockers[walk.next]
			stack[last].next++
			if index := active[owner] {
				mut cycle := []MutexWait{}
				for step in stack[index..] {
					cycle << MutexWait{
						thread: step.thread_id.str()
						mutex:  trace.waits[step.thread_id]
						owner:  step.blockers[step.next - 1].str()
					}
				}
				return cycle
			}
			if owner !in visited {
				active[owner] = stack.len
				stack << HangWalk{ thread_id: owner, blockers: trace.blocking_owners(owner) }
			}
		}
	}
	return []
}

fn diagnose_hang(outcome Outcome, timeout_ms int) Diagnosis {
	report := ordinary_diagnosis(outcome)
	stderr, trace := read_hang_trace(outcome.stderr, u64(outcome.pid)) or {
		return Diagnosis{ ...report, hang_error: err.msg() }
	}
	clean := Diagnosis{ ...report, outcome: Outcome{ ...outcome, stderr: stderr } }
	if outcome.status != 'timeout' {
		return clean
	}
	limited := Diagnosis{
		...clean
		execution_limit: ExecutionLimit{
			kind:     'wall_clock_ms'
			limit:    u64(timeout_ms)
			evidence: 'process_timeout'
		}
	}
	channels := trace.channel_waits.keys().sorted().map(trace.channel_waits[it])
	cycle := trace.wait_cycle()
	if cycle.len > 0 {
		return Diagnosis{
			...limited
			kind:   'deadlock'
			reason: 'instrumented mutex waits form a cycle'
			hang:   HangFinding{ kind: 'mutex_cycle', evidence: 'instrumented_mutex_events', cycle: cycle, channels: channels }
		}
	}
	if location := trace.loop {
		reason := match trace.proven_form {
			'empty_literal_true_loop' {
				'execution entered an empty loop with a literal true condition'
			}
			'empty_constant_true_loop' {
				'execution entered an empty loop with a condition that always evaluates to true'
			}
			'unconditional_continue_loop' {
				'execution entered a loop with a single unconditional continue'
			}
			'constant_control_loop' {
				'execution entered a loop whose constant branches only continue the loop'
			}
			else { 'execution entered an empty unconditional loop' }
		}
		return Diagnosis{
			...limited
			kind:     'infinite_loop'
			reason:   reason
			location: location
			hang:     HangFinding{
				kind:           trace.proven_form
				evidence:       'instrumented_loop_entry'
				proof_evidence: if trace.proven_form == 'constant_control_loop' {
					'compiler_static_control_flow'
				} else {
					''
				}
				channels:       channels
			}
		}
	}
	if trace.matches_channel_waits(outcome.channel_waits) {
		return Diagnosis{
			...limited
			kind:   'deadlock'
			reason: 'all live threads are blocked in process-private channel waits without a deadline'
			hang:   HangFinding{ kind: 'all_threads_channel_wait', evidence: 'linux_private_channel_futexes', channels: channels }
		}
	}
	if waits := trace.mixed_waits(outcome.channel_waits) {
		return Diagnosis{
			...limited
			kind:   'deadlock'
			reason: 'all live threads are blocked in process-private channel or owned lock waits without a deadline'
			hang:   HangFinding{
				kind:       'all_threads_mixed_wait'
				evidence:   'linux_private_channel_and_lock_futexes'
				channels:   channels
				lock_waits: waits
			}
		}
	}
	mut best := LoopProgress{}
	for _, progress in trace.progress {
		if progress.count > best.count {
			best = progress
		}
	}
	if best.count > 0 {
		return Diagnosis{
			...limited
			reason:   'execution timed out after repeated loop iterations'
			location: best.location
			hang:     HangFinding{
				kind:       'repeating_loop'
				evidence:   'observed_loop_iterations'
				iterations: best.count
				thread_id:  best.thread_id.str()
				channels:   channels
			}
		}
	}
	if channels.len > 0 {
		return Diagnosis{
			...limited
			reason: 'execution timed out with pending channel waits'
			hang:   HangFinding{ kind: 'channel_wait', evidence: 'instrumented_channel_waits', channels: channels }
		}
	}
	return limited
}

fn (bundle &Bundle) run_hang_trace(scenario ExecutionCase) !Diagnosis {
	if !bundle.manifest.options.trace_hangs || scenario.harness != '' {
		return error('--hangs requires a standalone executable built with --trace-hangs')
	}
	return diagnose_hang(scenario.run_binary(bundle.artifact, observe_channel_waits: true)!,
		scenario.timeout_ms)
}
