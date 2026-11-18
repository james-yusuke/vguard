module main

import json2
import os

const invalid_command = 'expected a command and input path. See vguard --help'

const usage = 'VGuard traces V binary failures to their source.

  vguard build <file-or-directory> --v <compiler> --backend <backend> --target <os/arch>
               --out <new-directory> [--prod] [--memory] [--object | --hot-fn <symbol>] [--v-arg <arg>]...
  vguard resolve <build.json> (--address <va> | --pc <pc> --load-base <base> |
                --offset <bytes> [--section <number>]) [--json]
  vguard run <build.json> [--case <case.json>] [--json]
  vguard compare <build.json> [--case <case.json>] [--json]
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
		else { ['--case'] }
	}
	boolean := if command == 'build' { ['--prod', '--object', '--memory'] } else { ['--json'] }
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
				'-is_o', '-hot-fn', 'run', 'test', 'self'] {
				return error('use the VGuard build options instead of --v-arg ${val}')
			}
			v_args << val
		} else {
			values[option] = val
		}
		index += 2
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
	if argv.len < 2 || argv[0] !in ['build', 'resolve', 'run', 'compare'] {
		return error(invalid_command)
	}
	command := argv[0]
	opts := parse_options(command, argv[2..])!
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
		println(build(options, os.abs_path(opts.require('--out')!), false)!)
		return 0
	}
	bundle := open_bundle(argv[1])!
	as_json := opts.switches['--json']
	if command == 'resolve' {
		location := resolve_cli(bundle, opts)!
		println(if as_json { json2.encode(location) } else { location_text(location) })
		return 0
	}
	scenario := load_case(opts.values['--case'])!
	if command == 'run' {
		report := bundle.run(scenario)!
		if as_json {
			println(json2.encode(report))
		} else {
			print(report.outcome.stdout)
			eprint(report.outcome.stderr)
			println('VGuard: ${report.kind} ${report.reason}'.trim_space())
			if report.memory_errors.len == 0 {
				if loc := report.location {
					println(location_text(loc))
				}
			}
			if report.location_error != '' {
				println(report.location_error)
			}
			if report.ssa_file != '' {
				println('SSA report: ${report.ssa_file}')
			}
			if report.ssa_error != '' {
				println('SSA report unavailable: ${report.ssa_error}')
			}
			for i, finding in report.memory_errors {
				print_memory_violation(finding, i > 0)
			}
		}
		return match report.kind {
			'crash', 'memory_error' { 1 }
			'exited' {
				if report.outcome.exit_code == 0 { 0 } else { 1 }
			}
			else { 2 }
		}
	}
	report := compare(bundle, scenario)!
	if as_json {
		println(json2.encode(report))
	} else {
		println('VGuard comparison: ${report.kind}')
		if report.target.stdout != report.reference.stdout {
			println('target stdout: ${json2.encode(report.target.stdout)}')
			println('reference stdout: ${json2.encode(report.reference.stdout)}')
		}
		if report.target.stderr != report.reference.stderr {
			println('target stderr: ${json2.encode(report.target.stderr)}')
			println('reference stderr: ${json2.encode(report.reference.stderr)}')
		}
		if report.target.exit_code != report.reference.exit_code || report.target.status != report.reference.status {
			println('target status: ${report.target.status} (${report.target.exit_code})')
			println('reference status: ${report.reference.status} (${report.reference.exit_code})')
		}
		if diff := report.divergence {
			if target := diff.target {
				println('target: ${target.file}:${target.line}:${target.column} ${target.kind} = ${target.value}')
			}
			if reference := diff.reference {
				println('reference: ${reference.file}:${reference.line}:${reference.column} ${reference.kind} = ${reference.value}')
			}
		}
		if report.location_error != '' {
			println(report.location_error)
		}
	}
	return match report.kind {
		'equal' { 0 }
		'different' { 1 }
		else { 2 }
	}
}

fn main() {
	args := os.args[1..]
	code := cli(args) or {
		if '--json' in args {
			println(json2.encode({
				'kind':   'error'
				'reason': err.msg()
			}))
		} else {
			eprintln('VGuard: ${err.msg()}')
		}
		exit(2)
	}
	exit(code)
}
