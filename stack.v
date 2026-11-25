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
	index     int
	address   string @[omitempty]
	text      string
	arguments string          @[omitempty]
	source    ?DebuggerSource @[omitempty]
}

struct DebuggerSource {
	file   string
	line   int
	column int @[omitempty]
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
