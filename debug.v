module main

import os
import strconv
import json2

struct Diagnosis {
	kind               string
	reason             string
	address            string
	location           ?Location
	location_error     string
	ssa_file           string
	ssa_original_file  string @[omitempty]
	ssa_error          string
	ssa_excerpt        SsaExcerpt         @[skip]
	ssa_dataflow       ?SsaDataflow       @[omitempty]
	ssa_dataflow_error string             @[omitempty]
	runtime_ssa        ?RuntimeSsaReport  @[omitempty]
	runtime_ssa_error  string             @[omitempty]
	runtime_stop       ?RuntimeStopAnchor @[skip]
	machine_error      string             @[omitempty]
	register_snapshot  ?RegisterSnapshot  @[omitempty]
	stopped_ssa        ?StoppedSsa        @[omitempty]
	stopped_frames     []StoppedSsa       @[omitempty]
	stopped_ssa_error  string             @[omitempty]
	stack_trace        ?DebuggerStack     @[omitempty]
	stack_error        string             @[omitempty]
	execution_limit    ?ExecutionLimit    @[omitempty]
	hang               ?HangFinding       @[omitempty]
	hang_error         string             @[omitempty]
	memory_errors      []MemoryViolation  @[omitempty]
	outcome            Outcome
}

struct NativeStop {
	reason            string
	pcs               []u64
	stop_pc           ?u64
	load_base         ?u64
	exit_code         ?int
	stack_trace       ?DebuggerStack
	register_snapshot ?RegisterSnapshot
	breakpoint        bool
	runtime_thread    DebuggerRuntimeThread
}

struct DebuggerRuntimeThread {
	process u64
	lwp     u64
	number  int
mut:
	frames []DebuggerRuntimeFrame
}

struct DebuggerRuntimeFrame {
	index int
	pc    u64
	fp    u64
}

struct DebuggerStack {
	debugger string
	evidence string = 'debugger_at_stop'
	text     string
	threads  []DebuggerThread @[omitempty]
}

@[params]
struct RunOptions {
	stack               bool
	fuel                u64
	machine             bool
	hangs               bool
	runtime_ssa         bool
	recover_ssa         bool
	stop_at             ?u64
	runtime_stop_anchor bool
}

struct ExecutionLimit {
	kind     string
	limit    u64
	evidence string
}

fn debugger_arg(value string) !string {
	if value.contains_any('\x00\r\n') {
		return error('LLDB command arguments cannot contain NUL or line breaks')
	}
	return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'
}

fn read_output(path string) !string {
	if !os.is_file(path) {
		return ''
	}
	if os.file_size(path) > u64(capture_limit) {
		return error('debug target exceeded the output capture limit')
	}
	return os.read_file(path)
}

fn (bundle &Bundle) run(scenario ExecutionCase, options RunOptions) !Diagnosis {
	if options.recover_ssa && (os.user_os() != 'linux' || bundle.image.format != 'elf'
		|| bundle.manifest.options.backend !in ['amd64', 'arm64'] || bundle.manifest.options.memory
		|| scenario.harness != '' || options.hangs || options.fuel > 0) {
		return error('--recover-ssa requires a standalone Linux native executable run under GDB')
	}
	if options.stop_at != none && !options.recover_ssa {
		return error('--at requires --recover-ssa')
	}
	if options.fuel > 0 && (bundle.image.format != 'wasm' || scenario.harness != '') {
		return error('--fuel requires a standalone WebAssembly build')
	}
	if bundle.image.relocatable || (!bundle.image.runnable && scenario.harness == '') {
		return error('use resolve for object or raw code, or specify a harness for a shared library')
	}
	if options.hangs {
		return bundle.run_hang_trace(scenario)
	}
	if options.runtime_ssa {
		return bundle.run_runtime_ssa(scenario, options)
	}
	if bundle.manifest.options.memory && bundle.image.format != 'wasm' {
		report := bundle.with_crash_ssa(bundle.run_memory(scenario)!)
		if options.stack && report.kind != 'exited' {
			return Diagnosis{
				...report
				stack_error: 'this sanitizer run uses the stack reported by the sanitizer'
			}
		}
		return report
	}
	report := if bundle.image.format == 'wasm' {
		outcome := bundle.run_wasm(scenario, fuel: options.fuel)!
		limited := with_wasm_limit(bundle.wasm_diagnosis(outcome), options.fuel, scenario.timeout_ms)
		resolved := bundle.with_wasm_function_body(limited)
		diagnosis := if bundle.manifest.options.memory {
			with_wasm_memory(bundle.with_wasm_heap_memory(resolved))
		} else {
			resolved
		}
		if options.stack {
			bundle.with_wasm_backtrace(diagnosis)
		} else {
			diagnosis
		}
	} else {
		bundle.run_debugger(scenario, options)!
	}
	if options.stack && report.kind in ['crash', 'timeout', 'fuel_exhausted'] && report.stack_trace == none {
		return bundle.with_crash_ssa(Diagnosis{
			...report
			stack_error: if bundle.image.format == 'wasm' {
				'Wasmtime did not report a WebAssembly trap backtrace'
			} else {
				'no native all-thread backtrace was captured at the stop'
			}
		})
	}
	return bundle.with_crash_ssa(report)
}

