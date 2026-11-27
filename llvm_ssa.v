module main

import json2
import os
import strconv
import strings

const llvm_trace_name = 'program.llvm-ssa.json'
const llvm_trace_directory = 'llvm-ssa'
const llvm_stream_limit = 4 * 1024 * 1024
const llvm_total_limit = 64 * 1024 * 1024
const llvm_default_functions = 'main,main__main'
const llvm_link_marker = '*** VGuard LLVM link-time optimization ***'

struct LlvmCapture {
	args      []string
	work      string
	compiler  string
	functions []string
}

struct LlvmTraceUnit {
	file      string
	source    string
	sha256    string
	exit_code int
	truncated bool @[omitempty]
}

struct LlvmTraceIndex {
	version   int = 1
	compiler  string
	functions []string
	units     []LlvmTraceUnit
	partial   bool @[omitempty]
}

struct LlvmDump {
	phase  string
	pass   string
	scope  string
	before bool
	line   int
	ir     string
}

struct LlvmCheckpoint {
	phase                     string
	pass                      string
	scope                     string
	before_line               int
	after_line                int
	before_sha256             string
	after_sha256              string
	added_instruction_lines   int
	removed_instruction_lines int
}

struct LlvmVerifiedUnit {
	file        string
	source      string
	checkpoints []LlvmCheckpoint
	unpaired    int
	truncated   bool @[omitempty]
}

struct LlvmVerification {
	evidence  string = 'clang_llvm_ir_pass_dumps'
	compiler  string
	functions []string
	units     []LlvmVerifiedUnit
	partial   bool @[omitempty]
}

fn llvm_function_names(raw string) ![]string {
	names := (if raw == '' { llvm_default_functions } else { raw }).split(',')
	if names.len > 16 || names.any(it == '' || !it.bytes().all(it.is_alnum() || it in [
		`_`,
		`.`,
		`$`,
		`-`,
	])) {
		return error('--ssa-function expects up to 16 comma-separated LLVM symbols')
	}
	return names
}

fn llvm_compiler(options BuildOptions) !string {
	mut selected := 'clang'
	for index, argument in options.args {
		if argument == '-cc' {
			if index + 1 >= options.args.len {
				return error('-cc requires a Clang executable')
			}
			selected = options.args[index + 1]
		}
	}
	return executable(selected)
}

fn prepare_llvm_capture(options BuildOptions, symbols string, work string) !LlvmCapture {
	if os.user_os() !in ['linux', 'macos'] || options.target.all_before('/') != os.user_os() {
		return error('C and FastC SSA tracing requires Clang on a matching Linux or macOS host')
	}
	functions := llvm_function_names(symbols)!
	clang := llvm_compiler(options)!
	version := capture(Command{ executable: clang, args: ['--version'], timeout_ms: 10000 })!
	lines := version.stdout.split_into_lines()
	if version.exit_code != 0 || version.status != 'exited' || lines.len == 0
		|| !lines[0].to_lower().contains('clang version') {
		return error('C and FastC --trace-ssa requires Clang as the C compiler')
	}
	directory := os.join_path(work, 'units')
	os.mkdir(directory)!
	launcher := os.join_path(work, 'clang')
	trace_linux_link := if os.user_os() == 'linux' { 1 } else { 0 }
	config := '#!/bin/sh\nclang=${shell_argument(clang)!}\ncapture_dir=${shell_argument(directory)!}\nfunctions=${shell_argument(functions.join(','))!}\ntrace_linux_link=${trace_linux_link}\n'
	os.write_file(launcher, config + $embed_file('compiler/clang_ssa_trace.sh').to_string())!
	os.chmod(launcher, 0o700)!
	return LlvmCapture{
		args:      ['-cc', launcher, '-nocache']
		work:      directory
		compiler:  lines[0]
		functions: functions
	}
}

struct LlvmCapturedStream {
	path string
	unit LlvmTraceUnit
}

