module main

import json2
import os

fn test_hang_trace_reports_only_cycles_of_observed_waits() {
	prefix := '\x1eVGUARD-MUTEX\t'
	log := [
		'94\t1\t0x10\tt',
		'94\t2\t0x20\tw',
		'94\t2\t0x20\ta',
		'94\t3\t0x30\tw',
		'94\t3\t0x30\tf',
		'94\t3\t0x10\tw',
		'94\t1\t0x20\tw',
		'94\t2\t0x10\tw',
		'95\t3\t0x10\tr',
	].map(prefix + it + '\n').join('')
	timed_out := Outcome{ status: 'timeout', pid: 94, stderr: 'keep\n' + log }
	report := diagnose_hang(timed_out, 100)
	assert report.kind == 'deadlock'
	assert report.outcome.stderr == 'keep\n'
	hang := report.hang or { panic('missing cycle') }
	assert hang.cycle == [
		MutexWait{ thread: '1', mutex: '0x20', owner: '2' },
		MutexWait{ thread: '2', mutex: '0x10', owner: '1' },
	]
	assert diagnose_hang(Outcome{ ...timed_out, pid: 93 }, 100).kind == 'timeout'
	assert diagnose_hang(Outcome{ ...timed_out, status: 'exited' }, 100).hang == none
	incomplete := diagnose_hang(Outcome{ ...timed_out, stderr: log + prefix }, 100)
	assert incomplete.kind == 'timeout'
	assert incomplete.hang_error.contains('incomplete')
}

fn test_hang_trace_does_not_equate_one_wait_with_deadlock() {
	log := '\x1eVGUARD-MUTEX\t94\t1\t0x10\tt\n' +
		'\x1eVGUARD-MUTEX\t94\t2\t0x10\tw\n'
	report := diagnose_hang(Outcome{ status: 'timeout', pid: 94, stderr: log }, 100)
	assert report.kind == 'timeout'
	assert report.hang == none
	limit := report.execution_limit or { panic('missing timeout evidence') }
	assert limit.evidence == 'process_timeout'
}

