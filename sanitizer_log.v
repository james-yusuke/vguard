module main

import os
import strconv

struct MemoryViolation {
mut:
	kind         string
	sanitizer    string
	message      string
	address      string
	access       string
	size_bytes   int
	location     ?Location
	allocation   ?Location
	deallocation ?Location
}

struct SanitizerEvent {
mut:
	finding     MemoryViolation
	crash       bool
	stack       []string
	alloc_stack []string
	free_stack  []string
}

enum SanitizerStack {
	access
	allocation
	deallocation
	other
}

fn sanitizer_address(text string) string {
	for word in text.fields() {
		address := word.trim_right(',:);')
		if address.starts_with('0x') {
			value := parse_address(address) or { continue }
			return hex_address(value)
		}
	}
	return ''
}

fn asan_event(line string) ?SanitizerEvent {
	if !line.starts_with('==') {
		return none
	}
	end := line.index_after('==', 2) or { return none }
	strconv.parse_uint(line[2..end], 10, 64) or { return none }
	prefix := 'ERROR: AddressSanitizer:'
	body := line[end + 2..].trim_space()
	if !body.starts_with(prefix) {
		return none
	}
	message := body[prefix.len..].trim_space()
	category := message.all_before(' ')
	kind := match true {
		category in ['heap-buffer-overflow', 'stack-buffer-overflow', 'global-buffer-overflow',
			'heap-use-after-free', 'use-after-poison'] {
			category
		}
		category == 'dynamic-stack-buffer-overflow' { 'stack-buffer-overflow' }
		message.starts_with('attempting double-free ') { 'double-free' }
		message.starts_with('attempting free on address which was not malloc()-ed')
			|| category in ['alloc-dealloc-mismatch', 'new-delete-type-mismatch'] {
			'invalid-free'
		}
		else { '' }
	}
	return SanitizerEvent{
		finding: MemoryViolation{
			kind:      kind
			sanitizer: 'asan'
			message:   message
			address:   sanitizer_address(message)
			access:    if kind in ['double-free', 'invalid-free'] { 'free' } else { '' }
		}
		crash:   category in ['SEGV', 'BUS', 'ILL', 'FPE', 'ABRT', 'stack-overflow']
	}
}

fn source_coordinate(text string) ?Location {
	separator := text.last_index(':') or { return none }
	mut line := strconv.atoi(text[separator + 1..]) or { return none }
	mut file := text[..separator]
	// UBSan includes a generated C column. Keep only the V line number.
	if column_separator := file.last_index(':') {
		if source_line := strconv.atoi(file[column_separator + 1..]) {
			line = source_line
			file = file[..column_separator]
		}
	}
	if line <= 0 || os.file_ext(file) !in ['.v', '.vv', '.vsh'] {
		return none
	}
	return Location{
		file:      file
		line:      line
		precision: 'source_line'
	}
}

fn ubsan_event(line string) ?SanitizerEvent {
	separator := line.index(': runtime error: ') or { return none }
	message := line[separator + ': runtime error: '.len..]
	kind := match true {
		message.starts_with('load of null pointer') || message.starts_with('store to null pointer')
			|| message.starts_with('member access within null pointer') {
			'null-pointer-dereference'
		}
		message.starts_with('index ') && message.contains(' out of bounds for type ') {
			'out-of-bounds'
		}
		else { return none }
	}
	return SanitizerEvent{
		finding: MemoryViolation{
			kind:      kind
			sanitizer: 'ubsan'
			message:   message
			address:   if kind == 'null-pointer-dereference' { '0x0' } else { '' }
			access:    if message.starts_with('load ') {
				'read'
			} else if message.starts_with('store ') {
				'write'
			} else {
				''
			}
			location:  source_coordinate(line[..separator])
		}
	}
}

fn parse_sanitizer_log(log string) []SanitizerEvent {
	mut events := []SanitizerEvent{}
	mut event := SanitizerEvent{}
	mut stack := SanitizerStack.other
	for raw in log.split_into_lines() {
		line := raw.trim_space()
		next := if line.starts_with('==') { asan_event(line) } else { ubsan_event(line) }
		if header := next {
			if event.finding.sanitizer != '' {
				events << event
			}
			event = header
			stack = .access
			continue
		}
		if event.finding.sanitizer == '' {
			continue
		}
		if line.starts_with('freed by thread ') {
			stack = .deallocation
		} else if line.starts_with('previously allocated by thread ')
			|| line.starts_with('allocated by thread ') {
			stack = .allocation
		} else if line.starts_with('Thread ') || line.starts_with('SUMMARY:') {
			stack = .other
		} else if line.starts_with('#') {
			match stack {
				.access {
					if event.stack.len < 32 { event.stack << line }
				}
				.allocation {
					if event.alloc_stack.len < 32 { event.alloc_stack << line }
				}
				.deallocation {
					if event.free_stack.len < 32 { event.free_stack << line }
				}
				.other {}
			}
		} else if stack == .access {
			fields := line.fields()
			if fields.len >= 4 && fields[0] in ['READ', 'WRITE'] && fields[1] == 'of'
				&& fields[2] == 'size' {
				event.finding.access = fields[0].to_lower()
				event.finding.size_bytes = strconv.atoi(fields[3]) or { 0 }
				if address := line.index(' at ') {
					event.finding.address = sanitizer_address(line[address + 4..])
				}
			}
		}
	}
	if event.finding.sanitizer != '' {
		events << event
	}
	return events
}