fn (trace LlvmCapture) save(out string, partial bool) !string {
	mut streams := []LlvmCapturedStream{}
	mut total := u64(0)
	for name in os.ls(trace.work)! {
		job := os.join_path(trace.work, name)
		path := os.join_path(job, 'passes.log')
		if !os.is_file(path) {
			continue
		}
		size := os.file_size(path)
		total += size
		if size > llvm_stream_limit || total > llvm_total_limit {
			return error('LLVM pass logs exceeded the capture limit')
		}
		raw := os.read_file(path)!
		status := os.read_file(os.join_path(job, 'status')) or { '-1' }
		exit_code := strconv.atoi(status.trim_space())!
		truncated := os.is_file(os.join_path(job, 'truncated'))
		if parse_llvm_dumps(raw, !truncated && exit_code == 0).len == 0 {
			continue
		}
		streams << LlvmCapturedStream{
			path: path
			unit: LlvmTraceUnit{
				source:    os.read_file(os.join_path(job, 'source'))!.trim_space()
				sha256:    digest(raw.bytes())
				exit_code: exit_code
				truncated: truncated
			}
		}
	}
	if streams.len == 0 {
		return error('Clang produced no LLVM IR for the selected symbols. Check --ssa-function against the generated C names')
	}
	streams.sort_with_compare(fn (a &LlvmCapturedStream, b &LlvmCapturedStream) int {
		result := a.unit.source.compare(b.unit.source)
		return if result == 0 { a.unit.sha256.compare(b.unit.sha256) } else { result }
	})
	directory := os.join_path(out, llvm_trace_directory)
	os.mkdir(directory)!
	mut units := []LlvmTraceUnit{cap: streams.len}
	for ordinal, stream in streams {
		file := 'unit-${ordinal + 1}.log'
		os.cp(stream.path, os.join_path(directory, file))!
		units << LlvmTraceUnit{ ...stream.unit, file: file }
	}
	contents := json2.encode(LlvmTraceIndex{
		compiler:  trace.compiler
		functions: trace.functions
		units:     units
		partial:   partial || units.any(it.truncated || it.exit_code != 0)
	}, prettify: true) + '\n'
	os.write_file(os.join_path(out, llvm_trace_name), contents)!
	return digest(contents.bytes())
}

fn parse_llvm_dump_header(line string, number int) ?LlvmDump {
	header := line.trim_space().trim_string_left('; ')
	before_marker := '*** IR Dump Before '
	after_marker := '*** IR Dump After '
	before := header.starts_with(before_marker)
	if !before && !header.starts_with(after_marker) {
		return none
	}
	content := header[(if before { before_marker.len } else { after_marker.len })..]
	end := content.index(' ***') or { return none }
	description := content[..end]
	name := description.all_before(' on ')
	if name == '' {
		return none
	}
	return LlvmDump{
		pass:   name
		scope:  if description.contains(' on ') { description.all_after(' on ') } else { '' }
		before: before
		line:   number
	}
}

fn parse_llvm_dumps(raw string, complete bool) []LlvmDump {
	mut dumps := []LlvmDump{}
	mut header := ?LlvmDump(none)
	mut body := strings.new_builder(512)
	mut has_ir := false
	mut phase := 'compile'
	for index, line in raw.split_into_lines() {
		if line == llvm_link_marker || line.trim_left('#; ').starts_with('*** IR Dump ') {
			if previous := header {
				if has_ir {
					dumps << LlvmDump{ ...previous, ir: body.str() }
				}
			}
			if line == llvm_link_marker {
				phase = 'link_time'
				header = none
			} else if next := parse_llvm_dump_header(line, index + 1) {
				header = LlvmDump{ ...next, phase: phase }
			} else {
				header = none
			}
			body = strings.new_builder(512)
			has_ir = false
		} else if header != none {
			has_ir = has_ir || line.starts_with('define ') || line.starts_with('; ModuleID = ')
				|| line == '; Loop:'
			body.writeln(line)
		}
	}
	if complete {
		if previous := header {
			if has_ir {
				dumps << LlvmDump{ ...previous, ir: body.str() }
			}
		}
	}
	return dumps
}

fn llvm_instruction_line_counts(snapshot LlvmDump, functions []string) map[string]int {
	mut result := map[string]int{}
	mut function := ''
	for line in snapshot.ir.split_into_lines() {
		if line.starts_with('define ') {
			name := line.all_after('@').all_before('(').trim('"')
			function = if name in functions { name } else { '' }
		} else if line == '}' {
			function = ''
		} else if line == '; Loop:' && snapshot.scope.starts_with('Loop at depth ') {
			function = snapshot.scope
		} else if function != '' && line.starts_with('  ') && !line.starts_with('   ') {
			statement := line[2..]
			if statement != '' && !statement.starts_with(';') {
				result['${function}\x00${statement}']++
			}
		}
	}
	return result
}

