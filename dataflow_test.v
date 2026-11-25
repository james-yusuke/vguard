module main

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
}

fn test_debugger_stack_keeps_other_threads_out_of_primary_backtrace_parsing() {
	raw := 'VGUARD_PC 0x150\n#1 0x180 main ()\n\nVGUARD_STACK_BEGIN\nThread 2\n#0 0x700 waiting ()\n#1 0x800 worker ()\n'
	primary, recorded := debugger_stack(raw, '\nVGUARD_STACK_BEGIN\n', 'gdb')
	stack := recorded or { panic('missing stack') }
	assert stack.debugger == 'gdb'
	assert stack.text.contains('Thread 2')
	assert parse_gdb(primary, '/tmp/program').pcs == [u64(0x150), 0x180]
}