fn possible_native_stop(outcome Outcome) bool {
	if outcome.status == 'signal' {
		return true
	}
	$if windows {
		return u32(outcome.exit_code) & 0xc0000000 == 0xc0000000
	} $else {
		return false
	}
}

fn ordinary_diagnosis(outcome Outcome) Diagnosis {
	return Diagnosis{
		kind:    if possible_native_stop(outcome) { 'crash' } else { outcome.status }
		outcome: outcome
	}
}

fn (bundle &Bundle) run_debugger(scenario ExecutionCase, options RunOptions) !Diagnosis {
	work := temp_directory()!
	defer {
		os.rmdir_all(work) or {}
	}
	input := os.join_path(work, 'stdin')
	stdout := os.join_path(work, 'stdout')
	stderr := os.join_path(work, 'stderr')
	os.write_file(input, scenario.stdin)!
	program := if scenario.harness == '' { bundle.artifact } else { scenario.harness }
	mut env := scenario.env.clone()
	if scenario.harness != '' {
		env['VGUARD_ARTIFACT'] = bundle.artifact
	}
	debug_case := ExecutionCase{
		...scenario
		env: env
	}
	registers := if options.machine {
		native_debug_registers(bundle.manifest.options.backend)
	} else {
		[]string{}
	}
	plan := if options.recover_ssa {
		?RecoveryPlan(bundle.recovery_plan(options.stack)!)
	} else {
		?RecoveryPlan(none)
	}
	mut stop_anchor := u64(0)
	mut debugger_commands := if recovery_plan := plan {
		if address := options.stop_at {
			region := recovery_plan.region_at(address) or {
				return error('--at must identify native code covered by the executable source map')
			}
			stop_anchor = region.start
		}
		prepare_gdb_recovery(recovery_plan, work)!
	} else {
		[]string{}
	}
	if options.runtime_stop_anchor && os.user_os() == 'linux' {
		register := if bundle.manifest.options.backend == 'amd64' { 'rbp' } else { 'x29' }
		script := $embed_file('compiler/runtime_stop_gdb.py').to_string()
		debugger_commands << ['-ex', 'python vguard_frame_register = "${register}"', '-ex',
			'python exec(${json2.encode(script)})']
	}
	result, stop := if os.user_os() == 'linux' {
		run_gdb(program, bundle.artifact, debug_case, input, stdout, stderr, options.stack, registers,
			options.stop_at, stop_anchor, debugger_commands)!
	} else {
		run_lldb(program, bundle.artifact, debug_case, input, stdout, stderr, options.stack, registers)!
	}
	outcome := Outcome{
		...result
		stdout:    read_output(stdout)!
		stderr:    read_output(stderr)!
		status:    if stop.breakpoint {
			'stopped'
		} else if stop.reason != '' {
			'signal'
		} else {
			result.status
		}
		exit_code: if stop.breakpoint || stop.reason != '' {
			-1
		} else {
			stop.exit_code or { result.exit_code }
		}
	}
	if result.status != 'exited' {
		return ordinary_diagnosis(outcome)
	}
	if stop.reason == '' && !stop.breakpoint {
		if options.stop_at != none {
			return Diagnosis{ kind: 'inconclusive', reason: 'execution did not reach the requested instruction', outcome: outcome }
		}
		if stop.exit_code != none {
			return ordinary_diagnosis(outcome)
		}
		return Diagnosis{
			kind:           'inconclusive'
			reason:         'debugger did not reproduce a fatal stop'
			location_error: (result.stdout + result.stderr).trim_space()
			outcome:        outcome
		}
	}
	mut report := bundle.describe_debugger_stop(outcome, stop)
	if recovery_plan := plan {
		report = bundle.with_stopped_ssa(report, stop, work, result.stderr, recovery_plan) or {
			Diagnosis{ ...report, stopped_ssa_error: err.msg() }
		}
	}
	return report
}

