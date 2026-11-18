module main

struct Section {
	index   int
	name    string
	address u64
	size    u64
	offset  u64
}

struct Symbol {
	section int
	address u64
}

struct Image {
	format           string
	relocatable      bool
	runnable         bool
	preferred_base   u64
	uuid             string
	sections         []Section
	symbols          map[string]Symbol
	wasm_bodies      []Section
	wasm_code_offset u64
}

// view checks the byte range before converting untrusted offsets to array indexes.
fn view(data []u8, offset u64, size u64) ![]u8 {
	if offset > u64(data.len) || size > u64(data.len) - offset {
		return error('binary field outside the file')
	}
	return data[int(offset)..int(offset + size)]
}

fn number(data []u8, offset u64, width int) !u64 {
	bytes := view(data, offset, u64(width))!
	mut result := u64(0)
	for i, byte in bytes {
		result |= u64(byte) << (8 * i)
	}
	return result
}

fn c_string(data []u8, offset u64) !string {
	tail := view(data, offset, u64(data.len) - offset)!
	for i, byte in tail {
		if byte == 0 {
			return tail[..i].bytestr()
		}
	}
	return error('unterminated binary string')
}

fn image(data []u8, format string) !Image {
	if format == 'raw-arm64' {
		if data.len == 0 || data.len % 4 != 0 {
			return error('invalid arm64 machine code size')
		}
		return Image{
			format:      format
			relocatable: true
			sections:    [Section{ index: 1, name: 'code', size: u64(data.len) }]
		}
	}
	magic := number(data, 0, 4)!
	return match magic {
		0x464c457f { elf_image(data) }
		0xfeedfacf { macho_image(data) }
		0x6d736100 { wasm_image(data) }
		else { coff_image(data) }
	}
}

struct ElfSection {
	kind       u64
	flags      u64
	address    u64
	offset     u64
	size       u64
	name       u64
	link       u64
	entry_size u64
}

fn elf_image(data []u8) !Image {
	if number(data, 4, 2)! != 0x0102 || number(data, 18, 2)! !in [u64(62), 183] {
		return error('expected little-endian ELF64 for amd64 or arm64')
	}
	kind := number(data, 16, 2)!
	header := number(data, 40, 8)!
	entry_size := number(data, 58, 2)!
	count := number(data, 60, 2)!
	names_index := number(data, 62, 2)!
	if kind !in [u64(1), 2, 3] || entry_size != 64 || names_index >= count {
		return error('unsupported ELF header')
	}
	view(data, header, count * entry_size)!
	mut entries := []ElfSection{cap: int(count)}
	for i in 0 .. int(count) {
		entry := header + u64(i) * entry_size
		entries << ElfSection{
			name:       number(data, entry, 4)!
			kind:       number(data, entry + 4, 4)!
			flags:      number(data, entry + 8, 8)!
			address:    number(data, entry + 16, 8)!
			offset:     number(data, entry + 24, 8)!
			size:       number(data, entry + 32, 8)!
			link:       number(data, entry + 40, 4)!
			entry_size: number(data, entry + 56, 8)!
		}
	}
	names := entries[int(names_index)]
	name_data := view(data, names.offset, names.size)!
	mut sections := []Section{}
	mut symbols := map[string]Symbol{}
	for i, entry in entries {
		if entry.flags & 4 != 0 && entry.kind == 1 {
			view(data, entry.offset, entry.size)!
			sections << Section{
				index:   i
				name:    c_string(name_data, entry.name)!
				address: entry.address
				size:    entry.size
				offset:  entry.offset
			}
		}
		if entry.kind !in [u64(2), 11] || entry.entry_size != 24 || entry.link >= count {
			continue
		}
		strings := entries[int(entry.link)]
		strtab := view(data, strings.offset, strings.size)!
		symtab := view(data, entry.offset, entry.size)!
		for start := 0; start + 24 <= symtab.len; start += 24 {
			offset := u64(start)
			sid := int(number(symtab, offset + 6, 2)!)
			if sid == 0 || sid >= entries.len || entries[sid].flags & 4 == 0 {
				continue
			}
			name := c_string(strtab, number(symtab, offset, 4)!)!
			if name != '' {
				symbols[name] = Symbol{
					section: sid
					address: number(symtab, offset + 8, 8)!
				}
			}
		}
	}
	mut base := u64(0)
	mut has_base := false
	p_offset := number(data, 32, 8)!
	p_size := number(data, 54, 2)!
	p_count := number(data, 56, 2)!
	if p_count > 0 {
		if p_size != 56 {
			return error('invalid ELF program header size')
		}
		table := view(data, p_offset, p_size * p_count)!
		for i in 0 .. int(p_count) {
			offset := u64(i) * p_size
			if number(table, offset, 4)! != 1 {
				continue
			}
			vaddr := number(table, offset + 16, 8)!
			if !has_base || vaddr < base {
				base = vaddr
				has_base = true
			}
		}
	}
	return Image{
		format:         'elf'
		relocatable:    kind == 1
		runnable:       kind == 2 || (kind == 3 && number(data, 24, 8)! != 0)
		preferred_base: base
		sections:       sections
		symbols:        symbols
	}
}

