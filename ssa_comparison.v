module main

import json2
import os
import strings

struct SsaPassChange {
	before SsaInstruction
	after  SsaInstruction
}

struct SsaPassRewrite {
	from int
	to   int
	user int
}

struct SsaVerifierFinding {
	severity    string
	message     string
	function    string
	function_id int
	block       int
	value       int
}

struct SsaPassRecord {
	version      int
	kind         string
	pass         string
	verifier_ran bool
	before_count int
	after_count  int
	created      []SsaInstruction
	removed      []SsaInstruction
	changed      []SsaPassChange
	rewrites     []SsaPassRewrite
	findings     []SsaVerifierFinding
}

struct SsaCheckpoint {
	instructions_before int
	instructions_after  int
	created             int
	removed             int
	changed             int
	rewrites            int
	verifier_ran        bool
	critical_findings   int
	advisory_findings   int
}

struct SsaCheckpointDifference {
	pass      string
	target    ?SsaCheckpoint @[omitempty]
	reference ?SsaCheckpoint @[omitempty]
}

struct SsaOpcodeDifference {
	function  string
	opcode    string
	target    int
	reference int
}

struct SsaComparison {
	evidence                   string = 'compiler_checkpoints'
	target_order               []string
	reference_order            []string
	checkpoint_differences     []SsaCheckpointDifference
	opcode_differences         []SsaOpcodeDifference
	first_function_differences []SsaFunctionDifference @[omitempty]
}

fn (bundle &Bundle) read_ssa_passes() ![]SsaPassRecord {
	if bundle.manifest.ssa_passes_sha256 == '' {
		return error('build with --trace-ssa to record optimization checkpoints')
	}
	path := bundle.ssa_path.trim_string_right('.ssa') + '.passes.jsonl'
	if !os.is_file(path) {
		return error('the recorded SSA pass log is missing')
	}
	if os.file_size(path) > u64(capture_limit * 4) {
		return error('the SSA pass log exceeds the 64 MiB analysis limit')
	}
	data := os.read_bytes(path)!
	if digest(data) != bundle.manifest.ssa_passes_sha256 {
		return error('SSA pass log SHA-256 does not match the build manifest')
	}
	return decode_ssa_passes(data.bytestr())
}

fn decode_ssa_passes(data string) ![]SsaPassRecord {
	mut passes := []SsaPassRecord{}
	mut names := map[string]bool{}
	mut instructions := 0
	for line in data.split_into_lines() {
		record := json2.decode[SsaPassRecord](line)!
		kind := if passes.len == 0 { 'baseline' } else { 'pass' }
		if record.version != 1 || record.kind != kind || record.pass == ''
			|| record.pass in names || record.before_count != instructions
			|| record.after_count < 0
			|| record.after_count != instructions + record.created.len - record.removed.len
			|| (!record.verifier_ran && record.findings.len != 0)
			|| record.findings.any(it.severity !in ['critical', 'advisory']) {
			return error('invalid SSA pass checkpoint at line ${passes.len + 1}')
		}
		passes << record
		names[record.pass] = true
		instructions = record.after_count
	}
	if passes.len == 0 {
		return error('the SSA pass log has no baseline')
	}
	return passes
}

fn (record SsaPassRecord) checkpoint() SsaCheckpoint {
	return SsaCheckpoint{
		instructions_before: record.before_count
		instructions_after:  record.after_count
		created:             record.created.len
		removed:             record.removed.len
		changed:             record.changed.len
		rewrites:            record.rewrites.len
		verifier_ran:        record.verifier_ran
		critical_findings:   record.findings.filter(it.severity == 'critical').len
		advisory_findings:   record.findings.filter(it.severity == 'advisory').len
	}
}

fn compare_checkpoints(target []SsaPassRecord, reference []SsaPassRecord) []SsaCheckpointDifference {
	mut remaining := map[string]SsaCheckpoint{}
	for record in reference {
		remaining[record.pass] = record.checkpoint()
	}
	mut differences := []SsaCheckpointDifference{}
	for record in target {
		current := record.checkpoint()
		expected := remaining[record.pass] or {
			differences << SsaCheckpointDifference{ pass: record.pass, target: current }
			continue
		}
		if current != expected {
			differences << SsaCheckpointDifference{
				pass:      record.pass
				target:    current
				reference: expected
			}
		}
		remaining.delete(record.pass)
	}
	for record in reference {
		if expected := remaining[record.pass] {
			differences << SsaCheckpointDifference{ pass: record.pass, reference: expected }
		}
	}
	return differences
}

fn (graph SsaGraph) opcode_counts() map[string]map[string]int {
	mut counts := map[string]map[string]int{}
	for instruction in graph.instructions {
		counts[instruction.function][instruction.op]++
	}
	return counts
}