fn (bundle &Bundle) describe_debugger_stop(outcome Outcome, stop NativeStop) Diagnosis {
	kind := if stop.breakpoint { 'stopped' } else { 'crash' }
	reason := if stop.breakpoint { 'requested instruction reached' } else { stop.reason }
	mut location_error := 'no frame belonging to the build artifact could be located'
	mut stack_trace := stop.stack_trace
	stop_address := if pc := stop.stop_pc { hex_address(pc) } else { '' }
	if base := stop.load_base {
		if stack := stack_trace {
			stack_trace = bundle.with_mapped_stack(stack, base)
		}
		for i, pc in stop.pcs {
			location := bundle.map_debugger_frame(pc, base, i > 0 || stop.stop_pc == none) or {
				location_error = err.msg()
				continue
			}
			return Diagnosis{
				kind:              kind
				reason:            reason
				address:           stop_address
				stack_trace:       stack_trace
				register_snapshot: stop.register_snapshot
				location:          location
				runtime_stop:      stop.runtime_thread.anchor(pc, location)
				outcome:           outcome
			}
		}
	} else {
		location_error = 'debugger did not report the artifact load address'
	}
	return Diagnosis{
		kind:              kind
		reason:            reason
		address:           stop_address
		location_error:    location_error
		stack_trace:       stack_trace
		register_snapshot: stop.register_snapshot
		outcome:           outcome
	}
}

fn (observed DebuggerRuntimeThread) anchor(pc u64, location Location) ?RuntimeStopAnchor {
	if observed.process == 0 || observed.lwp == 0 {
		return none
	}
	caller := location.precision == 'caller_frame'
	mut fp := u64(0)
	mut frame_index := 0
	// These top-frame instructions can change the frame register before the stop.
	if caller || location.ssa_opcode !in ['ret', 'inline_asm'] {
		for frame in observed.frames {
			if (frame.index > 0) == caller && frame.pc == pc {
				fp = frame.fp
				frame_index = frame.index
				break
			}
		}
	}
	return RuntimeStopAnchor{
		process:   observed.process
		lwp:       observed.lwp
		frame:     fp
		caller:    caller
		thread:    observed.number
		frame_idx: frame_index
	}
}

fn run_lldb(program string, artifact string, scenario ExecutionCase, input string, stdout string, stderr string, stack bool, registers []string) !(Outcome, NativeStop) {
	path := executable('lldb')!
	launch := 'process launch -i ' + debugger_arg(input)! + ' -o ' + debugger_arg(stdout)! +
		' -e ' + debugger_arg(stderr)!
	mut args := ['--no-lldbinit', '--batch', '-o', 'settings set target.disable-aslr false', '-o',
		launch, '-k', 'thread list', '-k', 'register read pc', '-k', 'image list -h -f', '-k',
		'bt']
	register_command := 'register read --format hex ' + registers.join(' ')
	if registers.len > 0 {
		args << ['-k', register_command]
	}
	if stack {
		args << ['-k', 'thread backtrace all']
	}
	args << ['--', program]
	args << scenario.argv
	result := capture(Command{
		executable: path
		args:       args
		env:        scenario.environment()
		cwd:        scenario.cwd
		timeout_ms: scenario.timeout_ms
	})!
	primary, backtrace := if stack {
		debugger_stack(result.stdout, '(lldb) thread backtrace all\n', 'lldb')
	} else {
		result.stdout, ?DebuggerStack(none)
	}
	stop := parse_lldb(primary + '\n' + result.stderr, artifact)
	return result, NativeStop{
		...stop
		stack_trace:       backtrace
		register_snapshot: debugger_register_snapshot(primary, '(lldb) ${register_command}\n',
			'', 'lldb', registers)
	}
}