fn test_companion_compiler_reports_a_mutex_cycle_and_an_entered_unconditional_loop() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	host := os.user_os()
	arch := $if arm64 { 'arm64' } $else $if amd64 { 'amd64' } $else { '' }
	if compiler == '' || host !in ['linux', 'macos'] || arch == '' {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'hang.v')
	os.write_file(source, "module main

import os
import sync
import time

fn worker(mut first sync.Mutex, mut second sync.Mutex, ready chan bool, start chan bool) {
	first.lock()
	ready <- true
	_ := <-start
	second.lock()
	second.unlock()
	first.unlock()
}

fn main() {
	match os.args[1] {
		'spin' { for {} }
		'literal-spin' { for (true) {} }
		'constant-spin' { for !false && (true != false) {} }
		'short-circuit-spin' { for true || unexpected_condition() {} }
		'continue-spin' { for { continue } }
		'literal-continue' { for true { continue } }
		'constant-branches' {
			for {
				if false && unexpected_condition() { break }
				if false { return }
			}
		}
		'constant-else' {
			for true {
				if false { break } else if !false { continue }
			}
		}
		'reachable-break' {
			for {
				if true { break }
			}
			eprintln('left through break')
		}
		'labeled-break' {
			outer: // The loop must keep its label.
			for {
				break outer
			}
			eprintln('left through label')
		}
		'effectful-condition' {
			mut calls := [0]
			for condition(mut calls) || true {}
		}
		'sleep' { time.sleep(5 * time.second) }
		'busy' {
			mut n := 0
			for {
				n++
				if n == 1000 {
					n = 0
				}
			}
		}
		'conditional' {
			mut n := 0
			for n >= 0 {
				n++
				if n == 1000 {
					n = 0
				}
			}
		}
		'finite' {
			mut n := 0
			for {
				n++
				if n == 1000 {
					break
				}
			}
			time.sleep(5 * time.second)
		}
		'receive' {
			ch := chan int{}
			println(<-ch)
		}
		'reader-writer' {
			mut rw := sync.new_rwmutex()
			mut mutex := sync.new_mutex()
			ready := chan bool{cap: 2}
			start := chan bool{cap: 2}
			reader := spawn shared_reader(mut rw, mut mutex, ready, start)
			writer := spawn exclusive_writer(mut rw, mut mutex, ready, start)
			_ := <-ready
			_ := <-ready
			start <- true
			start <- true
			reader.wait()
			writer.wait()
		}
		'ok' {
			mut mutex := sync.new_mutex()
			assert mutex.try_lock()
			mutex.unlock()
			eprintln('finished')
		}
		else {
			mut first := sync.new_mutex()
			mut second := sync.new_mutex()
			ready := chan bool{cap: 2}
			start := chan bool{cap: 2}
			left := spawn worker(mut first, mut second, ready, start)
			right := spawn worker(mut second, mut first, ready, start)
			_ := <-ready
			_ := <-ready
			start <- true
			start <- true
			left.wait()
			right.wait()
		}
	}
}

fn unexpected_condition() bool {
	eprintln('unexpected condition call')
	return false
}

fn condition(mut calls []int) bool {
	calls[0]++
	if calls[0] == 2 {
		eprintln('condition ran twice')
		exit(0)
	}
	return false
}

fn shared_reader(mut rw sync.RwMutex, mut mutex sync.Mutex, ready chan bool, start chan bool) {
	rw.rlock()
	ready <- true
	_ := <-start
	mutex.lock()
	mutex.unlock()
	rw.runlock()
}

fn exclusive_writer(mut rw sync.RwMutex, mut mutex sync.Mutex, ready chan bool, start chan bool) {
	mutex.lock()
	ready <- true
	_ := <-start
	rw.lock()
	rw.unlock()
	mutex.unlock()
}
") or { panic(err) }
	manifest := build(BuildOptions{
		source:      os.real_path(source)
		compiler:    os.real_path(compiler)
		backend:     'c'
		target:      '${host}/${arch}'
		trace_hangs: true
		args:        ['-cc', 'clang', '-gc', 'none']
	}, os.join_path(dir, 'build'), false) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	for mode, kind in {
		'ok':                  'exited'
		'spin':                'infinite_loop'
		'literal-spin':        'infinite_loop'
		'constant-spin':       'infinite_loop'
		'short-circuit-spin':  'infinite_loop'
		'continue-spin':       'infinite_loop'
		'literal-continue':    'infinite_loop'
		'constant-branches':   'infinite_loop'
		'constant-else':       'infinite_loop'
		'reachable-break':     'exited'
		'labeled-break':       'exited'
		'effectful-condition': 'exited'
		'sleep':               'timeout'
		'deadlock':            'deadlock'
		'reader-writer':       'deadlock'
		'busy':                'timeout'
		'conditional':         'timeout'
		'finite':              'timeout'
		'receive':             'timeout'
	} {
		report := bundle.run(ExecutionCase{ argv: [mode], timeout_ms: 1000 }, hangs: true) or {
			panic(err)
		}
		assert report.kind == kind || (mode == 'receive' && report.kind == 'deadlock'), '${mode}: ${report.kind} ${report.hang_error} ${report.outcome.stderr}'
		assert report.hang_error == ''
		if mode == 'ok' {
			assert report.outcome.exit_code == 0
			assert report.outcome.stderr == 'finished\n'
		} else if mode == 'effectful-condition' {
			assert report.outcome.exit_code == 0
			assert report.outcome.stderr == 'condition ran twice\n'
			assert report.hang == none
		} else if mode == 'spin' {
			location := report.location or { panic('missing loop source') }
			assert location.file == os.real_path(source)
			assert location.line == 18
		} else if mode in ['literal-spin', 'continue-spin', 'literal-continue'] {
			finding := report.hang or { panic('missing loop entry') }
			assert finding.evidence == 'instrumented_loop_entry'
			assert finding.kind == if mode == 'literal-spin' {
				'empty_literal_true_loop'
			} else {
				'unconditional_continue_loop'
			}
		} else if mode in ['constant-spin', 'short-circuit-spin'] {
			finding := report.hang or { panic('missing constant loop entry') }
			assert finding.evidence == 'instrumented_loop_entry'
			assert finding.kind == 'empty_constant_true_loop'
			assert report.outcome.stderr == ''
		} else if mode in ['constant-branches', 'constant-else'] {
			finding := report.hang or { panic('missing loop entry with constant control flow') }
			assert finding.kind == 'constant_control_loop'
			assert finding.evidence == 'instrumented_loop_entry'
			assert finding.proof_evidence == 'compiler_static_control_flow'
			assert report.outcome.stderr == ''
		} else if mode in ['reachable-break', 'labeled-break'] {
			assert report.hang == none
			assert report.outcome.stderr == if mode == 'reachable-break' {
				'left through break\n'
			} else {
				'left through label\n'
			}
		} else if mode in ['deadlock', 'reader-writer'] {
			finding := report.hang or { panic('missing deadlock evidence') }
			assert finding.cycle.len == 2
			assert finding.cycle[0].owner == finding.cycle[1].thread
			assert finding.cycle[1].owner == finding.cycle[0].thread
		} else if mode in ['busy', 'conditional'] {
			finding := report.hang or { panic('missing loop iterations') }
			assert finding.kind == 'repeating_loop'
			assert finding.iterations >= 64
		} else if mode == 'receive' {
			finding := report.hang or { panic('missing channel wait') }
			assert finding.evidence == if report.kind == 'deadlock' {
				'linux_private_channel_futexes'
			} else {
				'instrumented_channel_waits'
			}
			assert finding.channels.len == 1 && finding.channels[0].operation == 'receive'
		} else {
			assert report.hang == none
		}
	}
}

