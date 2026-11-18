module main

import json2
import os
import strconv

struct DebugSymbol {
	function_name string @[json: 'FunctionName']
	file_name     string @[json: 'FileName']
	line          int    @[json: 'Line']
}

struct DebugResponse {
	symbol []DebugSymbol @[json: 'Symbol']
}

fn hex_address(address u64) string {
	return '0x' + address.hex()
}

fn parse_address(s string) !u64 {
	if s.starts_with('0x') || s.starts_with('0X') {
		return strconv.parse_uint(s[2..], 16, 64)
	}
	return strconv.parse_uint(s, 10, 64)
}

fn (bundle &Bundle) resolve_address(address u64) !Location {
	if bundle.image.relocatable {
		if bundle.image.format == 'raw-arm64' {
			return bundle.resolve_section(1, address)
		}
		return error('object files require a section index and an offset')
	}
	for section in bundle.image.sections {
		if address >= section.address && address - section.address < section.size {
			return bundle.resolve_section(section.index, address - section.address)
		}
	}
	return error('address ${hex_address(address)} is outside the executable sections')
}

fn (bundle &Bundle) resolve_section(index int, offset u64) !Location {
	section := bundle.image.section(index)!
	if offset >= section.size {
		return error('offset ${hex_address(offset)} is outside section ${index} (${section.name})')
	}
	if location := bundle.match_range(index, offset) {
		return location
	}
	if bundle.ranges.len > 0 || bundle.image.format == 'raw-arm64' {
		return error('no SSA range for this instruction')
	}
	if bundle.image.relocatable && bundle.image.sections.any(it.index != index
		&& it.address == section.address && offset < it.size) {
		return error('the debug address overlaps more than one executable object section')
	}
	if offset > u64(-1) - section.address {
		return error('address overflows the executable section')
	}
	address := section.address + offset
	if bundle.image.format == 'wasm' {
		// DWARF addresses are relative to the code section payload.
		return bundle.debug_location(address - bundle.image.wasm_code_offset)
	}
	return bundle.debug_location(address)
}

fn (bundle &Bundle) debug_location(address u64) !Location {
	path := executable('llvm-symbolizer') or {
		return error('llvm-symbolizer is required to read C or FastC debug information')
	}
	mut artifact := bundle.artifact
	if bundle.image.format == 'macho' && !bundle.image.relocatable {
		artifact = bundle.macho_debug_object()!
	}
	mut args := ['--no-debuginfod', '--output-style=JSON', '--obj=' + artifact]
	if bundle.image.format == 'coff' && !bundle.image.relocatable {
		args << '--relative-address'
	}
	args << hex_address(address)
	output := capture(Command{ executable: path, args: args })!
	if output.exit_code != 0 || output.status != 'exited' {
		return error('debug information lookup failed: ${output.stderr.trim_space()}')
	}
	response := json2.decode[[]DebugResponse](output.stdout)!
	if response.len > 0 {
		for symbol in response[0].symbol {
			if symbol.line > 0 && os.file_ext(symbol.file_name) in ['.v', '.vv', '.vsh'] {
				// A generated C column is not a V source column.
				return Location{
					file:      symbol.file_name
					line:      symbol.line
					function:  symbol.function_name
					precision: 'source_line'
				}
			}
		}
	}
	return error('no V source position in the available debug information')
}

fn (bundle &Bundle) address_from_load_base(pc u64, load_base u64) !u64 {
	if pc < load_base {
		return error('PC is below the image load address')
	}
	delta := pc - load_base
	if bundle.image.format == 'coff' {
		return delta
	}
	if delta > u64(-1) - bundle.image.preferred_base {
		return error('image address overflow')
	}
	return delta + bundle.image.preferred_base
}

fn (bundle &Bundle) macho_debug_object() !string {
	dwarf := os.join_path(bundle.artifact + '.dSYM', 'Contents', 'Resources', 'DWARF')
	if !os.is_dir(dwarf) {
		return bundle.artifact
	}
	contents := os.ls(dwarf)!
	for name in contents {
		path := os.join_path(dwarf, name)
		if !os.is_file(path) {
			continue
		}
		if id := macho_uuid(os.read_bytes(path)!) {
			if id == bundle.image.uuid {
				return path
			}
		}
	}
	return error('dSYM UUID does not match the Mach-O image')
}
