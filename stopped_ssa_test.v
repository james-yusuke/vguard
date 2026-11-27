module main

import json2
import os

fn test_stopped_ssa_plan_preserves_a_zero_stack_argument_offset() {
	entry := NativeArgumentEntry{ ready: 36, stack_offset: 0, stack_adjusted: 4, frame_ready: 8 }
	encoded := json2.encode(entry)
	assert encoded.contains('"stack_offset":0')
}

fn test_control_flow_homes_allow_separate_machine_paths() {
	homes := NativeControlHomes{ prefix_through: 4, alternate_start: 13, alternate_through: 13 }
	assert homes.includes(4)
	assert !homes.includes(5)
	assert !homes.includes(12)
	assert homes.includes(13)
	assert !homes.includes(14)
}

fn test_recovery_plan_can_stop_at_a_mapped_instruction_without_a_home() {
	bundle := Bundle{
		image:        Image{ sections: [Section{ index: 1, address: 0x1000, size: 64 }] }
		native_homes: [NativeValueHome{ function: 'other', value: 7, snapshot_bytes: 8 }]
		ranges:       [
			PlacedRange{
				section:  1
				start:    0x10
				end:      0x18
				location: Location{ function: 'literal_site', ssa_opcode: 'call' }
			},
		]
	}
	plan := bundle.recovery_plan(false) or { panic(err) }
	region := plan.region_at(0x1013) or { panic('instruction is absent from the recovery plan') }
	assert region.function == 'literal_site'
	assert region.function !in plan.homes
}

fn test_stopped_literals_require_compiler_width_and_preserve_bits() {
	literal := SsaOperand{ id: 17, role: 'use', kind: 'constant', text: '-2', literal_bytes: 1 }
	negative := stopped_literal(literal) or { panic('no literal bits') }
	assert negative.bits == '0xfe' && negative.bytes == 1
	assert negative.evidence == 'compiler_ssa_literal'
	wide := stopped_literal(SsaOperand{ ...literal, text: '0xffff_ffff_ffff_ffff', literal_bytes: 8 }) or { panic('no wide literal') }
	assert wide.bits == '0xffffffffffffffff'
	assert stopped_literal(SsaOperand{ ...literal, text: '41suffix' }) == none
	assert stopped_literal(SsaOperand{ ...literal, literal_bytes: 0 }) == none
	assert stopped_literal(SsaOperand{ ...literal, kind: 'global' }) == none
}

fn test_rematerialization_uses_integer_semantics_and_rejects_memory_dependencies() {
	argument := SsaOperand{ id: 1, role: 'use', kind: 'argument' }
	three := SsaOperand{ id: 2, role: 'use', kind: 'constant', text: '3', literal_bytes: 1 }
	xor := SsaInstruction{
		id:       10
		op:       'xor'
		function: 'test_f'
		operands: [argument, three]
	}
	input := SsaOperand{ id: 10, role: 'use', kind: 'instruction' }
	root := SsaInstruction{ id: 20, op: 'ret', function: 'test_f', operands: [input] }
	graph := SsaGraph{ instructions: [xor, root] }
	homes := {
		10: NativeValueHome{ snapshot_bytes: 1 }
	}
	observation := StoppedSsaValue{ value: 1, bits: '0xfe', bytes: 1, argument: true, storage: 'frame_slot' }
	values := rematerialized_stop_inputs(graph, root, homes, [observation])
	assert values.len == 1 && values[0].bits == '0xfd'
	assert values[0].evidence == 'derived_ssa_integer'
	assert rematerialized_stop_inputs(graph, root, homes, []).len == 0
	load := SsaInstruction{ ...xor, op: 'load', operands: [argument] }
	assert rematerialized_stop_inputs(SsaGraph{ instructions: [load, root] }, root, homes,
		[observation]).len == 0
}