fn debugger_stack(stdout string, marker string, debugger string) (string, ?DebuggerStack) {
	offset := stdout.index(marker) or { return stdout, none }
	frames := stdout[offset + marker.len..].trim_space()
	if frames == '' {
		return stdout[..offset], none
	}
	return stdout[..offset], DebuggerStack{
		debugger: debugger
		text:     frames
		threads:  parse_debugger_threads(frames)
	}
}

fn parse_lldb(output string, artifact string) NativeStop {
	mut reason := ''
	mut pcs := []u64{}
	mut frames := []u64{}
	mut stop_pc := ?u64(none)
	mut load_base := ?u64(none)
	mut exit_code := ?int(none)
	for line in output.split_into_lines() {
		words := line.fields()
		if line.contains('stop reason = ') {
			value := line.all_after('stop reason = ').trim_space()
			if value.starts_with('EXC_') || value.starts_with('signal ')
				|| value.to_lower().starts_with('exception') {
				reason = value
			}
		}
		if line.contains('exited with status = ') {
			value := line.all_after('exited with status = ').fields()
			if value.len > 0 {
				exit_code = strconv.atoi(value[0]) or { continue }
			}
		}
		if words.len >= 3 && words[0] in ['pc', 'rip'] && words[1] == '=' {
			pc := parse_address(words[2]) or { continue }
			stop_pc = pc
			pcs << pc
		}
		if words.len >= 3 && words[0] == 'frame' && words[1].ends_with(':') {
			if words[1] != '#0:' {
				frames << (parse_address(words[2]) or { continue })
			}
		}
		if line.trim_space().starts_with('[') && debugger_image_path(line, artifact) {
			address := words.filter(it.starts_with('0x'))
			if address.len > 0 {
				load_base = parse_address(address[0]) or { continue }
			}
		}
	}
	pcs << frames
	return NativeStop{
		reason:    reason
		pcs:       pcs
		stop_pc:   stop_pc
		load_base: load_base
		exit_code: exit_code
	}
}

fn shell_argument(value string) !string {
	if value.contains_any('\x00\r\n') {
		return error('GDB command arguments cannot contain NUL or line breaks')
	}
	return "'" + value.replace("'", "'\\''") + "'"
}

fn run_gdb(program string, artifact string, scenario ExecutionCase, input string, stdout string, stderr string, stack bool, registers []string, stop_at ?u64, stop_anchor u64, recovery []string) !(Outcome, NativeStop) {
	path := executable('gdb')!
	mut run_command := 'run'
	for arg in scenario.argv {
		run_command += ' ' + shell_argument(arg)!
	}
	run_command += ' < ' + shell_argument(input)! + ' > ' + shell_argument(stdout)! + ' 2> ' +
		shell_argument(stderr)!
	mut args := ['--nx', '--batch', '-iex', 'set auto-load off', '-iex', 'set debuginfod enabled off',
		'-ex', 'set disable-randomization off']
	if address := stop_at {
		pc := hex_address(address)
		check := [
			'try:',
			'    architecture = gdb.selected_inferior().architecture()',
			'    instructions = architecture.disassemble(${hex_address(stop_anchor)}, ${pc})',
			'except gdb.error:',
			'    instructions = []',
			'if not any(i["addr"] == ${pc} for i in instructions):',
			'    gdb.write("VGUARD_INVALID_STOP\\n")',
			'    gdb.execute("quit 2")',
		].join('\n')
		args << ['-ex', 'python exec(${json2.encode(check)})', '-ex', 'break *${pc}']
	}
	args << ['-ex', run_command, '-ex', 'printf "VGUARD_PC %p\\n", $pc', '-ex', 'info proc mappings',
		'-ex', 'bt']
	if registers.len > 0 {
		args << ['-ex', 'echo \\nVGUARD_REGISTERS_BEGIN\\n', '-ex',
			'info registers ' + registers.join(' '), '-ex', 'echo \\nVGUARD_REGISTERS_END\\n']
	}
	args << recovery
	if stack {
		args << ['-ex', 'set print frame-arguments all', '-ex', 'echo \\nVGUARD_STACK_BEGIN\\n',
			'-ex', 'thread apply all backtrace']
	}
	args << ['--args', program]
	result := capture(Command{
		executable: path
		args:       args
		env:        scenario.environment()
		cwd:        scenario.cwd
		timeout_ms: scenario.timeout_ms
	})!
	if stop_at != none && result.stdout.split_into_lines().contains('VGUARD_INVALID_STOP') {
		return error('--at must identify a machine instruction boundary')
	}
	primary, backtrace := if stack {
		debugger_stack(result.stdout, '\nVGUARD_STACK_BEGIN\n', 'gdb')
	} else {
		result.stdout, ?DebuggerStack(none)
	}
	stop := parse_gdb(primary + '\n' + result.stderr, artifact)
	return result, NativeStop{
		...stop
		stack_trace:       backtrace
		breakpoint:        stop_at != none && primary.split_into_lines().any(it.starts_with('Breakpoint 1,') || it.contains('hit Breakpoint 1,'))
		register_snapshot: debugger_register_snapshot(primary, '\nVGUARD_REGISTERS_BEGIN\n',
			'\nVGUARD_REGISTERS_END\n', 'gdb', registers)
	}
}

