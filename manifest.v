module main

import crypto.sha256
import json2
import os

const map_version = 1

struct RawRange {
	function string
	symbol   string
	body     int
	start    int
	end      int
	value    int
	op       string
	file     string
	line     int
	column   int
}

struct SourceMap {
	version    int
	format     string
	backend    string
	target_os  string
	arch       string
	revision   string
	sha256     string
	ssa_sha256 string
	ranges     []RawRange
}

struct BuildOptions {
	source   string
	compiler string
	backend  string
	target   string
	args     []string
	prod     bool
	object   bool
	hot_fn   string
}

struct Manifest {
	version         int = map_version
	options         BuildOptions
	artifact        string
	source_map      string
	compiler_sha256 string
	source_sha256   string
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
}

struct PlacedRange {
	section  int
	start    u64
	end      u64
	location Location
}

struct Bundle {
	manifest   Manifest
	artifact   string
	image      Image
	ranges     []PlacedRange
	ssa_path   string
	ssa_sha256 string
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

fn build(options BuildOptions, out string, trace bool) !string {
	target := options.target.split('/')
	if target.len != 2 || target[0] == '' || target[1] !in ['amd64', 'arm64', 'wasm32'] {
		return error('--target expects OS/amd64, OS/arm64 or wasm32_emscripten/wasm32')
	}
	if options.backend !in ['c', 'fastc', 'amd64', 'arm64', 'wasm'] {
		return error('invalid V backend: ${options.backend}')
	}
	source_sha256 := source_digest(options.source, out)!
	compiler_sha256 := digest(os.read_bytes(options.compiler)!)
	os.mkdir(out)!
	mut completed := false
	defer {
		if !completed {
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
	if options.object {
		args << '-is_o'
	}
	if options.hot_fn != '' {
		args << ['-hot-fn', options.hot_fn]
	}
	args << options.args
	args << options.source
	result := capture(Command{
		executable: options.compiler
		args:       args
		timeout_ms: 300000
	})!
	if result.status != 'exited' || result.exit_code != 0 {
		details := result.stdout + result.stderr
		if result.status == 'exited' && result.exit_code == 2 && details.contains(invalid_command) {
			return error('--v points to the VGuard executable (${options.compiler}). Pass the V compiler that supports -vguard-map.')
		}
		return error('V build failed (${result.status}, ${result.exit_code})\n${details}')
	}
	if source_digest(options.source, out)! != source_sha256 {
		return error('source changed during the build')
	}
	manifest := Manifest{
		options:         options
		artifact:        artifact
		source_map:      map_name
		source_sha256:   source_sha256
		compiler_sha256: compiler_sha256
	}
	read_bundle(manifest, out)!
	os.write_file(manifest_path, json2.encode(manifest, prettify: true) + '\n')!
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
	img := image(data, source_map.format)!
	if img.format != source_map.format {
		return error('source map format does not match the binary header')
	}
	return Bundle{
		manifest:   manifest
		artifact:   artifact
		image:      img
		ranges:     placed_ranges(img, source_map.ranges)!
		ssa_path:   map_path + '.ssa'
		ssa_sha256: source_map.ssa_sha256
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
		result << PlacedRange{
			section:  section.index
			start:    start + u64(entry.start)
			end:      start + u64(entry.end)
			location: Location{
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
