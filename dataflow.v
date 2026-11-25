module main

import json2
import os
import strings

const max_dataflow_nodes = 128

struct SsaOperand {
	id   int
	role string
	kind string
}

struct SsaAst {
	node        int
	kind        string
	file        string
	line        int
	column      int
	source_file string
	start_byte  int
	end_byte    int
	copied_from ?int @[omitempty]
}

struct SsaInstruction {
	id       int
	block    int
	function string
	op       string
	typ      int
	operands []SsaOperand
	ast      ?SsaAst @[omitempty]
}

struct SsaBlock {
	id           int
	function     string
	instructions []int
	successors   []int
}

struct SsaGraph {
	version      int
	instructions []SsaInstruction
	blocks       []SsaBlock
}

struct SsaDependency {
	from        int
	to          int
	kind        string
	value_kind  string @[omitempty]
	predecessor ?int   @[omitempty]
}

struct SsaDataflow {
	root      int
	evidence  string = 'static_ssa_candidates'
	nodes     []SsaInstruction
	edges     []SsaDependency
	truncated bool
}

fn (bundle &Bundle) read_ssa_graph() !SsaGraph {
	if bundle.manifest.ssa_graph_sha256 == '' {
		return error('build with --trace-ssa to record the SSA graph')
	}
	path := bundle.ssa_path.trim_string_right('.ssa') + '.passes.jsonl.graph.json'
	if !os.is_file(path) {
		return error('the recorded SSA graph is missing')
	}
	if os.file_size(path) > u64(capture_limit * 4) {
		return error('the SSA graph exceeds the 64 MiB analysis limit')
	}
	data := os.read_bytes(path)!
	if digest(data) != bundle.manifest.ssa_graph_sha256 {
		return error('SSA graph SHA-256 does not match the build manifest')
	}
	graph := json2.decode[SsaGraph](data.bytestr())!
	if graph.version != 1 {
		return error('unsupported SSA graph version')
	}
	return graph
}

fn (bundle &Bundle) with_dataflow(report Diagnosis) Diagnosis {
	if report.kind !in ['crash', 'fuel_exhausted'] {
		return report
	}
	location := report.location or {
		return Diagnosis{ ...report, ssa_dataflow_error: 'no mapped SSA instruction for this stop' }
	}
	dataflow := bundle.dataflow_at(location) or {
		return Diagnosis{ ...report, ssa_dataflow_error: err.msg() }
	}
	return Diagnosis{ ...report, ssa_dataflow: dataflow }
}

fn (bundle &Bundle) dataflow_at(location Location) !SsaDataflow {
	if location.ssa_value < 0 || location.ssa_opcode == '' {
		return error('no mapped SSA instruction for this stop')
	}
	graph := bundle.read_ssa_graph()!
	return graph.backward(location)
}

fn (graph SsaGraph) backward(location Location) !SsaDataflow {
	mut instructions := map[int]SsaInstruction{}
	mut blocks := map[int]SsaBlock{}
	mut predecessors := map[int][]int{}
	mut definition_copies := map[int][]SsaInstruction{}
	for instruction in graph.instructions {
		instructions[instruction.id] = instruction
		for operand in instruction.operands {
			if operand.role == 'definition' {
				definition_copies[operand.id] << instruction
			}
		}
	}
	for block in graph.blocks {
		blocks[block.id] = block
		for successor in block.successors {
			predecessors[successor] << block.id
		}
	}
	root := instructions[location.ssa_value] or { return error('mapped SSA value is absent from the graph') }
	if root.op != location.ssa_opcode || (location.function != '' && root.function != location.function) {
		return error('mapped instruction does not match the SSA graph')
	}

	mut nodes := []SsaInstruction{}
	mut edges := []SsaDependency{}
	mut queued := {
		root.id: true
	}
	mut queue := [root.id]
	for index := 0; index < queue.len && nodes.len < max_dataflow_nodes; index++ {
		instruction := instructions[queue[index]]
		nodes << instruction
		mut upstream := []SsaDependency{}
		for i, operand in instruction.operands {
			if operand.role != 'use' {
				continue
			}
			mut predecessor := ?int(none)
			if instruction.op == 'phi' && i + 1 < instruction.operands.len
				&& instruction.operands[i + 1].role == 'block' {
				predecessor = instruction.operands[i + 1].id
			}
			upstream << SsaDependency{
				from:        instruction.id
				to:          operand.id
				kind:        if predecessor != none { 'phi_incoming' } else { 'operand' }
				value_kind:  operand.kind
				predecessor: predecessor
			}
			for copy in definition_copies[operand.id] {
				if copy.function == instruction.function {
					upstream << SsaDependency{
						from:        instruction.id
						to:          copy.id
						kind:        'lowered_phi_definition'
						predecessor: copy.block
					}
				}
			}
		}
		for predecessor in predecessors[instruction.block] {
			block := blocks[predecessor]
			if block.function != instruction.function || block.instructions.len == 0 {
				continue
			}
			terminator := instructions[block.instructions.last()]
			if terminator.op in ['br', 'switch_'] {
				upstream << SsaDependency{
					from:        instruction.id
					to:          terminator.id
					kind:        'predecessor_branch'
					predecessor: predecessor
				}
			}
		}
		for edge in upstream {
			edges << edge
			if edge.to in instructions && edge.to !in queued {
				queue << edge.to
				queued[edge.to] = true
			}
		}
	}
	return SsaDataflow{
		root:      root.id
		nodes:     nodes
		edges:     edges
		truncated: queue.len > nodes.len
	}
}

fn write_dataflow(mut out strings.Builder, report Diagnosis) {
	if analysis := report.ssa_dataflow {
		out.writeln('  = static SSA dependencies for %${analysis.root} (possible execution paths)')
		if analysis.nodes.len > 0 {
			if ast := analysis.nodes[0].ast {
				out.writeln('    AST node ${ast.node} (${ast.kind}) at ${ast.file}:${ast.line}:${ast.column}')
			}
		}
		for edge in analysis.edges {
			if edge.from == analysis.root {
				out.writeln('    %${edge.from} <- %${edge.to} (${edge.kind})')
			}
		}
		out.writeln('    ${analysis.nodes.len} instructions examined${if analysis.truncated {
			' (limited)'
		} else {
			''
		}}')
	}
	if report.ssa_dataflow_error != '' {
		out.writeln('  = note: SSA dataflow unavailable (${report.ssa_dataflow_error})')
	}
}