fn parse_gdb(output string, artifact string) NativeStop {
	mut reason := ''
	mut pcs := []u64{}
	mut stop_pc := ?u64(none)
	mut load_base := ?u64(none)
	mut exit_code := ?int(none)
	mut runtime_thread := DebuggerRuntimeThread{}
	for line in output.split_into_lines() {
		words := line.fields()
		if line.starts_with('[Inferior ') {
			if line.contains('exited normally') {
				exit_code = 0
			} else if line.contains('exited with code ') {
				code := line.all_after('exited with code ').trim_right(']')
				exit_code = int(strconv.parse_uint(code, 8, 32) or { continue })
			}
		}
		if line.contains('received signal ') {
			reason = line.all_after('received signal ').trim_space()
		}
		if words.len in [3, 4] && words[0] == 'VGUARD_RUNTIME_THREAD' {
			process := strconv.parse_uint(words[1], 10, 32) or { continue }
			lwp := strconv.parse_uint(words[2], 10, 32) or { continue }
			thread_number := if words.len == 4 { strconv.atoi(words[3]) or { continue } } else { 0 }
			runtime_thread = DebuggerRuntimeThread{ process: process, lwp: lwp, number: thread_number }
		}
		if words.len == 4 && words[0] == 'VGUARD_RUNTIME_FRAME' && runtime_thread.lwp > 0 {
			index := strconv.atoi(words[1]) or { continue }
			pc := parse_address(words[2]) or { continue }
			frame := parse_address(words[3]) or { continue }
			if index >= 0 && index < 128 && frame > 0 {
				runtime_thread.frames << DebuggerRuntimeFrame{ index: index, pc: pc, fp: frame }
			}
		}
		if words.len >= 2 && (words[0] == 'VGUARD_PC' || (words[0].starts_with('#')
			&& words[0] != '#0' && words[1].starts_with('0x'))) {
			pc := parse_address(words[1]) or { continue }
			if words[0] == 'VGUARD_PC' {
				stop_pc = pc
			}
			pcs << pc
		}
		if words.len >= 5 && words[0].starts_with('0x') && debugger_image_path(line, artifact) && parse_address(words[3]) or {
			1
		} == 0 {
			candidate := parse_address(words[0]) or { continue }
			if previous := load_base {
				if previous < candidate {
					continue
				}
			}
			load_base = candidate
		}
	}
	return NativeStop{
		reason:         reason
		pcs:            pcs
		stop_pc:        stop_pc
		load_base:      load_base
		exit_code:      exit_code
		runtime_thread: runtime_thread
	}
}

fn (bundle &Bundle) run_wasm(scenario ExecutionCase, options RunOptions) !Outcome {
	path := executable('wasmtime')!
	mut args := ['run', '-C', 'cache=n']
	if options.fuel > 0 {
		args << ['-W', 'fuel=${options.fuel}']
	}
	for key, val in scenario.env {
		args << ['--env', '${key}=${val}']
	}
	args << '--'
	args << bundle.artifact
	args << scenario.argv
	return ExecutionCase{
		...scenario
		argv: args
	}.run_binary(path)
}

fn wasm_cause_line(line string) string {
	text := line.trim_space()
	prefix := text.all_before(': ')
	return if prefix.len > 0 && prefix.bytes().all(it >= `0` && it <= `9`) {
		text.all_after(': ')
	} else {
		text
	}
}

