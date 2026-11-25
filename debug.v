module main

import os
import strconv

struct Diagnosis {
	kind               string
	reason             string
	address            string
	location           ?Location
	location_error     string
	ssa_file           string
	ssa_original_file  string @[omitempty]
	ssa_error          string
	ssa_excerpt        SsaExcerpt        @[skip]
	ssa_dataflow       ?SsaDataflow      @[omitempty]
	ssa_dataflow_error string            @[omitempty]
	stack_trace        ?DebuggerStack    @[omitempty]
	stack_error        string            @[omitempty]
	execution_limit    ?ExecutionLimit   @[omitempty]
	memory_errors      []MemoryViolation @[omitempty]
	outcome            Outcome
}

struct NativeStop {
	reason      string
	pcs         []u64
	load_base   ?u64
	exit_code   ?int
	stack_trace ?DebuggerStack
}

struct DebuggerStack {
	debugger string
	evidence string = 'debugger_at_stop'
	text     string
	threads  []DebuggerThread @[omitempty]
}

@[params]
struct RunOptions {
	stack bool
	fuel  u64
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
	if options.fuel > 0 && (bundle.image.format != 'wasm' || scenario.harness != '') {
		return error('--fuel requires a standalone WebAssembly build')
	}
	if bundle.image.relocatable || (!bundle.image.runnable && scenario.harness == '') {
		return error('use resolve for object or raw code, or specify a harness for a shared library')
	}
	if bundle.manifest.options.memory {
		report := bundle.run_memory(scenario)!
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
		bundle.with_wasm_function_body(limited)
	} else {
		bundle.run_debugger(scenario, options.stack)!
	}
	if options.stack && report.kind in ['crash', 'timeout', 'fuel_exhausted'] && report.stack_trace == none {
		return bundle.with_crash_ssa(Diagnosis{
			...report
			stack_error: 'no native all-thread backtrace was captured at the stop'
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

fn (bundle &Bundle) run_debugger(scenario ExecutionCase, stack bool) !Diagnosis {
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
	result, stop := if os.user_os() == 'linux' {
		run_gdb(program, bundle.artifact, debug_case, input, stdout, stderr, stack)!
	} else {
		run_lldb(program, bundle.artifact, debug_case, input, stdout, stderr, stack)!
	}
	outcome := Outcome{
		...result
		stdout:    read_output(stdout)!
		stderr:    read_output(stderr)!
		status:    if stop.reason != '' { 'signal' } else { result.status }
		exit_code: if stop.reason != '' { -1 } else { stop.exit_code or { result.exit_code } }
	}
	if result.status != 'exited' {
		return ordinary_diagnosis(outcome)
	}
	if stop.reason == '' {
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
	mut location_error := 'no frame belonging to the build artifact could be located'
	if base := stop.load_base {
		for i, pc in stop.pcs {
			// The caller PC points after the call; its preceding byte belongs to the call.
			frame_pc := if i > 0 && pc > base { pc - 1 } else { pc }
			address := bundle.address_from_load_base(frame_pc, base) or { continue }
			location := bundle.resolve_address(address) or {
				location_error = err.msg()
				continue
			}
			return Diagnosis{
				kind:        'crash'
				reason:      stop.reason
				address:     hex_address(stop.pcs[0])
				stack_trace: stop.stack_trace
				location:    Location{
					...location
					precision: if i == 0 { location.precision } else { 'caller_frame' }
				}
				outcome:     outcome
			}
		}
	} else {
		location_error = 'debugger did not report the artifact load address'
	}
	return Diagnosis{
		kind:           'crash'
		reason:         stop.reason
		address:        if stop.pcs.len > 0 { hex_address(stop.pcs[0]) } else { '' }
		location_error: location_error
		stack_trace:    stop.stack_trace
		outcome:        outcome
	}
}

fn run_lldb(program string, artifact string, scenario ExecutionCase, input string, stdout string, stderr string, stack bool) !(Outcome, NativeStop) {
	path := executable('lldb')!
	launch := 'process launch -i ' + debugger_arg(input)! + ' -o ' + debugger_arg(stdout)! +
		' -e ' + debugger_arg(stderr)!
	mut args := ['--no-lldbinit', '--batch', '-o', 'settings set target.disable-aslr false', '-o',
		launch, '-k', 'thread list', '-k', 'register read pc', '-k', 'image list -h -f', '-k',
		'bt']
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
	if !stack {
		return result, parse_lldb(result.stdout + '\n' + result.stderr, artifact)
	}
	primary, backtrace := debugger_stack(result.stdout, '(lldb) thread backtrace all\n', 'lldb')
	stop := parse_lldb(primary + '\n' + result.stderr, artifact)
	return result, NativeStop{ ...stop, stack_trace: backtrace }
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
			pcs << (parse_address(words[2]) or { continue })
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

fn run_gdb(program string, artifact string, scenario ExecutionCase, input string, stdout string, stderr string, stack bool) !(Outcome, NativeStop) {
	path := executable('gdb')!
	mut run_command := 'run'
	for arg in scenario.argv {
		run_command += ' ' + shell_argument(arg)!
	}
	run_command += ' < ' + shell_argument(input)! + ' > ' + shell_argument(stdout)! + ' 2> ' +
		shell_argument(stderr)!
	mut args := ['--nx', '--batch', '-iex', 'set auto-load off', '-iex', 'set debuginfod enabled off',
		'-ex', 'set disable-randomization off', '-ex', run_command, '-ex',
		'printf "VGUARD_PC %p\\n", $pc', '-ex', 'info proc mappings', '-ex', 'bt']
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
	if !stack {
		return result, parse_gdb(result.stdout + '\n' + result.stderr, artifact)
	}
	primary, backtrace := debugger_stack(result.stdout, '\nVGUARD_STACK_BEGIN\n', 'gdb')
	stop := parse_gdb(primary + '\n' + result.stderr, artifact)
	return result, NativeStop{ ...stop, stack_trace: backtrace }
}

fn parse_gdb(output string, artifact string) NativeStop {
	mut reason := ''
	mut pcs := []u64{}
	mut load_base := ?u64(none)
	mut exit_code := ?int(none)
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
		if words.len >= 2 && (words[0] == 'VGUARD_PC' || (words[0].starts_with('#')
			&& words[0] != '#0' && words[1].starts_with('0x'))) {
			pcs << (parse_address(words[1]) or { continue })
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
		reason:    reason
		pcs:       pcs
		load_base: load_base
		exit_code: exit_code
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
	last := lines.last().trim_space()
	message := 'wasm trap: all fuel consumed by WebAssembly'
	prefix := last.all_before(': ')
	if last != message && !(prefix.len > 0 && prefix.bytes().all(it >= `0` && it <= `9`)
		&& last.all_after(': ') == message) {
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
				return report
			}
			function = range.location.function
			if range.location.file != '' {
				multiple_files = multiple_files || (file != '' && file != range.location.file)
				file = range.location.file
			}
		}
		if function != '' {
			return Diagnosis{
				...report
				location: Location{
					function:  function
					file:      if multiple_files { '' } else { file }
					precision: 'function_body'
				}
			}
		}
		break
	}
	return report
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
