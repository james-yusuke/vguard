module main

import os

const memory_exit_code = 86

fn validate_memory_target(options BuildOptions) ! {
	if options.backend != 'c' {
		return error('--memory requires the C backend (${options.backend} has no memory instrumentation)')
	}
	host := $if amd64 { os.user_os() + '/amd64' } $else $if arm64 { os.user_os() + '/arm64' } $else { '' }
	if options.target != host || host !in ['linux/amd64', 'linux/arm64', 'macos/arm64'] {
		return error('--memory requires a matching host target (Linux/amd64, Linux/arm64, or macOS/arm64)')
	}
	if options.object || options.hot_fn != '' || options.args.any(it in ['-shared', '--shared']) {
		return error('--memory requires a standalone executable')
	}
}

fn memory_compiler_args(options BuildOptions) ![]string {
	validate_memory_target(options)!
	if options.args.any(it in ['-cc', '-gc']) {
		return error('--memory selects Clang and -gc none. Remove the explicit -cc or -gc arguments.')
	}
	executable('clang')!
	sanitizers := '-fsanitize=address,null,array-bounds'
	return ['-cc', 'clang', '-gc', 'none', '-nocache', '-d', 'no_segfault_handler', '-cflags',
		sanitizers + ' -fno-sanitize-recover=null,array-bounds -fno-omit-frame-pointer -fno-optimize-sibling-calls',
		'-ldflags', sanitizers]
}

fn (bundle &Bundle) run_memory(scenario ExecutionCase) !Diagnosis {
	validate_memory_target(bundle.manifest.options)!
	if scenario.harness != '' {
		return error('--memory runs the instrumented executable directly. Omit the harness.')
	}
	work := temp_directory()!
	defer {
		os.rmdir_all(work) or {}
	}
	log_path := os.join_path(work, 'sanitizer')
	if log_path.contains_any("'\r\n") {
		return error('The sanitizer log path contains a quote or line break. Use a different temporary directory.')
	}
	mut env := scenario.env.clone()
	log_options := "symbolize=0:exitcode=${memory_exit_code}:log_path='${log_path}'"
	env['ASAN_OPTIONS'] = 'detect_leaks=0:halt_on_error=1:abort_on_error=0:' + log_options
	env['UBSAN_OPTIONS'] = 'print_stacktrace=1:halt_on_error=1:' + log_options
	outcome := ExecutionCase{ ...scenario, env: env }.run_binary(bundle.artifact)!
	mut names := os.ls(work)!
	names.sort()
	mut events := []SanitizerEvent{}
	mut log_size := u64(0)
	for name in names {
		if !name.starts_with('sanitizer.') {
			continue
		}
		path := os.join_path(work, name)
		log_size += os.file_size(path)
		if log_size > u64(capture_limit) {
			return Diagnosis{
				kind:    'inconclusive'
				reason:  'sanitizer reports exceeded the output capture limit'
				outcome: outcome
			}
		}
		events << parse_sanitizer_log(os.read_file(path)!)
	}
	return bundle.diagnose_memory(outcome, events)
}

fn (bundle &Bundle) diagnose_memory(outcome Outcome, events []SanitizerEvent) Diagnosis {
	mut findings := []MemoryViolation{}
	for event in events {
		if event.finding.kind == '' {
			continue
		}
		mut finding := event.finding
		if finding.location == none {
			finding.location = bundle.sanitizer_location(event.stack)
		}
		finding.allocation = bundle.sanitizer_location(event.alloc_stack)
		finding.deallocation = bundle.sanitizer_location(event.free_stack)
		findings << finding
	}
	if findings.len > 0 {
		first := findings[0]
		return Diagnosis{
			kind:           'memory_error'
			reason:         first.kind
			address:        first.address
			location:       first.location
			location_error: if first.location == none {
				'no V source line in the sanitizer report or debug information'
			} else {
				''
			}
			memory_errors:  findings
			outcome:        outcome
		}
	}
	for event in events {
		if event.crash {
			return Diagnosis{
				kind:     'crash'
				reason:   event.finding.message
				address:  sanitizer_address(event.finding.message.all_after(' at pc '))
				location: bundle.sanitizer_location(event.stack)
				outcome:  outcome
			}
		}
	}
	if events.len > 0 {
		return Diagnosis{
			kind:    'inconclusive'
			reason:  'unclassified sanitizer report (${events[0].finding.message})'
			outcome: outcome
		}
	}
	return ordinary_diagnosis(outcome)
}

fn (bundle &Bundle) sanitizer_location(frames []string) ?Location {
	for frame in frames {
		address := bundle.sanitizer_frame_address(frame) or { continue }
		if location := bundle.debug_location(address) {
			return location
		}
		if location := bundle.system_debug_location(address) {
			return location
		}
	}
	return none
}

fn (bundle &Bundle) sanitizer_frame_address(frame string) ?u64 {
	end := frame.last_index('+0x') or { return none }
	begin := frame[..end].index('(') or { return none }
	mut module_path := frame[begin + 1..end]
	if bundle.image.format == 'macho' {
		module_path = module_path.trim_string_right(':arm64')
	}
	if module_path != bundle.artifact && os.real_path(module_path) != bundle.artifact {
		return none
	}
	value := parse_address(frame[end + 1..].all_before(')')) or { return none }
	// Offline sanitizer frames already remove ASLR. Some Darwin versions
	// print an offset from __TEXT, while others print the unslid VA.
	if bundle.image.sections.any(value >= it.address && value - it.address < it.size) {
		return value
	}
	address := bundle.address_from_load_base(value, 0) or { return none }
	if bundle.image.sections.any(address >= it.address && address - it.address < it.size) {
		return address
	}
	return none
}

fn (bundle &Bundle) system_debug_location(address u64) ?Location {
	if bundle.image.format == 'macho' {
		path := executable('atos') or { return none }
		dwarf := bundle.macho_debug_object() or { return none }
		object := if dwarf == bundle.artifact { dwarf } else { bundle.artifact + '.dSYM' }
		result := capture(Command{
			executable: path
			args:       ['--fullPath', '--inlineFrames', '-o', object, '-l',
				hex_address(bundle.image.preferred_base), hex_address(address)]
		}) or { return none }
		if result.status == 'exited' && result.exit_code == 0 {
			for line in result.stdout.split_into_lines() {
				separator := line.index(' (in ') or { continue }
				position := line.index_after(') (', separator) or { continue }
				if loc := source_coordinate(line[position + 3..].trim_string_right(')')) {
					return Location{ ...loc, function: line[..separator] }
				}
			}
		}
		return none
	}
	if bundle.image.format == 'elf' {
		path := executable('addr2line') or { return none }
		result := capture(Command{
			executable: path
			args:       ['-f', '-i', '-e', bundle.artifact, hex_address(address)]
		}) or { return none }
		if result.status == 'exited' && result.exit_code == 0 {
			lines := result.stdout.split_into_lines()
			for i := 1; i < lines.len; i += 2 {
				if loc := source_coordinate(lines[i].all_before(' (discriminator ')) {
					return Location{ ...loc, function: lines[i - 1] }
				}
			}
		}
	}
	return none
}
