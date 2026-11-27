module main

import os
import strings

struct VerifiedSsaTrace {
	passes []SsaPassRecord
	graph  SsaGraph
}

struct VerifiedCheckpoint {
	pass         string
	verifier_ran bool
	findings     []SsaVerifierFinding
}

struct SsaVerificationReport {
	evidence           string = 'compiler_checkpoints_and_log_replay'
	final_instructions int
	critical_findings  int
	advisory_findings  int
	checkpoints        []VerifiedCheckpoint
	last_checkpoint    string @[omitempty]
}

fn (bundle &Bundle) read_verified_ssa_trace() !VerifiedSsaTrace {
	passes := bundle.read_ssa_passes()!
	graph := bundle.read_ssa_graph()!
	check_ssa_log_replay(passes, graph)!
	return VerifiedSsaTrace{ passes: passes, graph: graph }
}

fn replay_ssa_passes(passes []SsaPassRecord) !map[int]SsaInstruction {
	mut state := map[int]SsaInstruction{}
	for checkpoint in passes {
		for instruction in checkpoint.removed {
			current := state[instruction.id] or {
				return error('SSA checkpoint ${checkpoint.pass} removed an absent instruction %${instruction.id}')
			}
			if current != instruction {
				return error('SSA checkpoint ${checkpoint.pass} removal does not match %${instruction.id}')
			}
			state.delete(instruction.id)
		}
		for change in checkpoint.changed {
			current := state[change.before.id] or {
				return error('SSA checkpoint ${checkpoint.pass} changed an absent instruction %${change.before.id}')
			}
			if change.before.id != change.after.id || current != change.before {
				return error('SSA checkpoint ${checkpoint.pass} change does not match %${change.before.id}')
			}
			state[change.after.id] = change.after
		}
		for instruction in checkpoint.created {
			if instruction.id in state {
				return error('SSA checkpoint ${checkpoint.pass} re-created live instruction %${instruction.id}')
			}
			state[instruction.id] = instruction
		}
		if state.len != checkpoint.after_count {
			return error('SSA checkpoint ${checkpoint.pass} instruction count does not match its edits')
		}
	}
	return state
}

fn check_ssa_log_replay(passes []SsaPassRecord, graph SsaGraph) ! {
	mut state := replay_ssa_passes(passes)!
	if state.len != graph.instructions.len {
		return error('the SSA pass log does not match the final graph size')
	}
	for instruction in graph.instructions {
		replayed := state[instruction.id] or {
			return error('final SSA instruction %${instruction.id} is missing from the pass log')
		}
		if replayed != instruction {
			return error('final SSA instruction %${instruction.id} differs from the pass log')
		}
		state.delete(instruction.id)
	}
}

fn (trace VerifiedSsaTrace) verification_report() SsaVerificationReport {
	mut checkpoints := []VerifiedCheckpoint{cap: trace.passes.len}
	mut critical := 0
	mut advisory := 0
	for checkpoint in trace.passes {
		checkpoints << VerifiedCheckpoint{
			pass:         checkpoint.pass
			verifier_ran: checkpoint.verifier_ran
			findings:     checkpoint.findings
		}
		for finding in checkpoint.findings {
			match finding.severity {
				'critical' { critical++ }
				'advisory' { advisory++ }
				else {}
			}
		}
	}
	return SsaVerificationReport{
		final_instructions: trace.graph.instructions.len
		critical_findings:  critical
		advisory_findings:  advisory
		checkpoints:        checkpoints
	}
}

fn read_partial_ssa_verification(path string) !SsaVerificationReport {
	if os.file_size(path) > u64(capture_limit * 4) {
		return error('the SSA pass log exceeds the 64 MiB analysis limit')
	}
	text := os.read_file(path)!
	end := text.last_index('\n') or { return error('the partial SSA log has no complete checkpoint') }
	passes := decode_ssa_passes(text[..end + 1])!
	state := replay_ssa_passes(passes)!
	report := VerifiedSsaTrace{ passes: passes }.verification_report()
	return SsaVerificationReport{
		...report
		evidence:           'partial_compiler_checkpoint_replay'
		final_instructions: state.len
		last_checkpoint:    passes.last().pass
	}
}

fn format_ssa_verification(report SsaVerificationReport) string {
	mut out := strings.new_builder(256)
	if report.last_checkpoint == '' {
		out.writeln('SSA trace replay matched ${report.final_instructions} final instructions')
	} else {
		out.writeln('Partial SSA trace replay reached ${report.last_checkpoint} with ${report.final_instructions} instructions')
	}
	out.writeln('Compiler verifier findings ${report.critical_findings} critical, ${report.advisory_findings} advisory')
	for checkpoint in report.checkpoints {
		status := if checkpoint.verifier_ran { 'compiler verifier ran' } else { 'verifier skipped' }
		out.writeln('  ${checkpoint.pass} (${status})')
		for finding in checkpoint.findings {
			site := if finding.function != '' { ' in ${finding.function}' } else { '' }
			out.writeln('    ${finding.severity}${site} %${finding.value} ${finding.message}')
		}
	}
	return out.str()
}
