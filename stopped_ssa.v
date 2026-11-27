module main

import json2
import os
import strings

const max_recovery_homes = 1024

struct RecoveryRange {
	start           u64
	end             u64
	function        string
	prologue        bool                @[omitempty]
	recovery_prefix int                 @[omitempty]
	return_home     ?NativeReturnHome   @[omitempty]
	control_homes   ?NativeControlHomes @[omitempty]
}

struct RecoveryPlan {
	artifact       string
	preferred_base u64
	frame_register string
	all_frames     bool
	ranges         []RecoveryRange
	homes          map[string][]NativeValueHome
}

struct DebuggerValue {
	id   int
	bits string
}

struct DebuggerValueFrame {
	thread      int
	selected    bool
	index       int
	pc          string
	at_entry    bool
	values      []DebuggerValue
	return_bits string
}

struct StoppedSsaValue {
	value        int
	bits         string
	bytes        int
	storage      string
	register     string @[omitempty]
	frame_offset ?int   @[omitempty]
	argument     bool   @[omitempty]
	evidence     string @[omitempty]
	event        int    @[omitempty]
}

struct StoppedSsa {
	evidence  string = 'debugger_at_stop'
	location  Location
	thread    int
	frame     int
	values    []StoppedSsaValue
	truncated bool @[omitempty]
}

fn (bundle &Bundle) recovery_plan(all_frames bool) !RecoveryPlan {
	native_homes := bundle.native_homes or { return error('build with --trace-ssa to recover stopped values') }
	frame_register := if bundle.manifest.options.backend == 'amd64' { 'rbp' } else { 'x29' }
	mut valid_registers := native_debug_registers(bundle.manifest.options.backend)
	if frame_register == 'x29' {
		for number in 8 .. 16 {
			valid_registers << 'd${number}'
		}
	}
	mut homes := map[string][]NativeValueHome{}
	for home in native_homes {
		if home.snapshot_bytes !in [1, 2, 4, 8] || (home.register != '' && home.register !in valid_registers) {
			continue
		}
		if alignment := home.object_alignment {
			if alignment <= 0 || (alignment & (alignment - 1)) != 0 {
				return error('invalid alignment in native value home')
			}
		}
		if homes[home.function].len < max_recovery_homes {
			homes[home.function] << home
		}
	}
	if homes.len == 0 && !bundle.ranges.any(it.return_home != none) {
		return error('rebuild with the compiler patch that records recoverable native value homes')
	}
	mut ranges := []RecoveryRange{}
	mut seen := map[string]bool{}
	for range in bundle.ranges {
		function := range.location.function
		if returned := range.return_home {
			expected := if frame_register == 'rbp' { ['rax'] } else { ['x0', 's0', 'd0'] }
			if returned.register !in expected {
				return error('return home uses a register from a different native backend')
			}
		}
		section := bundle.image.section(range.section)!
		if parameters := homes[function] {
			if function !in seen {
				seen[function] = true
				if range.function_start < range.start
					&& parameters.any(it.argument_entry != none) {
					ranges << RecoveryRange{
						start:    section.address + range.function_start
						end:      section.address + range.start
						function: function
						prologue: true
					}
				}
			}
		}
		ranges << RecoveryRange{
			start:           section.address + range.start
			end:             section.address + range.end
			function:        function
			recovery_prefix: range.recovery_prefix
			return_home:     range.return_home
			control_homes:   range.control_homes
		}
	}
	ranges.sort(a.start < b.start)
	return RecoveryPlan{
		artifact:       os.real_path(bundle.artifact)
		preferred_base: bundle.image.preferred_base
		frame_register: frame_register
		all_frames:     all_frames
		ranges:         ranges
		homes:          homes
	}
}

