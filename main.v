module main

import json2
import os
import strconv
import strings

const invalid_command = 'expected a command and input path. See vguard --help'

const usage = 'VGuard traces V binary failures to their source.

  vguard build <file-or-directory> --v <compiler> --backend <backend> --target <os/arch>
               --out <new-directory> [--prod] [--trace-build] [--trace-ssa] [--trace-runtime] [--trace-hangs] [--memory]
               [--wasm-heap] [--object | --hot-fn <symbol>] [--ssa-function <LLVM symbols>] [--v-arg <arg>]...
  vguard resolve <build.json> (--address <va> | --pc <pc> --load-base <base> |
                --offset <bytes> [--section <number>]) [--json] [--machine]
  vguard run <build.json> [--case <case.json>] [--json | --ssa] [--dataflow] [--machine]
             [--stack] [--recover-ssa [--at <linked-address>]] [--fuel <units> | --hangs | --runtime-ssa]
  vguard compare <build.json> [--reference <build.json> [--ssa-diff]] [--case <case.json>] [--json]
  vguard verify-ssa <build.json> [--json]
  vguard verify-ssa <passes.jsonl | program.llvm-ssa.json> --partial [--json]
  vguard regress <series.json> [--compiler-series] [--case <case.json>] [--include-exits] [--json]
  vguard minimize <build.json> --reference <build.json> --out <new-directory>
                  [--case <case.json>] [--attempts <count>] [--include-exits]
  vguard minimize <build.json> --panic --out <new-directory> [--case <case.json>] [--attempts <count>]
  vguard minimize <build.json> --arithmetic-trap --out <new-directory> [--case <case.json>] [--attempts <count>]
  vguard record <build.json> [--case <case.json>] [[--calls] [--memory-accesses] | --runtime-ssa | --wasi-stdio] --out <new-directory>
  vguard record <build.json> --qemu-kernel <file> --out <new-directory> [--case <case.json>]
                [--qemu-rootfs <initramfs|ext4>] [--qemu-launcher <static ELF>] [--qemu-libraries <map.json>]
  vguard replay <history.json> [--at-event <number> | --reexecute] [--json]
'

struct Arguments {
	values   map[string]string
	switches map[string]bool
	v_args   []string
}