fn macho_uuid(data []u8) ?string {
	magic := number(data, 0, 4) or { return none }
	if magic != 0xfeedfacf {
		return none
	}
	size := number(data, 20, 4) or { return none }
	commands := view(data, 32, size) or { return none }
	mut offset := u64(0)
	for offset < size {
		kind := number(commands, offset, 4) or { return none }
		length := number(commands, offset + 4, 4) or { return none }
		if length < 8 || length > size - offset {
			return none
		}
		if kind == 0x1b && length == 24 {
			bytes := view(commands, offset + 8, 16) or { return none }
			return bytes.hex()
		}
		offset += length
	}
	return none
}

fn macho_image(data []u8) !Image {
	cpu := number(data, 4, 4)!
	if cpu !in [u64(0x01000007), 0x0100000c] {
		return error('expected Mach-O for amd64 or arm64')
	}
	kind := number(data, 12, 4)!
	count := number(data, 16, 4)!
	commands := view(data, 32, number(data, 20, 4)!)!
	mut offset := u64(0)
	mut section_index := 0
	mut text_base := u64(0)
	mut sections := []Section{}
	mut symbols := map[string]Symbol{}
	mut symtab := []u8{}
	mut strtab := []u8{}
	for _ in 0 .. count {
		cmd := number(commands, offset, 4)!
		size := number(commands, offset + 4, 4)!
		if size < 8 {
			return error('invalid Mach-O load command size')
		}
		entry := view(commands, offset, size)!
		offset += size
		if cmd == 2 {
			symtab = view(data, number(entry, 8, 4)!, number(entry, 12, 4)! * 16)!
			strtab = view(data, number(entry, 16, 4)!, number(entry, 20, 4)!)!
		}
		if cmd != 0x19 {
			continue
		}
		if view(entry, 8, 16)!.bytestr().trim_right('\x00') == '__TEXT' {
			text_base = number(entry, 24, 8)!
		}
		nsects := number(entry, 64, 4)!
		view(entry, 72, nsects * 80)!
		for i in 0 .. nsects {
			start := 72 + i * 80
			section_index++
			flags := number(entry, start + 64, 4)!
			if flags & 0x80000400 == 0 {
				continue
			}
			section_size := number(entry, start + 40, 8)!
			section_offset := number(entry, start + 48, 4)!
			view(data, section_offset, section_size)!
			sections << Section{
				index:   section_index
				name:    view(entry, start, 16)!.bytestr().trim_right('\x00')
				address: number(entry, start + 32, 8)!
				size:    section_size
				offset:  section_offset
			}
		}
	}
	for i := 0; i + 16 <= symtab.len; i += 16 {
		if symtab[i + 4] & 0xee != 0x0e {
			continue
		}
		sid := int(symtab[i + 5])
		if !sections.any(it.index == sid) {
			continue
		}
		name := c_string(strtab, number(symtab, u64(i), 4)!)!
		symbols[name] = Symbol{
			section: sid
			address: number(symtab, u64(i + 8), 8)!
		}
	}
	return Image{
		format:         'macho'
		relocatable:    kind == 1
		runnable:       kind == 2
		preferred_base: text_base
		uuid:           macho_uuid(data) or { '' }
		sections:       sections
		symbols:        symbols
	}
}