fn test_sampled_stop_inputs_keep_only_observed_operands_and_preserve_debugger_values() {
	instruction := SsaInstruction{
		id:       10
		block:    1
		op:       'inline_asm'
		function: 'sampled'
		operands: [
			SsaOperand{ id: 1, role: 'use', kind: 'argument' },
			SsaOperand{ id: 2, role: 'use', kind: 'instruction' },
			SsaOperand{ id: 3, role: 'use', kind: 'instruction' },
			SsaOperand{ id: 4, role: 'definition', kind: 'phi_result' },
		]
	}
	readings := {
		1: RuntimeSsaValue{ bits: '0x12', bytes: 8, event: 4 }
		2: RuntimeSsaValue{ bits: '0x31', bytes: 8, event: 8 }
		3: RuntimeSsaValue{ bits: '0x33', bytes: 8, event: 10 }
		4: RuntimeSsaValue{ bits: '0x34', bytes: 8, event: 7 }
	}
	inputs := sampled_stop_inputs(instruction, readings, 10)
	assert inputs.map(it.value) == [1, 2]
	assert inputs[0].argument && inputs[1].evidence == 'native_ssa_sample_before_instruction'
	assert sampled_stop_inputs(SsaInstruction{ ...instruction, op: 'phi' }, readings, 10).len == 0
	location := Location{ function: 'sampled', ssa_value: 10, ssa_opcode: 'inline_asm' }
	report := Diagnosis{
		location:     location
		runtime_stop: RuntimeStopAnchor{ frame: 0x1200, thread: 3 }
		stopped_ssa:  StoppedSsa{
			location: location
			thread:   3
			values:   [StoppedSsaValue{ value: 1, bits: '0x13', storage: 'register' }]
		}
	}
	merged := with_sampled_stop_inputs(report, inputs, false).stopped_ssa or { panic('no stop values') }
	assert merged.values[0].bits == '0x13' && merged.values[0].storage == 'register'
	assert merged.values[1].bits == '0x31' && merged.values[1].event == 8
	recovered := with_sampled_stop_inputs(Diagnosis{ ...report, stopped_ssa: none }, inputs,
		false).stopped_ssa or { panic('no sampled stop values') }
	assert recovered.evidence == 'native_ssa_samples_at_debugger_stop'
	assert recovered.values[0].bits == '0x12'
}

fn test_return_register_recovery_checks_the_final_ssa_operand() {
	location := Location{ function: 'f', ssa_value: 10, ssa_opcode: 'ret' }
	graph := SsaGraph{
		instructions: [
			SsaInstruction{
				id:       10
				op:       'ret'
				function: 'f'
				operands: [SsaOperand{ id: 7, role: 'use', kind: 'argument' }]
			},
		]
	}
	home := NativeReturnHome{ value: 7, bytes: 1, register: 'rax' }
	value := stopped_return_value(DebuggerValueFrame{ return_bits: '0xfe' }, location, graph,
		home) or { panic(err) }
	assert value.value == 7 && value.bits == '0xfe' && value.argument
	assert value.storage == 'return_register'
	mismatched := stopped_return_value(DebuggerValueFrame{ return_bits: '0xfe' }, location, graph,
		NativeReturnHome{ ...home, value: 6 }) or {
		assert err.msg().contains('disagrees')
		StoppedSsaValue{}
	}
	assert mismatched.storage == ''
	unmasked := stopped_return_value(DebuggerValueFrame{ return_bits: '0x1fe' }, location, graph,
		home) or {
		assert err.msg().contains('width')
		StoppedSsaValue{}
	}
	assert unmasked.storage == ''
}