fn test_private_futex_wait_checks_operation_and_deadline() {
	line := '202 0x130 0x189 0x0 0x0 0x0 0xffffffff 0x240 0x320'
	assert private_futex_wait(line, '202') or { 0 } == 0x130
	assert private_futex_wait(line, '98') == none
	assert private_futex_wait(line.replace('0x189', '0x9'), '202') == none
	assert private_futex_wait(line.replace('0x189 0x0 0x0', '0x189 0x0 0x114'), '202') == none
	assert private_futex_wait('running', '202') == none
}

fn test_channel_deadlock_requires_every_task_and_exact_wait_word() {
	start := '\x1eVGUARD-CHANNEL\t23\t23\t0x1000\tR\t0x1100\n' +
		'\x1eVGUARD-CHANNEL\t23\t24\t0x1100\tS\t0x1200\n'
	sample := {
		u64(23): u64(0x1100)
		u64(24): u64(0x1200)
	}
	outcome := Outcome{ status: 'timeout', pid: 23, stderr: start, channel_waits: sample }
	report := diagnose_hang(outcome, 100)
	assert report.kind == 'deadlock'
	finding := report.hang or { panic('missing channel evidence') }
	assert finding.evidence == 'linux_private_channel_futexes'
	assert finding.channels.map(it.thread_id) == ['23', '24']
	assert !json2.encode(report).contains('"channel_waits"')
	assert diagnose_hang(Outcome{
		...outcome
		channel_waits: {
			u64(23): u64(0x1100)
		}
	}, 100).kind == 'timeout'
	assert diagnose_hang(Outcome{ ...outcome, stderr: start + '\x1eVGUARD-CHANNEL\t23\t24\t0x1100\ts\t0x1200\n' }, 100).kind == 'timeout'
	assert diagnose_hang(Outcome{ ...outcome, stderr: start.replace('\t0x1200\n', '\t0x1300\n') }, 100).kind == 'timeout'
	assert diagnose_hang(Outcome{ ...outcome, stderr: '\x1eVGUARD-CHANNEL\t23\t23\t0x1000\tR\n' }, 100).kind == 'timeout'
}