fn with_wasm_limit(report Diagnosis, fuel u64, timeout_ms int) Diagnosis {
	if fuel == 0 {
		return report
	}
	if report.kind == 'timeout' {
		return Diagnosis{
			...report
			execution_limit: ExecutionLimit{
				kind:     'wall_time_ms'
				limit:    u64(timeout_ms)
				evidence: 'vguard_process_timeout'
			}
		}
	}
	if report.kind != 'crash' {
		return report
	}
	// Wasmtime adds the trap cause as the last nonblank stderr line. Keep
	// earlier guest output and unrelated traps out of the fuel classification.
	lines := report.outcome.stderr.trim_space().split_into_lines()
	if lines.len == 0 {
		return report
	}
	if wasm_cause_line(lines.last()) != 'wasm trap: all fuel consumed by WebAssembly' {
		return report
	}
	return Diagnosis{
		...report
		kind:            'fuel_exhausted'
		reason:          'Wasmtime reported exhaustion of the WebAssembly fuel budget'
		execution_limit: ExecutionLimit{
			kind:     'wasm_fuel'
			limit:    fuel
			evidence: 'wasmtime_cli_trap'
		}
	}
}

fn (bundle &Bundle) with_wasm_function_body(report Diagnosis) Diagnosis {
	if report.kind != 'fuel_exhausted' || report.location != none || report.address == '' {
		return report
	}
	address := parse_address(report.address) or { return report }
	location := bundle.wasm_body_location(address) or { return report }
	return Diagnosis{ ...report, location: location }
}

fn (bundle &Bundle) wasm_body_location(address u64) ?Location {
	for section in bundle.image.wasm_bodies {
		if address < section.address || address - section.address >= section.size {
			continue
		}
		mut function := ''
		mut file := ''
		mut multiple_files := false
		for range in bundle.ranges {
			if range.section != section.index || range.location.function == '' {
				continue
			}
			if function != '' && function != range.location.function {
				return none
			}
			function = range.location.function
			if range.location.file != '' {
				multiple_files = multiple_files || (file != '' && file != range.location.file)
				file = range.location.file
			}
		}
		if function != '' {
			return Location{
				function:  function
				file:      if multiple_files { '' } else { file }
				precision: 'function_body'
			}
		}
		break
	}
	return none
}

fn (bundle &Bundle) wasm_diagnosis(outcome Outcome) Diagnosis {
	trace := outcome.stderr.index('wasm backtrace:') or { return ordinary_diagnosis(outcome) }
	if outcome.status != 'exited' || outcome.exit_code == 0 {
		return ordinary_diagnosis(outcome)
	}
	mut reason := 'WebAssembly trap'
	if outcome.stderr.contains('wasm trap: ') {
		reason += ': ' + outcome.stderr.all_after('wasm trap: ').all_before('\n').trim_space()
	}
	mut trap_address := ''
	mut location_error := 'Wasmtime did not report an instruction offset'
	for line in outcome.stderr[trace..].split_into_lines() {
		words := line.fields()
		if words.len < 3 || !words[0].ends_with(':') || !words[1].starts_with('0x')
			|| words[2] != '-' {
			continue
		}
		offset := strconv.parse_uint(words[1][2..], 16, 64) or { continue }
		if trap_address == '' {
			trap_address = words[1]
		}
		location := bundle.resolve_address(offset) or {
			if words[1] == trap_address {
				location_error = err.msg()
			}
			continue
		}
		if bundle.manifest.options.wasm_heap && wasm_heap_trap(location) != '' {
			continue
		}
		return Diagnosis{
			kind:     'crash'
			reason:   reason
			address:  trap_address
			location: Location{
				...location
				precision: if words[1] == trap_address {
					location.precision
				} else {
					'caller_frame'
				}
			}
			outcome:  outcome
		}
	}
	return Diagnosis{
		kind:           'crash'
		reason:         reason
		address:        trap_address
		location_error: location_error
		outcome:        outcome
	}
}

fn debugger_image_path(line string, artifact string) bool {
	$if windows {
		return line.trim_space().replace('\\', '/').to_lower().ends_with(' ' +
			artifact.replace('\\', '/').to_lower())
	} $else {
		return line.trim_space().ends_with(' ' + artifact)
	}
}