fn test_stopped_ssa_liveness_treats_phi_inputs_as_edge_uses() {
	graph := SsaGraph{
		instructions: [
			SsaInstruction{ id: 10, block: 1, op: 'add', function: 'f' },
			SsaInstruction{ id: 11, block: 1, op: 'jmp', function: 'f' },
			SsaInstruction{ id: 20, block: 2, op: 'add', function: 'f' },
			SsaInstruction{ id: 21, block: 2, op: 'jmp', function: 'f' },
			SsaInstruction{
				id:       30
				block:    3
				op:       'phi'
				function: 'f'
				operands: [
					SsaOperand{ id: 10, role: 'use' },
					SsaOperand{ id: 1, role: 'block' },
					SsaOperand{ id: 20, role: 'use' },
					SsaOperand{ id: 2, role: 'block' },
				]
			},
			SsaInstruction{
				id:       31
				block:    3
				op:       'ret'
				function: 'f'
				operands: [SsaOperand{ id: 30, role: 'use' }]
			},
		]
		blocks:       [
			SsaBlock{ id: 1, function: 'f', instructions: [10, 11], successors: [3] },
			SsaBlock{ id: 2, function: 'f', instructions: [20, 21], successors: [3] },
			SsaBlock{ id: 3, function: 'f', instructions: [30, 31] },
		]
	}
	homes := {
		10: NativeValueHome{}
		20: NativeValueHome{}
		30: NativeValueHome{}
	}
	left := recover_live_values(graph, Location{ function: 'f', ssa_value: 11, ssa_opcode: 'jmp' }, homes) or { panic(err) }
	assert left == {
		10: true
	}
	before := recover_live_values(graph, Location{ function: 'f', ssa_value: 10, ssa_opcode: 'add' }, homes) or { panic(err) }
	assert before.len == 0
	join := recover_live_values(graph, Location{ function: 'f', ssa_value: 31, ssa_opcode: 'ret' }, homes) or { panic(err) }
	assert join == {
		30: true
	}
}

const stopped_ssa_fixture = 'module main

@[noinline]
fn pause_site(left u64, right u64) u64 {
	sum := left + right
	return sum ^ left
}

@[noinline]
fn caller(value u64) u64 {
	return pause_site(value, 2) + value
}

@[noinline]
fn immediate() i8 {
	return i8(-2)
}

@[noinline]
fn with_literal(value u64) u64 {
	return value ^ u64(0x1122334455667788)
}

@[noinline]
fn float32_return(value f32) f32 {
	return value + f32(0.25)
}

@[noinline]
fn float64_return(value f64) f64 {
	return value - 0.25
}

@[noinline]
fn branch_probe(left u64, right u64, choice bool) u64 {
	sum := left + right
	if choice {
		println(left)
		return sum + left
	}
	println(right)
	return sum + right
}

@[noinline]
fn spread(a u64, b u64, c u64, d u64, e u64, f u64, g u64, h u64, i u64) u64 {
	return a + b + c + d + e + f + g + h + i
}

fn main() {
	assert caller(40) == 42
	assert immediate() == -2
	assert with_literal(1) == u64(0x1122334455667789)
	assert float32_return(f32(1.25)) == f32(1.5)
	assert float64_return(-1.25) == -1.5
	assert branch_probe(40, 2, false) == 44
	assert branch_probe(40, 2, true) == 82
	assert spread(11, 12, 13, 14, 15, 16, 17, 18, 19) == 135
}
'

