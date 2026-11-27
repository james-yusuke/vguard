module main

import crypto.sha256
import json2
import os
import time

const map_version = 1

struct RawRange {
	function        string
	symbol          string
	body            int
	start           int
	end             int
	value           int
	op              string
	file            string
	line            int
	column          int
	recovery_prefix int                 @[omitempty]
	return_home     ?NativeReturnHome   @[omitempty]
	control_homes   ?NativeControlHomes @[omitempty]
}

struct NativeControlHomes {
	prefix_through    int
	alternate_start   int @[omitempty]
	alternate_through int @[omitempty]
}

struct NativeReturnHome {
	value    int
	bytes    int
	register string
}

struct SourceMap {
	version       int
	format        string
	backend       string
	target_os     string
	arch          string
	revision      string
	sha256        string
	ssa_sha256    string
	ranges        []RawRange
	native_homes  ?[]NativeValueHome @[omitempty]
	native_memory bool               @[omitempty]
}

struct BuildOptions {
	source        string
	compiler      string
	backend       string
	target        string
	args          []string
	prod          bool
	memory        bool @[omitempty]
	wasm_heap     bool @[omitempty]
	trace_hangs   bool @[omitempty]
	trace_runtime bool @[omitempty]
	object        bool
	hot_fn        string
}

struct Manifest {
	version           int = map_version
	options           BuildOptions
	artifact          string
	source_map        string
	compiler_sha256   string
	source_sha256     string
	ssa_passes_sha256 string @[omitempty]
	ssa_graph_sha256  string @[omitempty]
	llvm_ssa_sha256   string @[omitempty]
}

struct Location {
pub:
	function   string
	file       string
	line       int
	column     int
	ssa_opcode string
	ssa_value  int = -1
	precision  string
	machine    ?MachineMapping @[omitempty]
}

struct PlacedRange {
	section         int
	start           u64
	end             u64
	function_start  u64
	recovery_prefix int
	return_home     ?NativeReturnHome
	control_homes   ?NativeControlHomes
	location        Location
}

struct Bundle {
	manifest        Manifest
	artifact        string
	artifact_sha256 string
	image           Image
	ranges          []PlacedRange
	native_homes    ?[]NativeValueHome
	ssa_path        string
	ssa_sha256      string
}

fn digest(data []u8) string {
	return sha256.sum256(data).hex()
}

fn source_digest(path string, out string) !string {
	if os.is_file(path) {
		return digest(os.read_bytes(path)!)
	}
	if !os.is_dir(path) {
		return error('source does not exist: ${path}')
	}
	mut files := []string{}
	mut problems := []string{}
	output_path := os.real_path(out)
	os.walk_dir(path, fn [mut files, mut problems, output_path] (file string, entry os.WalkDirEntry) os.WalkDirAction {
		if entry.is_dir && (file == output_path || entry.name == '.git') {
			return .skip_dir
		}
		if err := entry.err {
			problems << err.msg()
		} else if !entry.is_dir && (os.file_ext(file) in ['.v', '.vh', '.c', '.h'] || entry.name == 'v.mod') {
			files << file
		}
		return .proceed
	})!
	if problems.len != 0 {
		return error('could not fingerprint the build inputs: ' + problems[0])
	}
	files.sort()
	mut hashes := []string{cap: files.len}
	for file in files {
		hashes << file + '\x00' + digest(os.read_bytes(file)!)
	}
	return digest(hashes.join('\x00').bytes())
}

fn artifact_name(options BuildOptions) string {
	if options.hot_fn != '' {
		return 'program.code'
	}
	if options.object {
		return 'program.o'
	}
	if options.args.any(it in ['-shared', '--shared']) {
		return match options.target.all_before('/') {
			'windows' { 'program.dll' }
			'macos' { 'program.dylib' }
			else { 'program.so' }
		}
	}
	return match options.target.all_before('/') {
		'windows' { 'program.exe' }
		'wasm32_emscripten' { 'program.wasm' }
		else { 'program' }
	}
}