fn parse_options(command string, args []string) !Arguments {
	valued := match command {
		'build' {
			['--v', '--backend', '--target', '--out', '--hot-fn', '--v-arg', '--ssa-function']
		}
		'resolve' { ['--address', '--pc', '--load-base', '--offset', '--section'] }
		'compare' { ['--case', '--reference'] }
		'minimize' { ['--case', '--reference', '--out', '--attempts'] }
		'run' { ['--case', '--fuel', '--at'] }
		'record' {
			['--case', '--out', '--qemu-kernel', '--qemu-rootfs', '--qemu-launcher', '--qemu-libraries']
		}
		'replay' { ['--at-event'] }
		'verify-ssa' { []string{} }
		else { ['--case'] }
	}
	boolean := match command {
		'build' {
			['--prod', '--object', '--memory', '--trace-build', '--trace-ssa', '--trace-hangs',
				'--trace-runtime', '--wasm-heap']
		}
		'resolve' { ['--json', '--machine'] }
		'run' {
			['--json', '--ssa', '--dataflow', '--machine', '--stack', '--hangs', '--runtime-ssa',
				'--recover-ssa']
		}
		'compare' { ['--json', '--ssa-diff'] }
		'verify-ssa' { ['--json', '--partial'] }
		'record' { ['--calls', '--memory-accesses', '--runtime-ssa', '--wasi-stdio'] }
		'replay' { ['--json', '--reexecute'] }
		'minimize' { ['--include-exits', '--panic', '--arithmetic-trap'] }
		'regress' { ['--include-exits', '--json', '--compiler-series'] }
		else { ['--json'] }
	}
	mut values := map[string]string{}
	mut switches := map[string]bool{}
	mut v_args := []string{}
	mut index := 0
	for index < args.len {
		option := args[index]
		if option in boolean && option !in switches {
			switches[option] = true
			index++
			continue
		}
		if option !in valued || option in values || index + 1 >= args.len {
			return error('invalid or repeated option: ${option}')
		}
		val := args[index + 1]
		if option == '--v-arg' {
			if val in ['-b', '-os', '-arch', '-o', '-output', '-prod', '-vguard-map', '-vguard-trace',
				'-vguard-ssa-analysis', '-vguard-trace-calls', '-vguard-native-memory',
				'-vguard-trace-hangs', '-vguard-runtime-ssa', '-vguard-wasm-heap', '-is_o', '-hot-fn',
				'run', 'test', 'self'] {
				return error('use the VGuard build options instead of --v-arg ${val}')
			}
			v_args << val
		} else {
			values[option] = val
		}
		index += 2
	}
	if switches['--json'] && switches['--ssa'] {
		return error('--json and --ssa are mutually exclusive')
	}
	if (switches['--dataflow'] || switches['--stack']) && switches['--ssa'] {
		return error('--dataflow and --stack are available with the terminal and JSON reports')
	}
	if switches['--machine'] && switches['--ssa'] {
		return error('--machine is available with the terminal and JSON reports')
	}
	if switches['--hangs'] && (switches['--stack'] || switches['--machine'] || switches['--ssa']
		|| switches['--dataflow'] || switches['--runtime-ssa'] || '--fuel' in values) {
		return error('--hangs uses instrumented execution and cannot be combined with debugger, SSA, or fuel options')
	}
	if switches['--runtime-ssa'] && (switches['--ssa'] || '--fuel' in values) {
		return error('--runtime-ssa requires native terminal or JSON output')
	}
	if command == 'record' && switches['--runtime-ssa'] && (switches['--calls'] || switches['--memory-accesses']) {
		return error('record --runtime-ssa uses native SSA instrumentation')
	}
	if switches['--wasi-stdio'] && (switches['--calls'] || switches['--memory-accesses']
		|| switches['--runtime-ssa']) {
		return error('--wasi-stdio records the Wasm program inputs and output streams')
	}
	if '--qemu-kernel' in values {
		if switches['--calls'] || switches['--memory-accesses'] || switches['--runtime-ssa']
			|| switches['--wasi-stdio'] {
			return error('QEMU recording uses the original executable and its existing instrumentation')
		}
	} else if '--qemu-rootfs' in values || '--qemu-launcher' in values || '--qemu-libraries' in values {
		return error('QEMU options require --qemu-kernel')
	}
	if switches['--reexecute'] && '--at-event' in values {
		return error('--reexecute and --at-event are mutually exclusive')
	}
	if switches['--recover-ssa'] && (switches['--ssa'] || switches['--hangs'] || '--fuel' in values) {
		return error('--recover-ssa requires a debugger with terminal or JSON output')
	}
	if '--at' in values && !switches['--recover-ssa'] {
		return error('--at requires --recover-ssa')
	}
	if switches['--ssa-diff'] && '--reference' !in values {
		return error('--ssa-diff requires --reference')
	}
	if switches['--panic'] && ('--reference' in values || switches['--include-exits']) {
		return error('--panic compares a V panic against its original run')
	}
	if switches['--arithmetic-trap'] && (switches['--panic'] || '--reference' in values
		|| switches['--include-exits']) {
		return error('--arithmetic-trap compares a Wasm arithmetic trap against its original run')
	}
	return Arguments{
		values:   values
		switches: switches
		v_args:   v_args
	}
}

fn (options Arguments) require(name string) !string {
	value := options.values[name]
	if value == '' {
		return error('missing ${name}')
	}
	return value
}

@[params]
struct CaseLoadOptions {
	guest bool
}