fn (plan &RecoveryPlan) region_at(address u64) ?RecoveryRange {
	mut lo := 0
	mut hi := plan.ranges.len
	for lo < hi {
		mid := (lo + hi) / 2
		if plan.ranges[mid].end <= address {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < plan.ranges.len && plan.ranges[lo].start <= address {
		return plan.ranges[lo]
	}
	return none
}

fn recover_prologue(frame DebuggerValueFrame, region RecoveryRange, offset u64, homes []NativeValueHome) StoppedSsa {
	mut parameters := map[int]NativeValueHome{}
	for home in homes {
		if home.snapshot_argument && home.argument_entry != none {
			parameters[home.value] = home
		}
	}
	mut values := []StoppedSsaValue{}
	for reading in frame.values {
		home := parameters[reading.id] or { continue }
		entry := home.argument_entry or { continue }
		bits := parse_address(reading.bits) or { continue }
		if entry.ready > 0 && offset >= u64(entry.ready) {
			values << stopped_home_value(home, bits)
		} else if entry.register != '' && (offset == 0 || entry.preserve_register) {
			values << StoppedSsaValue{
				value:    home.value
				bits:     hex_address(bits)
				bytes:    home.snapshot_bytes
				storage:  'incoming_register'
				register: entry.register
				argument: true
			}
		} else if entry.stack_offset != none && (offset == 0 || entry.frame_ready > 0) {
			values << StoppedSsaValue{
				value:    home.value
				bits:     hex_address(bits)
				bytes:    home.snapshot_bytes
				storage:  'incoming_stack'
				argument: true
			}
		}
	}
	values.sort(a.value < b.value)
	return StoppedSsa{
		location:  Location{ function: region.function, precision: 'function_prologue' }
		thread:    frame.thread
		frame:     frame.index
		values:    values
		truncated: homes.len >= max_recovery_homes
	}
}

fn stopped_home_value(home NativeValueHome, bits u64) StoppedSsaValue {
	return StoppedSsaValue{
		value:        home.value
		bits:         hex_address(bits)
		bytes:        home.snapshot_bytes
		storage:      if home.object_offset != none {
			'frame_object_address'
		} else if home.register != '' {
			'register'
		} else {
			'frame_slot'
		}
		register:     home.register
		frame_offset: if home.object_offset != none {
			home.object_offset
		} else {
			home.frame_offset
		}
		argument:     home.snapshot_argument
	}
}

fn prepare_gdb_recovery(plan RecoveryPlan, work string) ![]string {
	script := os.join_path(work, 'stopped-ssa.py')
	input := os.join_path(work, 'recovery-plan.json')
	output := os.join_path(work, 'stopped-ssa.json')
	os.write_file(script, $embed_file('compiler/stopped_ssa_gdb.py').to_string())!
	os.write_file(input, json2.encode(plan))!
	return ['-ex', 'python vguard_recovery_plan = ${json2.encode(input)}', '-ex',
		'python vguard_recovery_output = ${json2.encode(output)}', '-ex',
		'python exec(compile(open(${json2.encode(script)}, "rb").read(), ${json2.encode(script)}, "exec"))']
}

fn transfer_live_values(mut live map[int]bool, instruction SsaInstruction, homes map[int]NativeValueHome) {
	live.delete(instruction.id)
	for operand in instruction.operands {
		if operand.role == 'definition' {
			live.delete(operand.id)
		}
	}
	if instruction.op != 'phi' {
		for operand in instruction.operands {
			if operand.role == 'use' && operand.id in homes {
				live[operand.id] = true
			}
		}
	}
}

fn recover_live_values(graph SsaGraph, location Location, homes map[int]NativeValueHome) !map[int]bool {
	mut instructions := map[int]SsaInstruction{}
	mut blocks := map[int]SsaBlock{}
	mut predecessors := map[int][]int{}
	mut phi_inputs := map[int]map[int][]int{}
	for instruction in graph.instructions {
		if instruction.function == location.function {
			instructions[instruction.id] = instruction
			if instruction.op == 'phi' {
				for index in 0 .. instruction.operands.len / 2 {
					value := instruction.operands[2 * index]
					predecessor := instruction.operands[2 * index + 1]
					if value.id in homes && value.role == 'use' && predecessor.role == 'block' {
						mut incoming := phi_inputs[instruction.block]
						incoming[predecessor.id] << value.id
						phi_inputs[instruction.block] = incoming
					}
				}
			}
		}
	}
	root := instructions[location.ssa_value] or { return error('stop instruction is absent from the SSA graph') }
	if root.op != location.ssa_opcode {
		return error('stop instruction does not match the SSA graph')
	}
	mut pending := []int{}
	mut queued := map[int]bool{}
	for block in graph.blocks {
		if block.function == location.function {
			blocks[block.id] = block
			for successor in block.successors {
				predecessors[successor] << block.id
			}
			pending << block.id
			queued[block.id] = true
		}
	}
	mut live_in := map[int]map[int]bool{}
	mut live_out := map[int]map[int]bool{}
	for pending.len > 0 {
		id := pending.pop()
		queued.delete(id)
		block := blocks[id]
		mut live := map[int]bool{}
		for successor in block.successors {
			for value, _ in live_in[successor] {
				live[value] = true
			}
			for value in phi_inputs[successor][id] {
				live[value] = true
			}
		}
		live_out[id] = live.clone()
		for index := block.instructions.len - 1; index >= 0; index-- {
			instruction := instructions[block.instructions[index]] or { return error('missing instruction in SSA block') }
			transfer_live_values(mut live, instruction, homes)
		}
		// Backward transfer is monotonic, so equal cardinality means equal sets.
		if live.len != live_in[id].len {
			live_in[id] = live.move()
			for predecessor in predecessors[id] {
				if predecessor !in queued {
					pending << predecessor
					queued[predecessor] = true
				}
			}
		}
	}
	block := blocks[root.block] or { return error('missing stop block') }
	mut live := live_out[root.block].clone()
	for index := block.instructions.len - 1; index >= 0; index-- {
		id := block.instructions[index]
		transfer_live_values(mut live, instructions[id], homes)
		if id == root.id {
			return live
		}
	}
	return error('stop instruction is absent from its SSA block')
}

fn stopped_return_value(frame DebuggerValueFrame, location Location, graph SsaGraph, home NativeReturnHome) !StoppedSsaValue {
	if location.ssa_opcode != 'ret' {
		return error('the return home is not mapped to a return instruction')
	}
	for instruction in graph.instructions {
		if instruction.id != location.ssa_value || instruction.function != location.function {
			continue
		}
		if instruction.op != 'ret' || instruction.operands.len != 1
			|| instruction.operands[0].role != 'use' || instruction.operands[0].id != home.value {
			break
		}
		bits := parse_address(frame.return_bits) or { return error('GDB could not read the native return register') }
		if home.bytes < 8 && bits >> (home.bytes * 8) != 0 {
			return error('the sampled return value exceeds its SSA width')
		}
		return StoppedSsaValue{
			value:    home.value
			bits:     hex_address(bits)
			bytes:    home.bytes
			storage:  'return_register'
			register: home.register
			argument: instruction.operands[0].kind == 'argument'
		}
	}
	return error('the recorded native return home disagrees with the final SSA graph')
}

fn (control NativeControlHomes) includes(offset u64) bool {
	return offset <= u64(control.prefix_through) || (control.alternate_start > 0
		&& offset >= u64(control.alternate_start) && offset <= u64(control.alternate_through))
}

fn stopped_instruction(graph SsaGraph, location Location) !SsaInstruction {
	for instruction in graph.instructions {
		if instruction.id == location.ssa_value && instruction.function == location.function
			&& instruction.op == location.ssa_opcode {
			return instruction
		}
	}
	return error('stop instruction does not match the final SSA graph')
}

fn stopped_literal(operand SsaOperand) ?StoppedSsaValue {
	if operand.role != 'use' || operand.kind != 'constant' || operand.literal_bytes !in [
		1,
		2,
		4,
		8,
	] {
		return none
	}
	mut text := operand.text.replace('_', '')
	negative := text.starts_with('-')
	if negative {
		text = text[1..]
	}
	base := if text.starts_with('0x') || text.starts_with('0X') {
		16
	} else if text.starts_with('0b') || text.starts_with('0B') {
		2
	} else if text.starts_with('0o') || text.starts_with('0O') {
		8
	} else {
		10
	}
	digits := if base == 10 { text } else { text[2..] }
	if digits == '' || digits[0] in [`+`, `-`] {
		return none
	}
	magnitude := digits.parse_uint(base, 64) or { return none }
	word := if negative { u64(0) - magnitude } else { magnitude }
	return StoppedSsaValue{
		value:    operand.id
		bits:     hex_address(word & (u64(-1) >> (64 - operand.literal_bytes * 8)))
		bytes:    operand.literal_bytes
		storage:  'literal'
		evidence: 'compiler_ssa_literal'
	}
}

struct IntegerRecovery {
	definitions map[int]SsaInstruction
	homes       map[int]NativeValueHome
	parameters  map[int]StoppedSsaValue
mut:
	cache  map[int]u64
	budget int = 64
}

fn (mut state IntegerRecovery) evaluate(operand SsaOperand, bytes int) ?u64 {
	if state.budget <= 0 || operand.role != 'use' {
		return none
	}
	state.budget--
	if operand.kind == 'argument' {
		argument := state.parameters[operand.id] or { return none }
		if argument.bytes != bytes {
			return none
		}
		return parse_address(argument.bits) or { return none }
	}
	if literal := stopped_literal(operand) {
		if literal.bytes != bytes {
			return none
		}
		return parse_address(literal.bits) or { return none }
	}
	if operand.kind != 'instruction' {
		return none
	}
	home := state.homes[operand.id] or { return none }
	if home.snapshot_bytes != bytes || bytes !in [1, 2, 4, 8] {
		return none
	}
	if bits := state.cache[operand.id] {
		return bits
	}
	instruction := state.definitions[operand.id] or { return none }
	if instruction.operands.len != 2
		|| instruction.op !in ['and_', 'or_', 'xor'] {
		return none
	}
	left := state.evaluate(instruction.operands[0], bytes)?
	right := state.evaluate(instruction.operands[1], bytes)?
	word := match instruction.op {
		'and_' { left & right }
		'or_' { left | right }
		else { left ^ right }
	}
	bits := word & (u64(-1) >> (64 - bytes * 8))
	state.cache[operand.id] = bits
	return bits
}

fn rematerialized_stop_inputs(graph SsaGraph, instruction SsaInstruction, homes map[int]NativeValueHome, readings []StoppedSsaValue) []StoppedSsaValue {
	if instruction.op == 'phi' {
		return []
	}
	mut measured := map[int]bool{}
	mut parameters := map[int]StoppedSsaValue{}
	for reading in readings {
		measured[reading.value] = true
		if reading.argument && reading.storage == 'frame_slot' {
			parameters[reading.value] = reading
		}
	}
	if !instruction.operands.any(it.role == 'use' && it.kind == 'instruction'
		&& it.id in homes && it.id !in measured) {
		return []
	}
	// Both native backends emit these bitwise operations on the raw value bits.
	mut definitions := map[int]SsaInstruction{}
	for definition in graph.instructions {
		if definition.function == instruction.function {
			definitions[definition.id] = definition
		}
	}
	mut result := []StoppedSsaValue{}
	mut derivation := IntegerRecovery{ definitions: definitions, homes: homes, parameters: parameters }
	for operand in instruction.operands {
		if operand.kind != 'instruction' || operand.id in measured {
			continue
		}
		bytes := homes[operand.id].snapshot_bytes
		bits := derivation.evaluate(operand, bytes) or { continue }
		measured[operand.id] = true
		result << StoppedSsaValue{
			value:    operand.id
			bits:     hex_address(bits)
			bytes:    bytes
			storage:  'rematerialized'
			evidence: 'derived_ssa_integer'
		}
	}
	return result
}

fn (bundle &Bundle) recover_frame(frame DebuggerValueFrame, base u64, graph SsaGraph, native_homes []NativeValueHome, region RecoveryRange, offset u64) !StoppedSsa {
	location := bundle.map_debugger_frame(parse_address(frame.pc)!, base, frame.index > 0)!
	instruction := stopped_instruction(graph, location)!
	mut literals := []StoppedSsaValue{}
	// A phi's operands are edge-specific and cannot be selected without a path.
	if instruction.op != 'phi' {
		for operand in instruction.operands {
			if literal := stopped_literal(operand) {
				if !literals.any(it.value == literal.value) {
					literals << literal
				}
			}
		}
	}
	mut returned := ?StoppedSsaValue(none)
	if home := region.return_home {
		if frame.index == 0 && offset >= u64(region.recovery_prefix) && frame.return_bits != '' {
			returned = stopped_return_value(frame, location, graph, home)!
		}
	}
	return_prefix := region.recovery_prefix > 0 && offset <= u64(region.recovery_prefix)
	control_homes := if control := region.control_homes { control.includes(offset) } else { false }
	if !frame.at_entry && !return_prefix && !control_homes && location.ssa_opcode in [
		'ret',
		'br',
		'jmp',
		'switch_',
		'inline_asm',
	] {
		if value := returned {
			literals = literals.filter(it.value != value.value)
			literals << value
		}
		if literals.len > 0 {
			literals.sort(a.value < b.value)
			return StoppedSsa{
				location: location
				thread:   frame.thread
				frame:    frame.index
				values:   literals
			}
		}
		return error('the stop is inside an instruction that can move SSA homes or the frame pointer')
	}
	mut homes := map[int]NativeValueHome{}
	for home in native_homes {
		if home.function == location.function {
			homes[home.value] = home
		}
	}
	live := recover_live_values(graph, location, homes)!
	mut occupied := map[string]int{}
	for id in live.keys() {
		register := homes[id].register
		if register != '' {
			occupied[register]++
		}
	}
	mut written := map[string]bool{}
	if !frame.at_entry {
		written[homes[location.ssa_value].register] = true
		for operand in instruction.operands {
			if operand.role == 'definition' {
				written[homes[operand.id].register] = true
			}
		}
	}
	mut values := []StoppedSsaValue{}
	for reading in frame.values {
		home := homes[reading.id] or { continue }
		if reading.id !in live && !(home.snapshot_argument && home.register == '') {
			continue
		}
		if home.register != '' && (home.register in written || occupied[home.register] != 1) {
			continue
		}
		bits := parse_address(reading.bits) or { continue }
		values << stopped_home_value(home, bits)
	}
	if value := returned {
		if !values.any(it.value == value.value) {
			values << value
		}
	}
	for literal in literals {
		if !values.any(it.value == literal.value) {
			values << literal
		}
	}
	values << rematerialized_stop_inputs(graph, instruction, homes, values)
	values.sort(a.value < b.value)
	return StoppedSsa{
		location:  location
		thread:    frame.thread
		frame:     frame.index
		values:    values
		truncated: homes.len >= max_recovery_homes
	}
}

fn (bundle &Bundle) with_stopped_ssa(report Diagnosis, stop NativeStop, work string, debugger_error string, plan RecoveryPlan) !Diagnosis {
	base := stop.load_base or { return error('debugger did not identify the artifact load address') }
	data := read_output(os.join_path(work, 'stopped-ssa.json'))!
	if data == '' {
		message := debugger_error.trim_space()
		return error(if message == '' {
			'GDB with Python support could not capture any frame data'
		} else {
			'GDB could not capture frame data (${message})'
		})
	}
	frames := json2.decode[[]DebuggerValueFrame](data)!
	graph := bundle.read_ssa_graph()!
	homes := bundle.native_homes or { return error('the native value homes are missing') }
	mut result := []StoppedSsa{}
	mut selected := ?StoppedSsa(none)
	mut location := report.location
	mut location_error := report.location_error
	mut reason := 'the stopped thread has no frame with recoverable native SSA values'
	for frame in frames {
		pc := parse_address(frame.pc) or { continue }
		frame_pc := if frame.index > 0 && pc > base { pc - 1 } else { pc }
		address := bundle.address_from_load_base(frame_pc, base) or { continue }
		region := plan.region_at(address) or { continue }
		offset := address - region.start
		if region.prologue {
			prologue := recover_prologue(frame, region, offset, plan.homes[region.function])
			if frame.selected {
				location = prologue.location
				location_error = ''
				if prologue.values.len > 0 {
					selected = prologue
				} else {
					reason = 'no argument home is established at this point in the prologue'
				}
			} else if prologue.values.len > 0 {
				result << prologue
			}
			continue
		}
		snapshot := bundle.recover_frame(frame, base, graph, homes, region, offset) or {
			if frame.selected && frame.index == 0 {
				reason = err.msg()
			}
			continue
		}
		if snapshot.values.len > 0 {
			if frame.selected && frame.index == 0 {
				selected = snapshot
			} else {
				result << snapshot
			}
		}
	}
	return Diagnosis{
		...report
		location:          location
		location_error:    location_error
		stopped_ssa:       selected
		stopped_frames:    result
		stopped_ssa_error: if selected == none { reason } else { '' }
	}
}

fn sampled_stop_inputs(instruction SsaInstruction, readings map[int]RuntimeSsaValue, root_event int) []StoppedSsaValue {
	if instruction.op == 'phi' {
		return []
	}
	mut values := []StoppedSsaValue{}
	for operand in instruction.operands {
		if operand.role != 'use' || operand.kind !in ['instruction', 'argument', 'phi_result'] {
			continue
		}
		sample := readings[operand.id] or { continue }
		if sample.event <= 0 || sample.event >= root_event || values.any(it.value == operand.id) {
			continue
		}
		values << StoppedSsaValue{
			value:    operand.id
			bits:     sample.bits
			bytes:    sample.bytes
			storage:  'runtime_sample'
			argument: operand.kind == 'argument'
			evidence: 'native_ssa_sample_before_instruction'
			event:    sample.event
		}
	}
	return values
}

fn (snapshot StoppedSsa) with_sampled_inputs(inputs []StoppedSsaValue) StoppedSsa {
	mut values := snapshot.values.clone()
	mut positions := map[int]int{}
	for i, value in values {
		positions[value.value] = i
	}
	for input in inputs {
		index := positions[input.value] or {
			positions[input.value] = values.len
			values << input
			continue
		}
		if values[index].storage == 'rematerialized' {
			values[index] = input
		}
	}
	values.sort(a.value < b.value)
	return StoppedSsa{ ...snapshot, values: values }
}

fn with_sampled_stop_inputs(report Diagnosis, inputs []StoppedSsaValue, all_frames bool) Diagnosis {
	if inputs.len == 0 {
		return report
	}
	anchor := report.runtime_stop or { return report }
	location := report.location or { return report }
	sample_snapshot := StoppedSsa{
		evidence: 'native_ssa_samples_at_debugger_stop'
		location: location
		thread:   anchor.thread
		frame:    anchor.frame_idx
		values:   inputs
	}
	if anchor.caller {
		if !all_frames {
			return report
		}
		mut frames := report.stopped_frames.clone()
		for i, snapshot in frames {
			if snapshot.thread == anchor.thread && snapshot.frame == anchor.frame_idx
				&& snapshot.location.ssa_value == location.ssa_value {
				frames[i] = snapshot.with_sampled_inputs(inputs)
				return Diagnosis{ ...report, stopped_frames: frames }
			}
		}
		frames << sample_snapshot
		return Diagnosis{ ...report, stopped_frames: frames }
	}
	if snapshot := report.stopped_ssa {
		if snapshot.thread != anchor.thread || snapshot.frame != anchor.frame_idx
			|| snapshot.location.ssa_value != location.ssa_value {
			return report
		}
		return Diagnosis{ ...report, stopped_ssa: snapshot.with_sampled_inputs(inputs) }
	}
	return Diagnosis{ ...report, stopped_ssa: sample_snapshot, stopped_ssa_error: '' }
}

fn write_stopped_ssa(mut out strings.Builder, report Diagnosis) {
	mut snapshots := report.stopped_frames.clone()
	if selected := report.stopped_ssa {
		snapshots.insert(0, selected)
	}
	for snapshot in snapshots {
		out.writeln('  = recovered SSA in thread ${snapshot.thread}, frame #${snapshot.frame} (${snapshot.location.function})')
		for value in snapshot.values {
			source := if value.event > 0 {
				'${value.storage}, event ${value.event}'
			} else {
				value.storage
			}
			out.writeln('    %${value.value} = ${value.bits} (${value.bytes} bytes from ${source})')
		}
	}
	if report.stopped_ssa_error != '' {
		out.writeln('  = note: stopped SSA values unavailable (${report.stopped_ssa_error})')
	}
}