@[params]
struct BuildOutput {
	trace_build  bool
	trace_ssa    bool
	trace_calls  bool
	ssa_function string
}

fn build(options BuildOptions, out string, trace bool, output BuildOutput) !string {
	trace_ssa := output.trace_ssa || options.trace_runtime
	target := options.target.split('/')
	if target.len != 2 || target[0] == '' || target[1] !in ['amd64', 'arm64', 'wasm32'] {
		return error('--target expects OS/amd64, OS/arm64 or wasm32_emscripten/wasm32')
	}
	if options.backend !in ['c', 'fastc', 'amd64', 'arm64', 'wasm'] {
		return error('invalid V backend: ${options.backend}')
	}
	if output.trace_build && options.backend !in ['amd64', 'arm64'] {
		return error('--trace-build requires the amd64 or arm64 native backend')
	}
	llvm_trace := output.trace_ssa && options.backend in ['c', 'fastc']
	if output.ssa_function != '' && !llvm_trace {
		return error('--ssa-function requires --trace-ssa with the C or FastC backend')
	}
	if options.trace_hangs && (options.backend != 'c' || target[0] !in ['linux', 'macos']
		|| options.memory || options.object || options.hot_fn != ''
		|| options.args.any(it in ['-shared', '--shared'])) {
		return error('--trace-hangs requires a standalone C backend executable on Linux or macOS')
	}
	memory_args := if options.memory { memory_compiler_args(options)! } else { []string{} }
	runtime_work := if options.trace_runtime { temp_directory()! } else { '' }
	llvm_work := if llvm_trace { temp_directory()! } else { '' }
	defer {
		if runtime_work != '' {
			os.rmdir_all(runtime_work) or {}
		}
		if llvm_work != '' {
			os.rmdir_all(llvm_work) or {}
		}
	}
	llvm_capture := if llvm_trace {
		prepare_llvm_capture(options, output.ssa_function, llvm_work)!
	} else {
		LlvmCapture{}
	}
	runtime_args := if options.trace_runtime {
		runtime_ssa_compiler_args(options, runtime_work)!
	} else {
		[]string{}
	}
	source_sha256 := source_digest(options.source, out)!
	compiler_sha256 := digest(os.read_bytes(options.compiler)!)
	os.mkdir(out)!
	mut completed := false
	mut trace_saved := false
	defer {
		if !completed && !trace_saved {
			os.rmdir_all(out) or {}
		}
	}
	artifact := artifact_name(options)
	map_name := 'program.vgmap.json'
	manifest_path := os.join_path(out, 'build.json')
	mut args := ['-b', options.backend, '-os', target[0], '-arch', target[1], '-vguard-map',
		os.join_path(out, map_name), '-o', os.join_path(out, artifact)]
	if options.prod {
		args << '-prod'
	}
	if trace {
		args << '-vguard-trace'
	}
	if output.trace_calls {
		args << '-vguard-trace-calls'
	}
	if options.trace_hangs {
		args << '-vguard-trace-hangs'
	}
	if trace_ssa && !llvm_trace {
		args << '-vguard-ssa-analysis'
	}
	if options.object {
		args << '-is_o'
	}
	if options.hot_fn != '' {
		args << ['-hot-fn', options.hot_fn]
	}
	args << options.args
	args << memory_args
	args << runtime_args
	args << llvm_capture.args
	if output.trace_build {
		args << '-show-timings'
		eprintln('VGuard: tracing ${options.backend} compilation for ${options.target}')
	}
	args << options.source
	elapsed := time.new_stopwatch()
	result := capture(Command{
		executable:        options.compiler
		args:              args
		timeout_ms:        300000
		forward_to_stderr: output.trace_build
	}) or {
		if !output.trace_build {
			return err
		}
		eprintln(err.msg())
		Outcome{
			exit_code: -1
			status:    'start_error'
			stderr:    err.msg() + '\n'
		}
	}
	if output.trace_build {
		save_compile_trace(options, out, result, elapsed.elapsed().milliseconds())!
		trace_saved = true
	}
	if result.status != 'exited' || result.exit_code != 0 {
		if llvm_trace {
			if _ := llvm_capture.save(out, true) {
				trace_saved = true
				eprintln('VGuard: partial LLVM pass dumps saved in ${out}')
			}
		}
		if trace_ssa && os.is_file(os.join_path(out, map_name + '.passes.jsonl')) {
			// A compiler failure can leave complete checkpoints worth retaining.
			trace_saved = true
			eprintln('VGuard: SSA checkpoints saved in ${out}')
		}
		details := result.stdout + result.stderr
		if result.status == 'exited' && result.exit_code == 2 && details.contains(invalid_command) {
			return error('--v points to the VGuard executable (${options.compiler}). Pass the V compiler that supports -vguard-map.')
		}
		if output.trace_build {
			return error('V build failed (${result.status}, ${result.exit_code}). Compiler logs are in ${out}.')
		}
		return error('V build failed (${result.status}, ${result.exit_code})\n${details}')
	}
	if source_digest(options.source, out)! != source_sha256 {
		return error('source changed during the build')
	}
	mut passes_sha256 := ''
	mut graph_sha256 := ''
	if trace_ssa && !llvm_trace {
		passes := os.join_path(out, map_name + '.passes.jsonl')
		if !os.is_file(passes) || !os.is_file(passes + '.graph.json') {
			return error('the target compiler did not produce the SSA analysis files')
		}
		passes_sha256 = digest(os.read_bytes(passes)!)
		graph_sha256 = digest(os.read_bytes(passes + '.graph.json')!)
	}
	manifest := Manifest{
		options:           options
		artifact:          artifact
		source_map:        map_name
		source_sha256:     source_sha256
		compiler_sha256:   compiler_sha256
		ssa_passes_sha256: passes_sha256
		ssa_graph_sha256:  graph_sha256
		llvm_ssa_sha256:   if llvm_trace { llvm_capture.save(out, false)! } else { '' }
	}
	read_bundle(manifest, out)!
	os.write_file(manifest_path, json2.encode(manifest, prettify: true) + '\n') or {
		os.rm(manifest_path) or {}
		return err
	}
	completed = true
	return manifest_path
}