fn load_case(path string, options CaseLoadOptions) !ExecutionCase {
	if path == '' {
		return ExecutionCase{ cwd: if options.guest { '' } else { os.getwd() } }
	}
	scenario := json2.decode[ExecutionCase](os.read_file(path)!)!
	if scenario.timeout_ms <= 0 {
		return error('timeout_ms must be positive')
	}
	for key, value in scenario.env {
		if key == '' || key.contains_any('=\x00') || value.contains('\x00') {
			return error('invalid environment variable: ${key}')
		}
	}
	if scenario.argv.any(it.contains('\x00')) {
		return error('arguments cannot contain NUL')
	}
	if options.guest {
		return scenario
	}
	dir := os.dir(os.abs_path(path))
	cwd := if scenario.cwd == '' || os.is_abs_path(scenario.cwd) {
		scenario.cwd
	} else {
		os.join_path(dir, scenario.cwd)
	}
	if cwd != '' && !os.is_dir(cwd) {
		return error('working directory does not exist: ${cwd}')
	}
	harness := if scenario.harness == '' || os.is_abs_path(scenario.harness) {
		scenario.harness
	} else {
		os.join_path(dir, scenario.harness)
	}
	return ExecutionCase{
		...scenario
		cwd:     if cwd == '' { dir } else { cwd }
		harness: harness
	}
}

fn location_text(location Location) string {
	mut text := location.function
	if location.file != '' {
		text += ' at ${location.file}:${location.line}'
		if location.column > 0 {
			text += ':${location.column}'
		}
	}
	if location.ssa_value >= 0 {
		text += ' (SSA %${location.ssa_value} ${location.ssa_opcode})'
	}
	return text + ' [${location.precision}]'
}

fn resolve_cli(bundle Bundle, opts Arguments) !Location {
	if opts.values.len == 1 && '--address' in opts.values {
		return bundle.resolve_address(parse_address(opts.require('--address')!)!)
	}
	if opts.values.len == 2 && '--pc' in opts.values && '--load-base' in opts.values {
		pc := parse_address(opts.require('--pc')!)!
		base := parse_address(opts.require('--load-base')!)!
		return bundle.resolve_address(bundle.address_from_load_base(pc, base)!)
	}
	if '--offset' in opts.values {
		offset := parse_address(opts.require('--offset')!)!
		if opts.values.len == 1 && bundle.image.format in ['raw-arm64', 'wasm'] {
			return bundle.resolve_address(offset)
		}
		if opts.values.len == 2 && '--section' in opts.values {
			section := parse_address(opts.require('--section')!)!
			if section > 0x7fff_ffff {
				return error('invalid section index')
			}
			return bundle.resolve_section(int(section), offset)
		}
	}
	return error('specify --address, --pc with --load-base, or --offset with the section index')
}

