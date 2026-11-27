module main

import json2

fn test_ssa_structure_compares_contents_after_block_and_value_renumbering() {
	reference := SsaGraph{
		instructions: [
			SsaInstruction{
				id:       10
				block:    3
				function: 'compute'
				op:       'add'
				operands: [SsaOperand{ id: 4, role: 'use', kind: 'constant', text: '7' }]
			},
			SsaInstruction{
				id:       11
				block:    3
				function: 'compute'
				op:       'ret'
				operands: [SsaOperand{ id: 10, role: 'use', kind: 'instruction' }]
			},
		]
		blocks:       [SsaBlock{ id: 3, function: 'compute', instructions: [10, 11] }]
	}
	target := SsaGraph{
		instructions: [
			SsaInstruction{
				...reference.instructions[0]
				id:       90
				block:    27
				operands: [SsaOperand{ id: 100, role: 'use', kind: 'constant', text: '7' }]
			},
			SsaInstruction{
				...reference.instructions[1]
				id:       91
				block:    27
				operands: [SsaOperand{ id: 90, role: 'use', kind: 'instruction' }]
			},
		]
		blocks:       [SsaBlock{ id: 27, function: 'compute', instructions: [90, 91] }]
	}
	assert compare_function_structure(target, reference).len == 0
	changed := SsaGraph{
		...target
		instructions: [
			SsaInstruction{
				...target.instructions[0]
				operands: [SsaOperand{ id: 100, role: 'use', kind: 'constant', text: '8' }]
			},
			target.instructions[1],
		]
	}
	assert compare_opcodes(changed, reference).len == 0
	differences := compare_function_structure(changed, reference)
	assert differences.len == 1
	assert differences[0].function == 'compute'
	assert differences[0].instruction == 1
	actual := differences[0].target or { panic('missing changed instruction') }
	assert actual.operands[0].text == '8'
}

fn test_backward_ssa_reports_phi_candidates_and_branch_conditions() {
	graph := SsaGraph{
		version:      1
		blocks:       [
			SsaBlock{ id: 0, function: 'sample', instructions: [10], successors: [1, 2] },
			SsaBlock{ id: 1, function: 'sample', instructions: [11], successors: [2] },
			SsaBlock{ id: 2, function: 'sample', instructions: [12] },
		]
		instructions: [
			SsaInstruction{
				id:       10
				block:    0
				function: 'sample'
				op:       'br'
				operands: [SsaOperand{ id: 3, role: 'use', kind: 'argument' }]
			},
			SsaInstruction{ id: 11, block: 1, function: 'sample', op: 'add' },
			SsaInstruction{
				id:       12
				block:    2
				function: 'sample'
				op:       'phi'
				operands: [
					SsaOperand{ id: 4, role: 'use', kind: 'constant' },
					SsaOperand{ id: 0, role: 'block' },
					SsaOperand{ id: 11, role: 'use', kind: 'instruction' },
					SsaOperand{ id: 1, role: 'block' },
				]
			},
		]
	}
	trace := graph.backward(Location{ function: 'sample', ssa_value: 12, ssa_opcode: 'phi' }) or { panic(err) }
	assert trace.nodes.map(it.id) == [12, 11, 10]
	phi_inputs := trace.edges.filter(it.kind == 'phi_incoming')
	assert phi_inputs.map(it.to) == [4, 11]
	assert phi_inputs.map(it.predecessor or { -1 }) == [0, 1]
	assert trace.edges.any(it.kind == 'predecessor_branch' && it.from == 12 && it.to == 10)
	assert trace.edges.any(it.kind == 'operand' && it.from == 10 && it.to == 3)
	assert !trace.truncated
	assert !json2.encode(trace).contains('"ast"')
}

fn test_ssa_log_replay_rejects_a_change_with_the_wrong_prior_instruction() {
	original := SsaInstruction{ id: 4, block: 1, function: 'example', op: 'add' }
	replacement := SsaInstruction{ ...original, op: 'sub' }
	final := SsaGraph{ instructions: [replacement] }
	baseline := SsaPassRecord{ pass: 'input', after_count: 1, created: [original] }
	edit := SsaPassRecord{
		pass:        'change'
		after_count: 1
		changed:     [SsaPassChange{ before: original, after: replacement }]
	}
	check_ssa_log_replay([baseline, edit], final) or { panic(err) }
	incorrect := SsaPassRecord{
		...edit
		changed: [SsaPassChange{ before: replacement, after: replacement }]
	}
	check_ssa_log_replay([baseline, incorrect], final) or {
		assert err.msg().contains('change does not match %4')
		return
	}
	assert false, 'the log replay did not validate the prior instruction'
}

