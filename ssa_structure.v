module main

struct SsaOperandSample {
	id        int
	role      string
	kind      string
	reference string @[omitempty]
	text      string @[omitempty]
}

struct SsaInstructionSample {
	id       int
	op       string
	atomic   string @[omitempty]
	inline   string @[omitempty]
	operands []SsaOperandSample
}

struct SsaFunctionDifference {
	function             string
	kind                 string
	block                int
	instruction          int                   @[omitempty]
	target               ?SsaInstructionSample @[omitempty]
	reference            ?SsaInstructionSample @[omitempty]
	target_successors    []int                 @[omitempty]
	reference_successors []int                 @[omitempty]
}

struct SsaStructure {
mut:
	functions    map[string][]SsaBlock
	blocks       map[int]int
	instructions map[int]SsaInstruction
	positions    map[int]string
}

fn index_ssa_structure(graph SsaGraph) SsaStructure {
	mut result := SsaStructure{}
	for block in graph.blocks {
		ordinal := result.functions[block.function].len
		result.functions[block.function] << block
		result.blocks[block.id] = ordinal
		for i, id in block.instructions {
			result.positions[id] = '${block.function}:${ordinal}:${i}'
		}
	}
	for instruction in graph.instructions {
		result.instructions[instruction.id] = instruction
	}
	return result
}

fn (graph &SsaStructure) sample(id int) SsaInstructionSample {
	instruction := graph.instructions[id]
	mut operands := []SsaOperandSample{cap: instruction.operands.len}
	for operand in instruction.operands {
		reference := if operand.role == 'block' {
			if index := graph.blocks[operand.id] { 'block ${index}' } else { '' }
		} else {
			graph.positions[operand.id]
		}
		operands << SsaOperandSample{
			id:        operand.id
			role:      operand.role
			kind:      operand.kind
			reference: reference
			text:      operand.text
		}
	}
	return SsaInstructionSample{
		id:       instruction.id
		op:       instruction.op
		atomic:   if instruction.atomic == 'not_atomic' { '' } else { instruction.atomic }
		inline:   if instruction.inline == 'none_' { '' } else { instruction.inline }
		operands: operands
	}
}

fn same_instruction_shape(target SsaInstructionSample, reference SsaInstructionSample) bool {
	if target.op != reference.op || target.atomic != reference.atomic || target.inline != reference.inline
		|| target.operands.len != reference.operands.len {
		return false
	}
	for i, left in target.operands {
		right := reference.operands[i]
		if left.role != right.role || left.kind != right.kind || left.reference != right.reference
			|| (left.text != '' && right.text != '' && left.text != right.text) {
			return false
		}
	}
	return true
}

fn first_function_difference(target &SsaStructure, reference &SsaStructure, name string) ?SsaFunctionDifference {
	left := target.functions[name]
	right := reference.functions[name]
	for b := 0; b < left.len || b < right.len; b++ {
		if b == left.len || b == right.len {
			return SsaFunctionDifference{ function: name, block: b, kind: 'block_count' }
		}
		target_successors := left[b].successors.map(target.blocks[it] or { -1 })
		reference_successors := right[b].successors.map(reference.blocks[it] or { -1 })
		if target_successors != reference_successors {
			return SsaFunctionDifference{
				function:             name
				block:                b
				kind:                 'successors'
				target_successors:    target_successors
				reference_successors: reference_successors
			}
		}
		ls := left[b].instructions
		rs := right[b].instructions
		for i := 0; i < ls.len || i < rs.len; i++ {
			l := if i < ls.len { ?SsaInstructionSample(target.sample(ls[i])) } else { none }
			r := if i < rs.len { ?SsaInstructionSample(reference.sample(rs[i])) } else { none }
			if a := l {
				if b_sample := r {
					if same_instruction_shape(a, b_sample) {
						continue
					}
				}
			}
			return SsaFunctionDifference{
				function:    name
				block:       b
				instruction: i + 1
				kind:        'instruction'
				target:      l
				reference:   r
			}
		}
	}
	return none
}

fn compare_function_structure(target SsaGraph, reference SsaGraph) []SsaFunctionDifference {
	left := index_ssa_structure(target)
	right := index_ssa_structure(reference)
	mut names := map[string]bool{}
	for name, _ in left.functions {
		names[name] = true
	}
	for name, _ in right.functions {
		names[name] = true
	}
	mut differences := []SsaFunctionDifference{}
	for name in names.keys().sorted() {
		if difference := first_function_difference(&left, &right, name) {
			differences << difference
		}
	}
	return differences
}