fn open_bundle(manifest_path string) !Bundle {
	manifest := json2.decode[Manifest](os.read_file(manifest_path)!)!
	return read_bundle(manifest, os.dir(os.abs_path(manifest_path)))
}

fn read_bundle(manifest Manifest, directory string) !Bundle {
	if manifest.version != map_version {
		return error('unsupported build manifest version ${manifest.version}')
	}
	if manifest.artifact == '' || manifest.source_map == ''
		|| manifest.artifact != os.file_name(manifest.artifact)
		|| manifest.source_map != os.file_name(manifest.source_map) {
		return error('expected artifact and map filenames in the build manifest')
	}
	artifact := os.real_path(os.join_path(directory, manifest.artifact))
	data := os.read_bytes(artifact)!
	map_path := os.join_path(directory, manifest.source_map)
	source_map := json2.decode[SourceMap](os.read_file(map_path)!)!
	if source_map.version != map_version || source_map.sha256 != digest(data) {
		return error('the source map version or artifact SHA-256 does not match')
	}
	if source_map.backend != manifest.options.backend
		|| source_map.target_os + '/' + source_map.arch != manifest.options.target {
		return error('source map target or backend does not match the build manifest')
	}
	if manifest.options.backend in ['amd64', 'arm64'] && manifest.options.memory != source_map.native_memory {
		return error('source map and build manifest disagree about native memory checks')
	}
	img := image(data, source_map.format)!
	if img.format != source_map.format {
		return error('source map format does not match the binary header')
	}
	ranges := placed_ranges(img, source_map.ranges)!
	if manifest.options.wasm_heap {
		validate_wasm_heap_ranges(manifest.options, img, ranges, data)!
	}
	return Bundle{
		manifest:        manifest
		artifact:        artifact
		artifact_sha256: source_map.sha256
		image:           img
		ranges:          ranges
		native_homes:    source_map.native_homes
		ssa_path:        map_path + '.ssa'
		ssa_sha256:      source_map.ssa_sha256
	}
}

