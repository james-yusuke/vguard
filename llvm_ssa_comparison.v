module main

import strings

struct LlvmCheckpointDifference {
	unit          string
	phase         string
	pass          string
	scope         string
	occurrence    int
	target        ?LlvmCheckpoint @[omitempty]
	reference     ?LlvmCheckpoint @[omitempty]
	target_log    string          @[omitempty]
	reference_log string          @[omitempty]
}

struct LlvmComparison {
	evidence           string = 'clang_llvm_ir_pass_dumps'
	target_compiler    string
	reference_compiler string
	functions          []string
	target_passes      int
	reference_passes   int
	differences        []LlvmCheckpointDifference
}

fn llvm_checkpoints_by_occurrence(report LlvmVerification) !map[string]LlvmCheckpointDifference {
	mut checkpoints := map[string]LlvmCheckpointDifference{}
	mut sources := map[string]bool{}
	for unit in report.units {
		if unit.source in sources {
			return error('LLVM SSA comparison found multiple translation units named ${unit.source}')
		}
		sources[unit.source] = true
		mut occurrences := map[string]int{}
		for checkpoint in unit.checkpoints {
			key := checkpoint.phase + '\x00' + checkpoint.pass + '\x00' + checkpoint.scope
			occurrences[key]++
			occurrence := occurrences[key]
			checkpoints['${unit.source}\x00${key}\x00${occurrence}'] = LlvmCheckpointDifference{
				unit:       unit.source
				phase:      checkpoint.phase
				pass:       checkpoint.pass
				scope:      checkpoint.scope
				occurrence: occurrence
				target:     checkpoint
				target_log: unit.file
			}
		}
	}
	return checkpoints
}

fn compare_llvm_verifications(target LlvmVerification, reference LlvmVerification) !LlvmComparison {
	if target.partial || reference.partial {
		return error('LLVM SSA comparison requires complete captures')
	}
	if target.functions.sorted() != reference.functions.sorted() {
		return error('LLVM SSA comparison requires the same selected functions')
	}
	left := llvm_checkpoints_by_occurrence(target)!
	right := llvm_checkpoints_by_occurrence(reference)!
	mut differences := []LlvmCheckpointDifference{}
	for key in left.keys().sorted() {
		entry := left[key]
		if peer := right[key] {
			observed := entry.target or { return error('missing LLVM checkpoint') }
			prior := peer.target or { return error('missing reference LLVM checkpoint') }
			if observed.before_sha256 != prior.before_sha256 || observed.after_sha256 != prior.after_sha256 {
				differences << LlvmCheckpointDifference{ ...entry, reference: prior, reference_log: peer.target_log }
			}
		} else {
			differences << entry
		}
	}
	for key in right.keys().sorted() {
		if key !in left {
			entry := right[key]
			differences << LlvmCheckpointDifference{ ...entry, reference: entry.target, reference_log: entry.target_log, target: none, target_log: '' }
		}
	}
	return LlvmComparison{
		target_compiler:    target.compiler
		reference_compiler: reference.compiler
		functions:          target.functions
		target_passes:      left.len
		reference_passes:   right.len
		differences:        differences
	}
}

fn write_llvm_comparison(mut output strings.Builder, comparison LlvmComparison) {
	output.writeln('  = LLVM IR differences from Clang pass dumps')
	output.writeln('    ${comparison.differences.len} different or unmatched pass occurrences')
	for index, difference in comparison.differences {
		if index >= 12 {
			output.writeln('    See --json for all pass differences')
			break
		}
		output.writeln('    ${difference.unit} ${difference.phase} ${difference.pass} (${difference.scope}), occurrence ${difference.occurrence}')
	}
}
