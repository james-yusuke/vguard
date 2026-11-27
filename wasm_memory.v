module main

fn wasm_heap_trap(location Location) string {
	if location.ssa_value != -1 || location.ssa_opcode != 'unreachable' {
		return ''
	}
	return match location.function {
		'__vguard_heap_bounds' { 'wasm-heap-out-of-bounds' }
		'__vguard_heap_retired' { 'wasm-heap-use-after-free' }
		'__vguard_heap_invalid_lifetime' { 'wasm-invalid-heap-lifetime-operation' }
		'__vguard_heap_capacity' { 'wasm-heap-capacity-exceeded' }
		else { '' }
	}
}

fn validate_wasm_heap_ranges(options BuildOptions, image Image, ranges []PlacedRange, data []u8) ! {
	validate_memory_target(options)!
	if image.format != 'wasm' {
		return error('--wasm-heap requires a Wasm artifact')
	}
	mut seen := map[string]bool{}
	for range in ranges {
		kind := wasm_heap_trap(range.location)
		if kind == '' {
			continue
		}
		body := image.section(range.section)!
		if kind in seen || range.start != 0 || range.end != 1 || body.size != 2
			|| view(data, body.offset, body.size)! != [u8(0x00), 0x0b] {
			return error('invalid Wasm heap trap marker')
		}
		seen[kind] = true
	}
	if seen.len != 4 {
		return error('the target compiler did not emit the Wasm heap trap markers')
	}
}

fn (bundle &Bundle) with_wasm_heap_memory(report Diagnosis) Diagnosis {
	if !bundle.manifest.options.wasm_heap || report.kind != 'crash' {
		return report
	}
	lines := report.outcome.stderr.trim_space().split_into_lines()
	if lines.len == 0 || wasm_cause_line(lines.last()) != 'wasm trap: wasm `unreachable` instruction executed' {
		return report
	}
	pc := parse_address(report.address) or { return report }
	anchor := bundle.resolve_address(pc) or { return report }
	kind := wasm_heap_trap(anchor)
	message := match kind {
		'wasm-heap-out-of-bounds' { 'the checked access exceeded a tracked heap allocation' }
		'wasm-heap-use-after-free' { 'the checked access used a retired heap allocation' }
		'wasm-invalid-heap-lifetime-operation' {
			'free or realloc did not use the base of a live heap allocation'
		}
		'wasm-heap-capacity-exceeded' {
			'the checked allocation or its metadata could not fit in linear memory'
		}
		else { return report }
	}
	location := report.location or { Location{} }
	operation := match location.ssa_opcode {
		'load' { 'read' }
		'store' { 'write' }
		else { '' }
	}
	return Diagnosis{
		...report
		kind:          'memory_error'
		reason:        kind
		memory_errors: [MemoryViolation{
			kind:      kind
			sanitizer: 'vguard-wasm-shadow'
			message:   message
			access:    operation
			location:  report.location
		}]
	}
}
