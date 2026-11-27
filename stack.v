module main

import strconv

struct DebuggerThread {
	number      int
	selected    bool @[omitempty]
	description string
mut:
	frames []DebuggerFrame
}

struct DebuggerFrame {
	index           int
	address         string @[omitempty]
	text            string
	arguments       string          @[omitempty]
	source          ?DebuggerSource @[omitempty]
	mapped_location ?Location       @[omitempty]
}

struct DebuggerSource {
	file   string
	line   int
	column int @[omitempty]
}

fn (bundle &Bundle) with_wasm_backtrace(report Diagnosis) Diagnosis {
	if report.kind !in ['crash', 'fuel_exhausted', 'memory_error'] {
		return report
	}
	stderr := report.outcome.stderr.trim_space()
	lines := stderr.split_into_lines()
	if lines.len == 0 || !wasm_cause_line(lines.last()).starts_with('wasm trap: ') {
		return report
	}
	start := stderr.last_index('wasm backtrace:') or { return report }
	mut frames := []DebuggerFrame{}
	for raw in stderr[start + 'wasm backtrace:'.len..].trim_space().split_into_lines() {
		line := raw.trim_space()
		words := line.fields()
		if words.len < 4 || !words[0].ends_with(':') || !words[1].starts_with('0x')
			|| words[2] != '-' {
			break
		}
		index := debugger_decimal(words[0].trim_string_right(':')) or { break }
		if index != frames.len {
			break
		}
		pc := parse_address(words[1]) or { break }
		location := if mapped := bundle.resolve_address(pc) {
			?Location(if index == 0 {
				mapped
			} else {
				Location{ ...mapped, precision: 'caller_frame' }
			})
		} else {
			bundle.wasm_body_location(pc)
		}
		frames << DebuggerFrame{
			index:           index
			address:         words[1]
			text:            line
			mapped_location: location
		}
	}
	if frames.len == 0 {
		return report
	}
	return Diagnosis{
		...report
		stack_trace: DebuggerStack{
			debugger: 'wasmtime'
			evidence: 'wasmtime_cli_trap'
			text:     frames.map(it.text).join('\n')
			threads:  [
				DebuggerThread{
					selected:    true
					description: 'WebAssembly trap'
					frames:      frames
				},
			]
		}
	}
}

fn (bundle &Bundle) map_debugger_frame(pc u64, base u64, caller bool) !Location {
	// A saved return address points to the byte after the call.
	frame_pc := if caller && pc > base { pc - 1 } else { pc }
	mapped := bundle.resolve_address(bundle.address_from_load_base(frame_pc, base)!)!
	return if caller { Location{ ...mapped, precision: 'caller_frame' } } else { mapped }
}

fn (bundle &Bundle) with_mapped_stack(stack DebuggerStack, base u64) DebuggerStack {
	if bundle.ranges.len == 0 {
		return stack
	}
	mut threads := []DebuggerThread{cap: stack.threads.len}
	for thread_info in stack.threads {
		mut frames := []DebuggerFrame{cap: thread_info.frames.len}
		for frame in thread_info.frames {
			pc := parse_address(frame.address) or {
				frames << frame
				continue
			}
			location := bundle.map_debugger_frame(pc, base, frame.index > 0) or {
				frames << frame
				continue
			}
			frames << DebuggerFrame{ ...frame, mapped_location: location }
		}
		threads << DebuggerThread{ ...thread_info, frames: frames }
	}
	return DebuggerStack{ ...stack, threads: threads }
}

fn parse_debugger_threads(trace string) []DebuggerThread {
	mut threads := []DebuggerThread{}
	for raw in trace.split_into_lines() {
		line := raw.trim_space()
		if number := debugger_thread_number(line) {
			threads << DebuggerThread{
				number:      number
				selected:    line.starts_with('*')
				description: line
			}
		} else if threads.len > 0 {
			if frame := parse_debugger_frame(line) {
				threads[threads.len - 1].frames << frame
			}
		}
	}
	return threads
}

fn debugger_thread_number(line string) ?int {
	header := line.trim_left('* ')
	prefix := if header.starts_with('thread #') {
		'thread #'
	} else if header.starts_with('Thread ') {
		'Thread '
	} else {
		return none
	}
	mut end := prefix.len
	for end < header.len && header[end] >= `0` && header[end] <= `9` {
		end++
	}
	if end == prefix.len || (end < header.len && header[end] !in [`:`, `,`, ` `]) {
		return none
	}
	return strconv.atoi(header[prefix.len..end]) or { none }
}

fn parse_debugger_frame(line string) ?DebuggerFrame {
	frame := line.trim_left('* ').trim_string_left('frame ')
	if !frame.starts_with('#') {
		return none
	}
	separator := frame.index_any(': ')
	if separator < 2 {
		return none
	}
	frame_index := debugger_decimal(frame[1..separator]) or { return none }
	description := frame[separator..].trim_left(': ')
	words := description.fields()
	mut address := ''
	if words.len > 0 && words[0].starts_with('0x') {
		if _ := parse_address(words[0]) {
			address = words[0]
		}
	}
	mut before_source := description
	mut source := ?DebuggerSource(none)
	if at := description.last_index(' at ') {
		if location := parse_debugger_source(description[at + 4..]) {
			source = location
			before_source = description[..at]
		}
	}
	if from := before_source.last_index(' from ') {
		before_source = before_source[..from]
	}
	mut argument_text := ''
	if start := before_source.index('(') {
		if end := before_source.last_index(')') {
			if start < end && before_source[start + 1..end].contains('=') {
				argument_text = before_source[start + 1..end]
			}
		}
	}
	return DebuggerFrame{
		index:     frame_index
		address:   address
		text:      line
		arguments: argument_text
		source:    source
	}
}

fn parse_debugger_source(text string) ?DebuggerSource {
	// Parse coordinates from the right so Windows drive letters are preserved.
	site := text.trim_space().trim_string_right(' [opt]')
	colon := site.last_index(':') or { return none }
	last := debugger_decimal(site[colon + 1..]) or { return none }
	if last <= 0 || colon == 0 {
		return none
	}
	prefix := site[..colon]
	if previous := prefix.last_index(':') {
		if previous > 0 {
			if line := debugger_decimal(prefix[previous + 1..]) {
				if line > 0 {
					return DebuggerSource{ file: prefix[..previous], line: line, column: last }
				}
			}
		}
	}
	return DebuggerSource{ file: prefix, line: last }
}

fn debugger_decimal(text string) ?int {
	if text == '' || !text.bytes().all(it >= `0` && it <= `9`) {
		return none
	}
	return strconv.atoi(text) or { none }
}
