module main

import os
import strings

const max_machine_range_bytes = u64(128)

struct NativeValueHome {
	function          string
	value             int
	register          string               @[omitempty]
	frame_offset      ?int                 @[omitempty]
	object_offset     ?int                 @[omitempty]
	object_alignment  ?int                 @[omitempty]
	object_size       ?int                 @[omitempty]
	redzone_before    ?int                 @[omitempty]
	redzone_after     ?int                 @[omitempty]
	snapshot_bytes    int                  @[omitempty]
	snapshot_argument bool                 @[omitempty]
	argument_entry    ?NativeArgumentEntry @[omitempty]
}

struct NativeArgumentEntry {
	ready             int
	register          string @[omitempty]
	stack_offset      ?int
	stack_adjusted    int  @[omitempty]
	frame_ready       int  @[omitempty]
	preserve_register bool @[omitempty]
}

struct MachineCodeRange {
	section         int
	name            string
	start_offset    string
	end_offset      string
	bytes_hex       string
	bytes_truncated bool @[omitempty]
}

struct MachineMapping {
	evidence       string = 'compiler_allocator'
	frame_register string
	code           []MachineCodeRange
	homes          []NativeValueHome
}

struct RegisterReading {
	name  string
	value string
}

struct RegisterSnapshot {
	debugger  string
	evidence  string = 'debugger_at_stop'
	frame     int
	registers []RegisterReading
}

fn native_debug_registers(backend string) []string {
	return match backend {
		'amd64' {
			['rax', 'rbx', 'rcx', 'rdx', 'rsi', 'rdi', 'rbp', 'rsp', 'r8', 'r9', 'r10', 'r11',
				'r12', 'r13', 'r14', 'r15', 'rip']
		}
		'arm64' {
			mut registers := []string{cap: 33}
			for i in 0 .. 31 {
				registers << 'x${i}'
			}
			registers << ['sp', 'pc']
			registers
		}
		else { []string{} }
	}
}

fn debugger_register_snapshot(output string, begin string, end string, debugger string, names []string) ?RegisterSnapshot {
	if names.len == 0 {
		return none
	}
	start := output.index(begin) or { return none }
	mut block := output[start + begin.len..]
	if end != '' {
		stop := block.index(end) or { return none }
		block = block[..stop]
	}
	mut readings := []RegisterReading{}
	for line in block.split_into_lines() {
		if line.starts_with('(lldb) ') {
			break
		}
		words := line.fields()
		value_index := if debugger == 'lldb' { 2 } else { 1 }
		if words.len <= value_index || (debugger == 'lldb' && words[1] != '=')
			|| !words[value_index].starts_with('0x') {
			continue
		}
		// LLDB and GDB may render ARM64's frame and link registers with their aliases.
		name := match words[0] {
			'fp' {
				if 'x29' in names { 'x29' } else { words[0] }
			}
			'lr' {
				if 'x30' in names { 'x30' } else { words[0] }
			}
			else { words[0] }
		}
		if name !in names {
			continue
		}
		value := parse_address(words[value_index]) or { continue }
		readings << RegisterReading{
			name:  name
			value: hex_address(value)
		}
	}
	if readings.len == 0 {
		return none
	}
	return RegisterSnapshot{
		debugger:  debugger
		registers: readings
	}
}

fn (bundle &Bundle) with_machine_mapping(location Location) !Location {
	frame_register := match bundle.manifest.options.backend {
		'amd64' { 'rbp' }
		'arm64' { 'x29' }
		else {
			return error('machine allocation tracking requires the amd64 or arm64 native backend')
		}
	}
	if location.ssa_value < 0 || location.ssa_opcode == '' {
		return error('no mapped SSA instruction at this location')
	}
	native_homes := bundle.native_homes or {
		return error('build with --trace-ssa and a compiler that records native allocations')
	}
	graph := bundle.read_ssa_graph()!
	root := graph.instructions.filter(it.id == location.ssa_value
		&& it.function == location.function && it.op == location.ssa_opcode)
	if root.len != 1 {
		return error('mapped instruction does not match the SSA graph')
	}
	mut values := {
		location.ssa_value: true
	}
	for operand in root[0].operands {
		if operand.role in ['use', 'definition'] {
			values[operand.id] = true
		}
	}
	binary := os.read_bytes(bundle.artifact)!
	if digest(binary) != bundle.artifact_sha256 {
		return error('artifact SHA-256 changed after loading the source map')
	}
	mut code := []MachineCodeRange{}
	for range in bundle.ranges {
		if range.location.ssa_value == location.ssa_value && range.location.function == location.function {
			section := bundle.image.section(range.section)!
			size := range.end - range.start
			display_size := if size > max_machine_range_bytes {
				max_machine_range_bytes
			} else {
				size
			}
			bytes := view(binary, section.offset + range.start, display_size)!
			code << MachineCodeRange{
				section:         range.section
				name:            section.name
				start_offset:    hex_address(range.start)
				end_offset:      hex_address(range.end)
				bytes_hex:       bytes.hex()
				bytes_truncated: size > display_size
			}
		}
	}
	if code.len == 0 {
		return error('no emitted machine-code range for the mapped SSA instruction')
	}
	mut homes := native_homes.filter(it.function == location.function && it.value in values)
	homes = homes.map(NativeValueHome{ ...it, snapshot_bytes: 0, snapshot_argument: false, argument_entry: none })
	homes.sort(a.value < b.value)
	return Location{
		...location
		machine: MachineMapping{
			frame_register: frame_register
			code:           code
			homes:          homes
		}
	}
}

fn (bundle &Bundle) with_machine_diagnosis(report Diagnosis) Diagnosis {
	if report.kind !in ['crash', 'fuel_exhausted', 'memory_error', 'stopped'] {
		return report
	}
	location := report.location or {
		return Diagnosis{ ...report, machine_error: 'no mapped SSA instruction at the stop' }
	}
	mapped := bundle.with_machine_mapping(location) or {
		return Diagnosis{ ...report, machine_error: err.msg() }
	}
	return Diagnosis{ ...report, location: mapped }
}

fn write_machine_mapping(mut out strings.Builder, machine MachineMapping) {
	out.writeln('  = native code and compiler allocations')
	for range in machine.code {
		out.writeln('    ${range.name} (section ${range.section}) [${range.start_offset}, ${range.end_offset})')
		suffix := if range.bytes_truncated { ' …' } else { '' }
		out.writeln('      ${range.bytes_hex}${suffix}')
	}
	for home in machine.homes {
		if home.register != '' {
			out.writeln('    SSA %${home.value} register ${home.register}')
		}
		if offset := home.frame_offset {
			out.writeln('    SSA %${home.value} frame slot [${machine.frame_register}${offset}]')
		}
		if offset := home.object_offset {
			address := '${machine.frame_register}${offset}'
			if alignment := home.object_alignment {
				out.writeln('    SSA %${home.value} stack object at align_up(${address}, ${alignment})')
			} else {
				out.writeln('    SSA %${home.value} stack object [${address}]')
			}
		}
	}
}