fn compare_opcodes(target SsaGraph, reference SsaGraph) []SsaOpcodeDifference {
	left := target.opcode_counts()
	right := reference.opcode_counts()
	mut functions := map[string]bool{}
	for function, _ in left {
		functions[function] = true
	}
	for function, _ in right {
		functions[function] = true
	}
	mut differences := []SsaOpcodeDifference{}
	for function in functions.keys().sorted() {
		l_ops := left[function]
		r_ops := right[function]
		mut codes := map[string]bool{}
		for op, _ in l_ops {
			codes[op] = true
		}
		for op, _ in r_ops {
			codes[op] = true
		}
		for op in codes.keys().sorted() {
			if l_ops[op] != r_ops[op] {
				differences << SsaOpcodeDifference{
					function:  function
					opcode:    op
					target:    l_ops[op]
					reference: r_ops[op]
				}
			}
		}
	}
	return differences
}

fn compare_ssa(target Bundle, reference Bundle) !SsaComparison {
	left := target.read_verified_ssa_trace() or { return error('target: ${err.msg()}') }
	right := reference.read_verified_ssa_trace() or { return error('reference: ${err.msg()}') }
	return SsaComparison{
		target_order:               left.passes.map(it.pass)
		reference_order:            right.passes.map(it.pass)
		checkpoint_differences:     compare_checkpoints(left.passes, right.passes)
		opcode_differences:         compare_opcodes(left.graph, right.graph)
		first_function_differences: compare_function_structure(left.graph, right.graph)
	}
}

fn (report Comparison) with_ssa_comparison(target Bundle, reference Bundle) Comparison {
	if target.manifest.llvm_ssa_sha256 != '' || reference.manifest.llvm_ssa_sha256 != '' {
		result := compare_llvm_verifications(target.llvm_verification() or {
			return Comparison{ ...report, ssa_comparison_error: 'target: ${err.msg()}' }
		}, reference.llvm_verification() or {
			return Comparison{ ...report, ssa_comparison_error: 'reference: ${err.msg()}' }
		}) or {
			return Comparison{ ...report, ssa_comparison_error: err.msg() }
		}
		return Comparison{ ...report, llvm_ssa_comparison: result }
	}
	comparison := compare_ssa(target, reference) or {
		return Comparison{ ...report, ssa_comparison_error: err.msg() }
	}
	return Comparison{ ...report, ssa_comparison: comparison }
}

fn (checkpoint SsaCheckpoint) counts_text() string {
	return '${checkpoint.instructions_before} -> ${checkpoint.instructions_after}, created ${checkpoint.created}, removed ${checkpoint.removed}, changed ${checkpoint.changed}, rewrites ${checkpoint.rewrites}, verifier ${if checkpoint.verifier_ran {
		'${checkpoint.critical_findings} critical, ${checkpoint.advisory_findings} advisory'
	} else {
		'skipped'
	}}'
}

fn write_ssa_comparison(mut out strings.Builder, report Comparison) {
	if llvm := report.llvm_ssa_comparison {
		write_llvm_comparison(mut out, llvm)
	}
	if comparison := report.ssa_comparison {
		out.writeln('  = SSA differences from compiler checkpoints')
		out.writeln('    ${comparison.checkpoint_differences.len} changed or unmatched checkpoints')
		for difference in comparison.checkpoint_differences {
			out.writeln('    ${difference.pass}')
			if target := difference.target {
				out.writeln('      target ${target.counts_text()}')
			}
			if reference := difference.reference {
				out.writeln('      reference ${reference.counts_text()}')
			}
		}
		out.writeln('    ${comparison.opcode_differences.len} function/opcode count differences')
		end := if comparison.opcode_differences.len > 8 {
			8
		} else {
			comparison.opcode_differences.len
		}
		for difference in comparison.opcode_differences[..end] {
			out.writeln('    ${difference.function} ${difference.opcode} ${difference.target} / ${difference.reference} (target / reference)')
		}
		if end < comparison.opcode_differences.len {
			out.writeln('    See --json for the remaining count differences')
		}
		if comparison.first_function_differences.len > 0 {
			out.writeln('    ${comparison.first_function_differences.len} functions differ by block or instruction order')
			for i, difference in comparison.first_function_differences {
				if i == 8 {
					break
				}
				out.writeln('    ${difference.function} block ${difference.block}, ${difference.kind}')
				if target := difference.target {
					out.writeln('      target %${target.id} ${target.op} ${json2.encode(target.operands)}')
				}
				if reference := difference.reference {
					out.writeln('      reference %${reference.id} ${reference.op} ${json2.encode(reference.operands)}')
				}
			}
		}
	}
	if report.ssa_comparison_error != '' {
		out.writeln('  = note: SSA comparison unavailable (${report.ssa_comparison_error})')
	}
}