fn cli(argv []string) !int {
	if argv.len == 0 || argv[0] in ['-h', '--help', 'help'] {
		print(usage)
		return 0
	}
	if argv.len < 2 || argv[0] !in ['build', 'resolve', 'run', 'compare', 'record', 'replay', 'regress',
		'minimize', 'verify-ssa'] {
		return error(invalid_command)
	}
	command := argv[0]
	opts := parse_options(command, argv[2..])!
	if command == 'replay' {
		history := open_history(argv[1])!
		if opts.switches['--reexecute'] {
			is_vm := history.qemu_linux != none
			report := if is_vm {
				replay_qemu_linux(argv[1], history)!
			} else {
				replay_wasi_stdio(argv[1], history)!
			}
			if opts.switches['--json'] {
				println(json2.encode(report))
			} else {
				label := if is_vm { 'Linux VM' } else { 'WASI stdio' }
				println('${label} re-execution ${report.kind}')
				if report.detail != '' {
					println(report.detail)
				}
			}
			return match report.kind {
				'matched' { 0 }
				'different' { 1 }
				else { 2 }
			}
		}
		if '--at-event' in opts.values {
			index := strconv.atoi(opts.require('--at-event')!) or { return error('--at-event expects a positive event number') }
			state := replay_native_history(argv[1], history, index)!
			if opts.switches['--json'] {
				println(json2.encode(state))
			} else {
				mut out := strings.new_builder(1024)
				out.writeln('Recorded state at event ${state.event}')
				write_runtime_ssa(mut out, Diagnosis{ runtime_ssa: state.ssa })
				print(out.str())
			}
		} else if opts.switches['--json'] {
			println(json2.encode(history))
		} else {
			print(format_history(history))
		}
		return 0
	}
	if command == 'regress' {
		scenario := load_case(opts.values['--case'])!
		mode := ExitComparisonOptions{ include_exits: opts.switches['--include-exits'] }
		report := if opts.switches['--compiler-series'] {
			find_compiler_regression(load_compiler_regression(argv[1])!, scenario, mode)!
		} else {
			find_regression(load_regression_series(argv[1])!, scenario, mode)!
		}
		if opts.switches['--json'] {
			println(json2.encode(report))
		} else {
			print(format_regression(report))
		}
		return match report.kind {
			'unchanged' { 0 }
			'changed' { 1 }
			else { 2 }
		}
	}
	if command == 'build' {
		options := BuildOptions{
			source:        os.real_path(argv[1])
			compiler:      executable(opts.require('--v')!)!
			backend:       opts.require('--backend')!
			target:        opts.require('--target')!
			args:          opts.v_args
			prod:          opts.switches['--prod']
			memory:        opts.switches['--memory'] || opts.switches['--wasm-heap']
			wasm_heap:     opts.switches['--wasm-heap']
			trace_hangs:   opts.switches['--trace-hangs']
			trace_runtime: opts.switches['--trace-runtime']
			object:        opts.switches['--object']
			hot_fn:        opts.values['--hot-fn']
		}
		if options.hot_fn != '' && (options.object || options.backend != 'arm64') {
			return error('--hot-fn requires the arm64 backend and a raw output artifact')
		}
		println(build(options, os.abs_path(opts.require('--out')!), false,
			trace_build:  opts.switches['--trace-build']
			trace_ssa:    opts.switches['--trace-ssa']
			ssa_function: opts.values['--ssa-function']
		)!)
		return 0
	}
	as_json := opts.switches['--json']
	if command == 'verify-ssa' {
		if opts.switches['--partial'] && os.file_name(argv[1]) == llvm_trace_name {
			report := read_llvm_verification(argv[1], '')!
			if as_json {
				println(json2.encode(report))
			} else {
				print(format_llvm_verification(report))
			}
			return 0
		}
		report := if opts.switches['--partial'] {
			read_partial_ssa_verification(argv[1])!
		} else {
			checked := open_bundle(argv[1])!
			if checked.manifest.llvm_ssa_sha256 != '' {
				llvm := checked.llvm_verification()!
				if as_json {
					println(json2.encode(llvm))
				} else {
					print(format_llvm_verification(llvm))
				}
				return if llvm.partial { 2 } else { 0 }
			}
			checked.read_verified_ssa_trace()!.verification_report()
		}
		if as_json {
			println(json2.encode(report))
		} else {
			print(format_ssa_verification(report))
		}
		return if report.critical_findings > 0 { 1 } else { 0 }
	}
	bundle := open_bundle(argv[1])!
	if command == 'resolve' {
		mut location := resolve_cli(bundle, opts)!
		if opts.switches['--machine'] {
			location = bundle.with_machine_mapping(location)!
		}
		if as_json {
			println(json2.encode(location))
		} else {
			print(bundle.format_resolution(location))
		}
		return 0
	}
	scenario := load_case(opts.values['--case'],
		guest: command == 'record'
			&& '--qemu-kernel' in opts.values
	)!
	if command == 'minimize' {
		attempts := if '--attempts' in opts.values {
			strconv.atoi(opts.require('--attempts')!) or { return error('--attempts expects a positive integer') }
		} else {
			32
		}
		out := os.abs_path(opts.require('--out')!)
		if opts.switches['--panic'] {
			println(minimize_v_panic(bundle, scenario, out, attempts)!)
			return 0
		}
		if opts.switches['--arithmetic-trap'] {
			println(minimize_wasm_arithmetic(bundle, scenario, out, attempts)!)
			return 0
		}
		reference := open_bundle(opts.require('--reference')!)!
		println(minimize_output_difference(bundle, reference, scenario, out, attempts,
			include_exits: opts.switches['--include-exits']
		)!)
		return 0
	}
	if command == 'record' {
		out := os.abs_path(opts.require('--out')!)
		if '--qemu-kernel' in opts.values {
			println(record_qemu_linux(bundle, scenario, out, VmGuestOptions{
				kernel:    opts.require('--qemu-kernel')!
				rootfs:    opts.values['--qemu-rootfs']
				launcher:  opts.values['--qemu-launcher']
				libraries: opts.values['--qemu-libraries']
			})!)
			return 0
		}
		if opts.switches['--wasi-stdio'] {
			println(record_wasi_stdio(bundle, scenario, out)!)
			return 0
		}
		if opts.switches['--runtime-ssa'] {
			println(record_native_history(bundle, scenario, out)!)
			return 0
		}
		println(record_history(bundle, scenario, out,
			calls:           opts.switches['--calls']
			memory_accesses: opts.switches['--memory-accesses']
		)!)
		return 0
	}
	if command == 'run' {
		fuel := if '--fuel' in opts.values {
			parse_fuel(opts.require('--fuel')!)!
		} else {
			u64(0)
		}
		mut report := bundle.run(scenario,
			stack:       opts.switches['--stack']
			fuel:        fuel
			machine:     opts.switches['--machine']
			hangs:       opts.switches['--hangs']
			runtime_ssa: opts.switches['--runtime-ssa']
			recover_ssa: opts.switches['--recover-ssa']
			stop_at:     if '--at' in opts.values {
				?u64(parse_address(opts.require('--at')!)!)
			} else {
				none
			}
		)!
		if opts.switches['--dataflow'] {
			report = bundle.with_dataflow(report)
		}
		if opts.switches['--machine'] {
			report = bundle.with_machine_diagnosis(report)
		}
		if as_json {
			println(json2.encode(report))
		} else if opts.switches['--ssa'] {
			eprint(report.outcome.stdout)
			eprint(report.outcome.stderr)
			print(bundle.format_ssa_diagnosis(report))
		} else {
			print(report.outcome.stdout)
			if report.outcome.stdout != '' && !report.outcome.stdout.ends_with('\n') {
				println('')
			}
			eprint(report.outcome.stderr)
			print(bundle.format_diagnosis(report))
		}
		return match report.kind {
			'stopped' { 0 }
			'crash', 'memory_error' { 1 }
			'exited' {
				if report.outcome.exit_code == 0 { 0 } else { 1 }
			}
			else { 2 }
		}
	}
	mut report := Comparison{}
	if '--reference' in opts.values {
		reference := open_bundle(opts.require('--reference')!)!
		report = compare_recorded(bundle, reference, scenario) or {
			if !opts.switches['--ssa-diff'] {
				return err
			}
			Comparison{
				kind:             'inconclusive'
				location_error:   err.msg()
				build_comparison: BuildComparison{
					target:    compared_build(bundle.manifest)
					reference: compared_build(reference.manifest)
				}
			}
		}
		if opts.switches['--ssa-diff'] {
			report = report.with_ssa_comparison(bundle, reference)
		}
	} else {
		report = compare(bundle, scenario)!
	}
	if as_json {
		println(json2.encode(report))
	} else {
		print(bundle.format_comparison(report))
	}
	return match report.kind {
		'equal' { 0 }
		'different' { 1 }
		else { 2 }
	}
}

fn parse_fuel(value string) !u64 {
	if value == '' || !value.bytes().all(it >= `0` && it <= `9`) {
		return error('--fuel expects a positive decimal integer')
	}
	fuel := strconv.parse_uint(value, 10, 64) or {
		return error('--fuel is outside the supported unsigned 64-bit range')
	}
	if fuel == 0 {
		return error('--fuel must be greater than zero')
	}
	return fuel
}

fn main() {
	args := os.args[1..]
	code := cli(args) or {
		if '--json' in args {
			println(json2.encode({
				'kind':   'error'
				'reason': err.msg()
			}))
		} else if args.len > 0 && args[0] == 'run' && '--ssa' in args {
			println('; error[vguard]: ${ssa_comment_text(err.msg())}')
		} else {
			eprintln('error[vguard]: ${err.msg()}')
		}
		exit(2)
	}
	exit(code)
}
