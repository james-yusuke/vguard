module main

import json2
import os

fn test_llvm_dump_reader_pairs_repeated_passes_and_excludes_machine_ir() {
	raw := '; *** IR Dump Before ModulePass on [module] ***
define i32 @work(i32 %value) {
  %result = add i32 %value, 0
  ret i32 %result
}
*** IR Dump Before SimplifyPass on work ***
define i32 @work(i32 %value) {
  %result = add i32 %value, 0
  ret i32 %result
}
*** IR Dump After SimplifyPass on work ***
define i32 @work(i32 %value) {
  ret i32 %value
}
*** IR Dump After ModulePass on [module] ***
define i32 @work(i32 %value) {
  ret i32 %value
}
*** IR Dump After SimplifyPass on unrelated ***
define i32 @unrelated(i32 %value) {
  ret i32 %value
}
# *** IR Dump After instruction selection ***:
# Machine code for function work:
  RET
*** VGuard LLVM link-time optimization ***
*** IR Dump Before ModulePass on [module] ***
define i32 @work(i32 %value) {
  ret i32 %value
}
*** IR Dump After ModulePass on [module] ***
define i32 @work(i32 %value) {
  ret i32 %value
}
'
	unit := verify_llvm_unit(LlvmTraceUnit{ file: 'unit-1.log' }, raw, ['work'])
	assert unit.unpaired == 1
	assert unit.checkpoints.map(it.pass) == ['SimplifyPass', 'ModulePass', 'ModulePass']
	assert unit.checkpoints.map(it.phase) == ['compile', 'compile', 'link_time']
	assert unit.checkpoints[0].added_instruction_lines == 1
	assert unit.checkpoints[0].removed_instruction_lines == 2
	assert unit.checkpoints[0].before_sha256 != unit.checkpoints[0].after_sha256
	assert unit.checkpoints[1].before_line < unit.checkpoints[0].before_line
	truncated := verify_llvm_unit(LlvmTraceUnit{ file: 'unit-1.log', truncated: true }, raw,
		['work'])
	assert truncated.checkpoints.len == 2 && truncated.unpaired == 2
}

fn test_real_clang_ssa_dumps_from_c_and_fastc() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	if compiler == '' || os.user_os() != 'linux' || arch == '' {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	file := os.join_path(dir, 'input.v')
	os.write_file(file, 'module main

@[noinline]
fn compute(value int) int {
	mut result := value
	result *= 3
	return result + 1
}

fn main() {
	println(compute(7))
}
') or { panic(err) }
	mut reference := ?LlvmVerification(none)
	for backend in ['c', 'fastc'] {
		options := BuildOptions{
			source:   file
			compiler: os.real_path(compiler)
			target:   os.user_os() + '/' + arch
			backend:  backend
			args:     ['-cc', 'clang', '-gc', 'none']
			prod:     true
		}
		path := build(options, os.join_path(dir, backend), false,
			trace_ssa:    true
			ssa_function: 'compute,main__compute'
		) or { panic('${backend}: ${err.msg()}') }
		bundle := open_bundle(path) or { panic(err) }
		assert bundle.manifest.llvm_ssa_sha256.len == 64
		assert bundle.manifest.ssa_passes_sha256 == ''
		outcome := run_for_comparison(bundle, ExecutionCase{}) or { panic(err) }
		assert outcome.exit_code == 0 && outcome.stdout == '22\n'
		observed := bundle.llvm_verification() or { panic(err) }
		assert observed.compiler.to_lower().contains('clang version')
		assert observed.functions == ['compute', 'main__compute']
		assert !observed.partial
		assert observed.units.any(it.checkpoints.any(it.scope in ['compute', 'main__compute']
			&& it.before_sha256 != it.after_sha256 && it.removed_instruction_lines > 0)), '${backend}: ${json2.encode(observed)}'
		if other := reference {
			comparison := compare_llvm_verifications(observed, other) or { panic(err) }
			assert comparison.evidence == 'clang_llvm_ir_pass_dumps'
			assert comparison.target_passes > 0 && comparison.reference_passes > 0
		} else {
			reference = observed
		}
		log := os.join_path(dir, backend, llvm_trace_directory, observed.units[0].file)
		os.write_file(log, 'modified') or { panic(err) }
		bundle.llvm_verification() or {
			assert err.msg().contains('SHA-256')
			continue
		}
		assert false
	}
	options := BuildOptions{
		source:   file
		compiler: os.real_path(compiler)
		target:   os.user_os() + '/' + arch
		backend:  'c'
		args:     ['-cc', 'clang', '-gc', 'none']
	}
	legacy := build(options, os.join_path(dir, 'legacy'), false) or { panic(err) }
	assert !(os.read_file(legacy) or { panic(err) }).contains('"llvm_ssa_sha256"')
	assert !os.exists(os.join_path(dir, 'legacy', llvm_trace_name))
}
