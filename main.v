module main

import json2
import os
import strconv

const invalid_command = 'expected a command and input path. See vguard --help'

const usage = 'VGuard traces V binary failures to their source.

  vguard build <file-or-directory> --v <compiler> --backend <backend> --target <os/arch>
               --out <new-directory> [--prod] [--trace-build] [--trace-ssa] [--memory]
               [--object | --hot-fn <symbol>] [--v-arg <arg>]...
  vguard resolve <build.json> (--address <va> | --pc <pc> --load-base <base> |
                --offset <bytes> [--section <number>]) [--json]
  vguard run <build.json> [--case <case.json>] [--json | --ssa] [--dataflow] [--stack] [--fuel <units>]
  vguard compare <build.json> [--reference <build.json>] [--case <case.json>] [--json]
  vguard regress <series.json> [--case <case.json>] [--json]
  vguard record <build.json> [--case <case.json>] --out <new-directory>
  vguard replay <history.json> [--json]
'

struct Arguments {
	values   map[string]string
	switches map[string]bool
	v_args   []string
}

fn parse_options(command string, args []string) !Arguments {
	valued := match command {
		'build' { ['--v', '--backend', '--target', '--out', '--hot-fn', '--v-arg'] }
		'resolve' { ['--address', '--pc', '--load-base', '--offset', '--section'] }
		'compare' { ['--case', '--reference'] }
		'run' { ['--case', '--fuel'] }
		'record' { ['--case', '--out'] }
		'replay' { []string{} }
		else { ['--case'] }
	}
	boolean := match command {
		'build' { ['--prod', '--object', '--memory', '--trace-build', '--trace-ssa'] }
		'run' { ['--json', '--ssa', '--dataflow', '--stack'] }
		'record' { []string{} }
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
				'-vguard-ssa-analysis', '-is_o', '-hot-fn', 'run', 'test', 'self'] {
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

fn load_case(path string) !ExecutionCase {
	if path == '' {
		return ExecutionCase{ cwd: os.getwd() }
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
	if argv.len < 2 || argv[0] !in ['build', 'resolve', 'run', 'compare', 'record', 'replay', 'regress'] {
		return error(invalid_command)
	}
	command := argv[0]
	opts := parse_options(command, argv[2..])!
	if command == 'replay' {
		history := open_history(argv[1])!
		if opts.switches['--json'] {
			println(json2.encode(history))
		} else {
			print(format_history(history))
		}
		return 0
	}
	if command == 'regress' {
		series := load_regression_series(argv[1])!
		report := find_regression(series, load_case(opts.values['--case'])!)!
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
			source:   os.real_path(argv[1])
			compiler: executable(opts.require('--v')!)!
			backend:  opts.require('--backend')!
			target:   opts.require('--target')!
			args:     opts.v_args
			prod:     opts.switches['--prod']
			memory:   opts.switches['--memory']
			object:   opts.switches['--object']
			hot_fn:   opts.values['--hot-fn']
		}
		if options.hot_fn != '' && (options.object || options.backend != 'arm64') {
			return error('--hot-fn requires the arm64 backend and a raw output artifact')
		}
		println(build(options, os.abs_path(opts.require('--out')!), false,
			trace_build: opts.switches['--trace-build']
			trace_ssa:   opts.switches['--trace-ssa']
		)!)
		return 0
	}
	bundle := open_bundle(argv[1])!
	as_json := opts.switches['--json']
	if command == 'resolve' {
		location := resolve_cli(bundle, opts)!
		if as_json {
			println(json2.encode(location))
		} else {
			print(bundle.format_resolution(location))
		}
		return 0
	}
	scenario := load_case(opts.values['--case'])!
	if command == 'record' {
		println(record_history(bundle, scenario, os.abs_path(opts.require('--out')!))!)
		return 0
	}
	if command == 'run' {
		fuel := if '--fuel' in opts.values {
			parse_fuel(opts.require('--fuel')!)!
		} else {
			u64(0)
		}
		mut report := bundle.run(scenario, stack: opts.switches['--stack'], fuel: fuel)!
		if opts.switches['--dataflow'] {
			report = bundle.with_dataflow(report)
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
		report = compare_recorded(bundle, reference, scenario)!
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