fn test_mixed_wait_requires_the_measured_lock_word_and_blocked_owner() {
	log := '\x1eVGUARD-MUTEX\t23\t23\t0x1300\tt\n' +
		'\x1eVGUARD-CHANNEL\t23\t23\t0x1000\tR\t0x1100\n' +
		'\x1eVGUARD-MUTEX\t23\t24\t0x1300\tw\t0x1300\t40\n'
	outcome := Outcome{
		status:        'timeout'
		pid:           23
		stderr:        log
		channel_waits: {
			u64(23): u64(0x1100)
			u64(24): u64(0x1308)
		}
	}
	report := diagnose_hang(outcome, 100)
	assert report.kind == 'deadlock'
	finding := report.hang or { panic('missing mixed wait evidence') }
	assert finding.evidence == 'linux_private_channel_and_lock_futexes'
	assert finding.lock_waits == [MutexWait{ thread: '24', mutex: '0x1300', owner: '23' }]
	assert finding.cycle.len == 0
	assert diagnose_hang(Outcome{ ...outcome, stderr: log.replace('\t0x1300\t40', '\t0x1300\t8') }, 100).kind == 'timeout'
	assert diagnose_hang(Outcome{ ...outcome, stderr: log.replace('\t23\t0x1300\tt', '\t25\t0x1300\tt') }, 100).kind == 'timeout'
	assert diagnose_hang(Outcome{ ...outcome, stderr: log.replace('\t0x1300\t40', '') }, 100).kind == 'timeout'
}

const channel_timeout_fixture = "import os
import sync
import time

fn blocked_sender(c chan int) {
	c <- 42
}

fn delayed_sender(c chan int) {
	time.sleep(5 * time.second)
	c <- 42
}

fn lock_sender(mut gate sync.Mutex, c chan int) {
	gate.lock()
	gate.unlock()
	c <- 42
}

fn writer_sender(mut gate sync.RwMutex, c chan int) {
	gate.lock()
	gate.unlock()
	c <- 42
}

fn main() {
	empty := chan int{}
	match os.args[1] {
		'blocked' {
			full := chan int{cap: 1}
			full <- 1
			spawn blocked_sender(full)
			println(<-empty)
		}
		'delayed' {
			spawn delayed_sender(empty)
			println(<-empty)
		}
		'mixed' {
			mut gate := sync.new_mutex()
			gate.lock()
			spawn lock_sender(mut gate, empty)
			println(<-empty)
			gate.unlock()
		}
		'mixed-rw' {
			mut gate := sync.new_rwmutex()
			gate.rlock()
			spawn writer_sender(mut gate, empty)
			println(<-empty)
			gate.runlock()
		}
		'timed' {
			select {
				value := <-empty { println(value) }
				5 * time.second { println('deadline reached') }
			}
		}
		else { println(<-empty) }
	}
}
"

fn test_companion_compiler_matches_linux_channel_futexes() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	if compiler == '' || os.user_os() != 'linux' || arch == '' {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'channel.v')
	os.write_file(source, channel_timeout_fixture) or { panic(err) }
	manifest := build(BuildOptions{
		source:      source
		compiler:    os.real_path(compiler)
		backend:     'c'
		target:      'linux/' + arch
		trace_hangs: true
		args:        ['-cc', 'clang', '-gc', 'none']
	}, os.join_path(dir, 'build'), false) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	for mode in ['blocked', 'receive', 'delayed', 'timed', 'mixed', 'mixed-rw'] {
		report := bundle.run(ExecutionCase{ argv: [mode], timeout_ms: 700 }, hangs: true) or {
			panic(err)
		}
		assert report.hang_error == '', report.hang_error
		finding := report.hang or { panic('${mode}: ${report.reason}') }
		assert finding.channels.len == if mode == 'blocked' { 2 } else { 1 }
		if mode in ['delayed', 'timed'] {
			assert report.kind == 'timeout' && finding.kind == 'channel_wait'
		} else if os.getenv('VGUARD_TEST_CHANNEL_FUTEX') == '1' || report.kind == 'deadlock' {
			assert report.kind == 'deadlock', '${mode}: ${report.reason}'
			if mode.starts_with('mixed') {
				assert finding.evidence == 'linux_private_channel_and_lock_futexes'
				assert finding.channels.len == 1 && finding.lock_waits.len == 1
				assert finding.lock_waits[0].owner == finding.channels[0].thread_id
			} else {
				assert finding.evidence == 'linux_private_channel_futexes'
			}
		}
	}
}