fn placed_ranges(img Image, entries []RawRange) ![]PlacedRange {
	mut result := []PlacedRange{cap: entries.len}
	for entry in entries {
		mut section := Section{}
		mut start := u64(0)
		match img.format {
			'wasm' {
				section = img.section(entry.body)!
			}
			'raw-arm64' {
				section = img.section(1)!
			}
			else {
				symbol := img.symbols[entry.symbol] or {
					return error('emitted function symbol ${entry.symbol} is missing from the binary')
				}
				section = img.section(symbol.section)!
				if symbol.address < section.address {
					return error('function symbol lies before the executable section')
				}
				start = symbol.address - section.address
			}
		}
		if entry.start < 0 || entry.end <= entry.start || start > section.size
			|| u64(entry.end) > section.size - start {
			return error('invalid machine-code range in ${entry.function}')
		}
		if entry.recovery_prefix < 0 || entry.recovery_prefix >= entry.end - entry.start
			|| (entry.recovery_prefix > 0 && entry.op != 'ret') {
			return error('invalid frame recovery range in ${entry.function}')
		}
		if returned := entry.return_home {
			if entry.op != 'ret' || returned.value <= 0 || returned.bytes !in [1, 2, 4, 8]
				|| returned.register !in ['rax', 'x0', 's0', 'd0']
				|| (returned.register == 's0' && returned.bytes != 4)
				|| (returned.register == 'd0' && returned.bytes != 8) {
				return error('invalid native return home in ${entry.function}')
			}
		}
		if control := entry.control_homes {
			length := entry.end - entry.start
			if entry.op !in ['br', 'switch_'] || control.prefix_through <= 0
				|| control.prefix_through > length
				|| (control.alternate_start == 0 && control.alternate_through != 0)
				|| (control.alternate_start != 0 && (entry.op != 'br'
					|| control.alternate_start <= control.prefix_through
					|| control.alternate_start >= length
					|| control.alternate_through < control.alternate_start
					|| control.alternate_through > length)) {
				return error('invalid stable control-flow homes in ${entry.function}')
			}
		}
		result << PlacedRange{
			section:         section.index
			start:           start + u64(entry.start)
			end:             start + u64(entry.end)
			function_start:  start
			recovery_prefix: entry.recovery_prefix
			return_home:     entry.return_home
			control_homes:   entry.control_homes
			location:        Location{
				function:   entry.function
				file:       entry.file
				line:       entry.line
				column:     entry.column
				ssa_value:  entry.value
				ssa_opcode: entry.op
				precision:  if entry.file == '' { 'ssa' } else { 'source_span' }
			}
		}
	}
	result.sort_with_compare(fn (a &PlacedRange, b &PlacedRange) int {
		if a.section != b.section {
			return a.section - b.section
		}
		return if a.start < b.start {
			-1
		} else if a.start > b.start {
			1
		} else {
			0
		}
	})
	for i in 1 .. result.len {
		p := result[i - 1]
		r := result[i]
		if p.section == r.section && p.end > r.start {
			return error('overlapping machine-code ranges in source map')
		}
	}
	return result
}

fn (bundle &Bundle) match_range(section int, offset u64) ?Location {
	mut lo := 0
	mut hi := bundle.ranges.len
	for lo < hi {
		mid := (lo + hi) / 2
		r := bundle.ranges[mid]
		if r.section < section || (r.section == section && r.end <= offset) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < bundle.ranges.len {
		r := bundle.ranges[lo]
		if r.section == section && r.start <= offset {
			return r.location
		}
	}
	return none
}