fn coff_image(data []u8) !Image {
	mut header := u64(0)
	is_pe := number(data, 0, 2)! == 0x5a4d
	if is_pe {
		pe := number(data, 60, 4)!
		if number(data, pe, 4)! != 0x4550 {
			return error('invalid PE signature')
		}
		header = pe + 4
	}
	if number(data, header, 2)! !in [u64(0x8664), 0xaa64] {
		return error('unrecognized binary format')
	}
	count := number(data, header + 2, 2)!
	opt_size := number(data, header + 16, 2)!
	optional := view(data, header + 20, opt_size)!
	flags := number(data, header + 18, 2)!
	mut base := u64(0)
	if is_pe {
		if number(optional, 0, 2)! != 0x20b {
			return error('expected PE32+ for amd64 or arm64')
		}
		base = number(optional, 24, 8)!
	}
	table := view(data, header + 20 + opt_size, count * 40)!
	mut sections := []Section{}
	for i in 0 .. count {
		start := i * 40
		if number(table, start + 36, 4)! & 0x20000000 == 0 {
			continue
		}
		size := number(table, start + 16, 4)!
		offset := number(table, start + 20, 4)!
		view(data, offset, size)!
		sections << Section{
			index:   int(i) + 1
			name:    view(table, start, 8)!.bytestr().trim_right('\x00')
			address: if is_pe { number(table, start + 12, 4)! } else { 0 }
			size:    size
			offset:  offset
		}
	}
	return Image{
		format:         'coff'
		relocatable:    !is_pe
		runnable:       is_pe && flags & 0x2000 == 0
		preferred_base: base
		sections:       sections
	}
}

fn leb(data []u8, initial_offset int) !(int, int) {
	mut offset := initial_offset
	mut result := u32(0)
	for i in 0 .. 5 {
		if offset >= data.len {
			return error('truncated Wasm integer')
		}
		byte := data[offset]
		offset += 1
		if i == 4 && byte > 15 {
			break
		}
		result |= u32(byte & 127) << (i * 7)
		if byte & 128 == 0 && result <= 0x7fff_ffff {
			return int(result), offset
		}
	}
	return error('invalid Wasm integer')
}

fn wasm_image(data []u8) !Image {
	if number(data, 4, 4)! != 1 {
		return error('expected a WebAssembly core module')
	}
	mut cursor := 8
	mut bodies := []Section{}
	mut code_offset := u64(0)
	for cursor < data.len {
		kind := data[cursor]
		cursor++
		size, payload_start := leb(data, cursor)!
		cursor = payload_start
		payload := view(data, u64(cursor), u64(size))!
		if kind == 10 {
			if code_offset != 0 {
				return error('duplicate Wasm code section')
			}
			code_offset = u64(cursor)
			count, first_body := leb(payload, 0)!
			mut code := first_body
			for i in 0 .. count {
				body_size, body_start := leb(payload, code)!
				code = body_start
				body := view(payload, u64(code), u64(body_size))!
				groups, local_start := leb(body, 0)!
				mut instruction := local_start
				for _ in 0 .. groups {
					_, valtype := leb(body, instruction)!
					view(body, u64(valtype), 1)!
					instruction = valtype + 1
				}
				bodies << Section{
					index:   i
					name:    'code'
					address: u64(cursor + code + instruction)
					size:    u64(body_size - instruction)
					offset:  u64(cursor + code + instruction)
				}
				code += body_size
			}
			if code != payload.len {
				return error('invalid Wasm code section length')
			}
		}
		cursor += size
	}
	return Image{
		format:           'wasm'
		runnable:         true
		sections:         bodies
		wasm_bodies:      bodies
		wasm_code_offset: code_offset
	}
}

fn (img &Image) section(index int) !Section {
	for section in img.sections {
		if section.index == index {
			return section
		}
	}
	return error('no executable section with index ${index}')
}