fn llvm_checkpoint(before LlvmDump, after LlvmDump, functions []string) LlvmCheckpoint {
	mut added := 0
	mut removed := 0
	if before.ir != after.ir {
		old := llvm_instruction_line_counts(before, functions)
		new_lines := llvm_instruction_line_counts(after, functions)
		for line, count in new_lines {
			if count > old[line] {
				added += count - old[line]
			}
		}
		for line, count in old {
			if count > new_lines[line] {
				removed += count - new_lines[line]
			}
		}
	}
	return LlvmCheckpoint{
		phase:                     before.phase
		pass:                      before.pass
		scope:                     before.scope
		before_line:               before.line
		after_line:                after.line
		before_sha256:             digest(before.ir.bytes())
		after_sha256:              digest(after.ir.bytes())
		added_instruction_lines:   added
		removed_instruction_lines: removed
	}
}

fn verify_llvm_unit(unit LlvmTraceUnit, raw string, functions []string) LlvmVerifiedUnit {
	mut pending := map[string][]LlvmDump{}
	mut unpaired := 0
	mut checkpoints := []LlvmCheckpoint{}
	for snapshot in parse_llvm_dumps(raw, !unit.truncated && unit.exit_code == 0) {
		key := snapshot.phase + '\x00' + snapshot.pass + '\x00' + snapshot.scope
		mut chain := pending[key]
		if snapshot.before {
			chain << snapshot
		} else if chain.len == 0 {
			unpaired++
		} else {
			before := chain.pop()
			checkpoints << llvm_checkpoint(before, snapshot, functions)
		}
		pending[key] = chain
	}
	for _, chain in pending {
		unpaired += chain.len
	}
	return LlvmVerifiedUnit{
		file:        unit.file
		source:      unit.source
		checkpoints: checkpoints
		unpaired:    unpaired
		truncated:   unit.truncated
	}
}

fn read_llvm_verification(path string, expected string) !LlvmVerification {
	if os.file_size(path) > u64(capture_limit) {
		return error('LLVM pass index exceeds the input size limit')
	}
	contents := os.read_file(path)!
	if expected != '' && digest(contents.bytes()) != expected {
		return error('LLVM pass index SHA-256 does not match the build manifest')
	}
	index := json2.decode[LlvmTraceIndex](contents)!
	if index.version != 1 || index.compiler == '' || index.functions.len == 0 || index.units.len == 0 {
		return error('invalid LLVM pass index')
	}
	mut total := u64(0)
	mut verified := []LlvmVerifiedUnit{cap: index.units.len}
	for ordinal, unit in index.units {
		if unit.file != 'unit-${ordinal + 1}.log' || unit.source == '' || (!index.partial && (unit.exit_code != 0 || unit.truncated)) {
			return error('invalid LLVM pass stream metadata')
		}
		log := os.join_path(os.dir(path), llvm_trace_directory, unit.file)
		size := os.file_size(log)
		total += size
		if size == 0 || size > llvm_stream_limit || total > llvm_total_limit {
			return error('invalid LLVM pass stream size')
		}
		raw := os.read_file(log)!
		if digest(raw.bytes()) != unit.sha256 {
			return error('LLVM pass stream ${unit.file} does not match its SHA-256')
		}
		verified << verify_llvm_unit(unit, raw, index.functions)
	}
	return LlvmVerification{
		compiler:  index.compiler
		functions: index.functions
		units:     verified
		partial:   index.partial
	}
}

fn (bundle &Bundle) llvm_verification() !LlvmVerification {
	if bundle.manifest.llvm_ssa_sha256 == '' {
		return error('build with --trace-ssa and Clang to record LLVM pass dumps')
	}
	return read_llvm_verification(os.join_path(os.dir(bundle.ssa_path), llvm_trace_name), bundle.manifest.llvm_ssa_sha256)
}

fn format_llvm_verification(report LlvmVerification) string {
	mut output := strings.new_builder(512)
	output.writeln('LLVM IR pass dumps from ${report.compiler}')
	for unit in report.units {
		changed := unit.checkpoints.filter(it.before_sha256 != it.after_sha256)
		output.writeln('  ${unit.file} (${unit.source}) with ${unit.checkpoints.len} matched passes, ${changed.len} changes and ${unit.unpaired} unmatched dumps')
		for checkpoint in changed {
			output.writeln('    ${checkpoint.phase} ${checkpoint.pass} (${checkpoint.scope}) lines ${checkpoint.before_line}/${checkpoint.after_line}, +${checkpoint.added_instruction_lines} -${checkpoint.removed_instruction_lines} instruction lines')
		}
	}
	if report.partial {
		output.writeln('  = partial LLVM trace')
	}
	return output.str()
}