fn test_debugger_stack_keeps_other_threads_out_of_primary_backtrace_parsing() {
	raw := 'VGUARD_PC 0x150\n#1 0x180 main ()\n\nVGUARD_STACK_BEGIN\nThread 2\n#0 0x700 waiting ()\n#1 0x800 worker ()\n'
	primary, recorded := debugger_stack(raw, '\nVGUARD_STACK_BEGIN\n', 'gdb')
	stack := recorded or { panic('missing stack') }
	assert stack.debugger == 'gdb'
	assert stack.text.contains('Thread 2')
	assert stack.threads.len == 1
	assert stack.threads[0].number == 2
	assert stack.threads[0].frames.map(it.index) == [0, 1]
	stop := parse_gdb(primary, '/tmp/program')
	assert stop.pcs == [u64(0x150), 0x180]
	assert (stop.stop_pc or { 0 }) == 0x150
	frame_only := parse_gdb('#1 0x180 main ()', '/tmp/program')
	assert frame_only.pcs == [u64(0x180)]
	assert frame_only.stop_pc == none
}

fn test_native_stack_maps_each_thread_with_caller_address_adjustment() {
	stack := DebuggerStack{
		debugger: 'gdb'
		text:     'Thread 1\n#0 0x23104 worker ()\n#1 0x23108 caller ()\nThread 2\n#0 0x50000 sleep ()'
	}
	threads := parse_debugger_threads(stack.text)
	bundle := Bundle{
		image:  Image{
			format:         'elf'
			preferred_base: 0x1000
			sections:       [Section{ index: 1, address: 0x1100, size: 8 }]
		}
		ranges: [
			PlacedRange{
				section:  1
				start:    4
				end:      8
				location: Location{ function: 'sample', ssa_value: 5, precision: 'source_span' }
			},
		]
	}
	mapped := bundle.with_mapped_stack(DebuggerStack{ ...stack, threads: threads }, 0x23000)
	assert mapped.text == stack.text
	top := mapped.threads[0].frames[0].mapped_location or { panic('top frame was not mapped') }
	caller := mapped.threads[0].frames[1].mapped_location or { panic('return PC was not adjusted') }
	assert top.ssa_value == caller.ssa_value
	assert top.precision == 'source_span'
	assert caller.precision == 'caller_frame'
	assert mapped.threads[1].frames[0].mapped_location == none
}

fn test_debugger_register_readings_are_scoped_to_the_debugger_command() {
	gdb := 'rbx 0xffff 0\nBEGIN\nrbx 0x12 18\nrbp 0x5000 0x5000\nunknown 0x1 1\nEND\n'
	registers := debugger_register_snapshot(gdb, '\nBEGIN\n', '\nEND\n', 'gdb', ['rbx', 'rbp']) or {
		panic('GDB readings were not decoded')
	}
	assert registers.debugger == 'gdb'
	assert registers.evidence == 'debugger_at_stop'
	assert registers.frame == 0
	assert registers.registers.map(it.name) == ['rbx', 'rbp']
	assert registers.registers.map(it.value) == ['0x12', '0x5000']
	lldb := '(lldb) register read --format hex x19 x29\n x19 = 0x0000000000000007\n fp = 0x5000\n(lldb) quit\n x19 = 0xdead\n'
	snapshot := debugger_register_snapshot(lldb, '(lldb) register read --format hex x19 x29\n',
		'', 'lldb', ['x19', 'x29']) or { panic('LLDB reading was not decoded') }
	assert snapshot.registers.map(it.name) == ['x19', 'x29']
	assert snapshot.registers.map(it.value) == ['0x7', '0x5000']
	assert debugger_register_snapshot(gdb, '\nBEGIN\n', '\nMISSING\n', 'gdb', ['rbx']) == none
}

fn test_debugger_frames_retain_visible_arguments_and_source_positions() {
	trace := '* thread #1, queue = main, stop reason = signal SIGABRT\n' +
		'  * frame #0: 0x00001200 demo\x60worker(n=42) at /tmp/source file.v:7:3 [opt]\n' +
		'  thread #2\n  frame #0: 0x00001500 lib\x60wait\n'
	threads := parse_debugger_threads(trace)
	assert threads.map(it.number) == [1, 2]
	assert threads[0].selected
	frame := threads[0].frames[0]
	assert frame.address == '0x00001200'
	assert frame.arguments == 'n=42'
	source := frame.source or { panic('missing debugger source position') }
	assert source.file == '/tmp/source file.v'
	assert source.line == 7
	assert source.column == 3
	assert threads[1].frames[0].source == none
	frame_without_pc := parse_debugger_frame(r'#0 main (n=<optimized out>) at C:\work\sample.v:12') or {
		panic('missing frame')
	}
	assert frame_without_pc.address == ''
	assert frame_without_pc.arguments == 'n=<optimized out>'
	file := frame_without_pc.source or { panic('missing source') }
	assert file.file == r'C:\work\sample.v'
	assert file.line == 12
	assert file.column == 0
}