fn test_gdb_recovers_a_live_result_and_arguments_at_a_requested_native_stop() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	if compiler == '' || os.user_os() != 'linux' || arch == '' {
		return
	}
	gdb := executable('gdb') or { return }
	// Containers that translate machine instructions may lack ptrace register support.
	probe := capture(Command{
		executable: gdb
		args:       ['--nx', '--batch', '-ex', 'set disable-randomization off', '-ex', 'starti',
			'--args', '/bin/true']
	}) or { return }
	if !probe.stdout.contains('Program stopped.') {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'recovery.v')
	os.write_file(source, stopped_ssa_fixture) or { panic(err) }
	for prod in [false, true] {
		path := build(BuildOptions{
			source:   source
			compiler: os.real_path(compiler)
			backend:  arch
			target:   'linux/' + arch
			prod:     prod
			args:     ['-gc', 'none']
		}, os.join_path(dir, 'build-${prod}'), false, trace_ssa: true) or { panic(err) }
		bundle := open_bundle(path) or { panic(err) }
		xor := bundle.ranges.filter(it.location.function == 'pause_site' && it.location.ssa_opcode == 'xor')
		assert xor.len > 0
		section := bundle.image.section(xor[0].section) or { panic(err) }
		address := section.address + xor[0].start
		legacy := bundle.run(ExecutionCase{}) or { panic(err) }
		assert legacy.kind == 'exited' && legacy.outcome.exit_code == 0
		assert !json2.encode(legacy).contains('"stopped_ssa"')
		report := bundle.run(ExecutionCase{}, recover_ssa: true, stop_at: address, stack: true) or { panic(err) }
		assert report.kind == 'stopped', report.location_error
		assert report.outcome.status == 'stopped' && report.outcome.exit_code == -1
		snapshot := report.stopped_ssa or { panic(report.stopped_ssa_error) }
		assert snapshot.location.function == 'pause_site' && snapshot.location.ssa_opcode == 'xor'
		assert snapshot.values.any(it.bits == '0x2a' && it.bytes == 8)
		assert snapshot.values.any(it.bits == '0x28' && it.argument)
		assert report.stopped_frames.any(it.location.function == 'caller' && it.values.any(it.bits == '0x28' && it.argument))

		plan := bundle.recovery_plan(false) or { panic(err) }
		graph := bundle.read_ssa_graph() or { panic(err) }
		literal_ops := graph.instructions.filter(it.function == 'with_literal'
			&& it.operands.any(it.literal_bytes == 8
				&& (stopped_literal(it) or { StoppedSsaValue{} }).bits == '0x1122334455667788'))
		assert literal_ops.len == 1
		literal_ranges := bundle.ranges.filter(it.location.ssa_value == literal_ops[0].id)
		assert literal_ranges.len == 1
		literal_range := literal_ranges[0]
		literal_section := bundle.image.section(literal_range.section) or { panic(err) }
		literal_stop := bundle.run(ExecutionCase{},
			recover_ssa: true
			stop_at:     literal_section.address + literal_range.start
		) or { panic(err) }
		literal_values := literal_stop.stopped_ssa or { panic(literal_stop.stopped_ssa_error) }
		assert literal_values.values.any(it.bits == '0x1122334455667788' && it.bytes == 8
			&& it.evidence == 'compiler_ssa_literal'), json2.encode(literal_values)

		branches := bundle.ranges.filter(it.location.function == 'branch_probe'
			&& it.location.ssa_opcode == 'br')
		assert branches.len == 1
		branch_section := bundle.image.section(branches[0].section) or { panic(err) }
		branch_start := branch_section.address + branches[0].start
		branch_end := branch_section.address + branches[0].end
		disassembly := capture(Command{
			executable: gdb
			args:       ['--nx', '--batch', '-iex', 'set auto-load off', '-ex',
				'python print(hex(gdb.selected_inferior().architecture().disassemble(${branch_start}, count=2)[1]["addr"]))',
				bundle.artifact]
		}) or { panic(err) }
		branch_stop := parse_address(disassembly.stdout.trim_space()) or { panic(disassembly.stdout + disassembly.stderr) }
		assert branch_stop > branch_start && branch_stop < branch_end
		boundaries := branches[0].control_homes or { panic('missing stable branch prefix') }
		assert boundaries.includes(branch_stop - branch_start)
		branch_snapshot := bundle.run(ExecutionCase{}, recover_ssa: true, stop_at: branch_stop) or {
			panic(err)
		}
		assert branch_snapshot.kind == 'stopped'
		branch_values := branch_snapshot.stopped_ssa or { panic(branch_snapshot.stopped_ssa_error) }
		assert branch_values.location.ssa_opcode == 'br'
		assert branch_values.values.any(it.bits == '0x28' && it.bytes == 8 && it.argument)
		assert branch_values.values.any(it.bits == '0x0' && it.bytes == 1)
		if prod {
			assert branch_values.values.any(it.bits == '0x2a' && it.bytes == 8 && !it.argument), json2.encode(branch_values)
		}

		prologue := plan.ranges.filter(it.prologue && it.function == 'spread')
		assert prologue.len == 1
		entry := bundle.run(ExecutionCase{}, recover_ssa: true, stop_at: prologue[0].start) or {
			panic(err)
		}
		assert entry.kind == 'stopped', entry.location_error
		entry_location := entry.location or { panic(entry.location_error) }
		assert entry_location.precision == 'function_prologue' && entry_location.function == 'spread'
		entry_values := entry.stopped_ssa or { panic(entry.stopped_ssa_error) }
		assert entry_values.values.len == 9
		assert entry_values.values.all(it.argument)
		assert entry_values.values.any(it.bits == '0xb' && it.storage == 'incoming_register')
		assert entry_values.values.any(it.bits == '0x13' && it.storage == 'incoming_stack')
		if !prod {
			misaligned := bundle.run(ExecutionCase{},
				recover_ssa: true
				stop_at:     prologue[0].start + 1
			) or {
				assert err.msg().contains('instruction boundary')
				Diagnosis{}
			}
			assert misaligned.kind == ''
		}

		mut spills := []int{}
		for home in plan.homes['spread'] {
			if abi := home.argument_entry {
				spills << abi.ready
			}
		}
		spills.sort()
		assert spills.len == 9 && prologue[0].start + u64(spills[0]) < prologue[0].end
		partial := bundle.run(ExecutionCase{},
			recover_ssa: true
			stop_at:     prologue[0].start +
				u64(spills[0])
		) or { panic(err) }
		partial_values := partial.stopped_ssa or { panic(partial.stopped_ssa_error) }
		assert partial_values.values.len == 9
		assert partial_values.values.any(it.bits == '0xb' && it.storage in [
			'frame_slot',
			'register',
		])
		assert partial_values.values.any(it.bits == '0xc' && it.storage == 'incoming_register')
		assert partial_values.values.any(it.bits == '0x13' && it.storage == 'incoming_stack')

		ret := plan.ranges.filter(it.function == 'pause_site' && it.recovery_prefix > 0)
		assert ret.len == 1
		before_restore := bundle.run(ExecutionCase{},
			recover_ssa: true
			stop_at:     ret[0].start +
				u64(ret[0].recovery_prefix)
		) or { panic(err) }
		live_return := before_restore.stopped_ssa or { panic(before_restore.stopped_ssa_error) }
		assert live_return.location.ssa_opcode == 'ret'
		assert live_return.values.any(it.bits == '0x2' && !it.argument)
		native_ret_size := if arch == 'arm64' { u64(4) } else { u64(1) }
		after_restore := bundle.run(ExecutionCase{},
			recover_ssa: true
			stop_at:     ret[0].end -
				native_ret_size
		) or { panic(err) }
		assert after_restore.kind == 'stopped'
		returned := after_restore.stopped_ssa or { panic(after_restore.stopped_ssa_error) }
		expected_register := if arch == 'amd64' { 'rax' } else { 'x0' }
		assert returned.values.len == 1
		assert returned.values[0].bits == '0x2'
		assert returned.values[0].storage == 'return_register'
		assert returned.values[0].register == expected_register
		assert returned.values[0].value == (ret[0].return_home or { panic('missing native return home') }).value

		constant_return := plan.ranges.filter(it.function == 'immediate' && it.return_home != none)
		assert constant_return.len == 1
		constant_stop := bundle.run(ExecutionCase{},
			recover_ssa: true
			stop_at:     constant_return[0].end -
				native_ret_size
		) or { panic(err) }
		constant := constant_stop.stopped_ssa or { panic(constant_stop.stopped_ssa_error) }
		assert constant.values.len == 1
		assert constant.values[0].bits == '0xfe' && constant.values[0].bytes == 1
		assert constant.values[0].storage == 'return_register'

		for function, bits in {
			'float32_return': '0x3fc00000'
			'float64_return': '0xbff8000000000000'
		} {
			ranges := plan.ranges.filter(it.function == function && it.return_home != none)
			assert ranges.len == 1
			home := ranges[0].return_home or { panic('missing float return home') }
			float_stop := bundle.run(ExecutionCase{},
				recover_ssa: true
				stop_at:     ranges[0].end - native_ret_size
			) or { panic(err) }
			sample := float_stop.stopped_ssa or { panic(float_stop.stopped_ssa_error) }
			width := if function == 'float32_return' { 4 } else { 8 }
			register := if arch == 'amd64' {
				'rax'
			} else if width == 4 {
				's0'
			} else {
				'd0'
			}
			assert sample.location.function == function
			assert sample.values.len == 1
			assert sample.values[0].storage == 'return_register'
			assert sample.values[0].register == register
			assert sample.values[0].value == home.value
			assert sample.values[0].bytes == width && sample.values[0].bits == bits
		}
	}
}
