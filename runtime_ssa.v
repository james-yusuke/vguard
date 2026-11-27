module main

import os
import strings

const runtime_record_size = 56
const runtime_event_limit = 65536
const runtime_thread_record_size = 32

struct RuntimeStopAnchor {
	process   u64
	lwp       u64
	frame     u64
	caller    bool
	thread    int
	frame_idx int
}

struct RuntimeStopBinding {
	anchor     RuntimeStopAnchor
	pthread_id u64
	generation u64
}

struct RuntimeStopCorrelation {
	evidence string
	lwp      u64
	frame    string @[omitempty]
}

struct RuntimeSsaEvent {
	thread_generation u64
	thread_id         u64
	frame             u64
	kind              int
	id                int
	payload           u64
	width             int
	allocation_size   u64
}

struct RuntimeSsaValue {
	ssa_value int
	bits      string
	bytes     int
	event     int
}

struct RuntimeBranch {
	from_block int
	to_block   int
	event      int
}

struct RuntimeSsaEdge {
	from_event    int
	from_value    int
	to_event      int
	to_value      int
	kind          string
	address       string @[omitempty]
	overlap_bytes int    @[omitempty]
	evidence      string @[omitempty]
}

struct RuntimeSsaReport {
	evidence         string = 'native_ssa_events'
	function         string
	thread_id        string
	activation       int
	root_event       int
	root_value       int
	values           []RuntimeSsaValue
	branches         []RuntimeBranch
	dependencies     []RuntimeSsaEdge
	memory_order     ?RuntimeMemoryReport    @[omitempty]
	stop_correlation ?RuntimeStopCorrelation @[omitempty]
	stop_inputs      []StoppedSsaValue       @[skip]
	truncated        bool
}

struct RuntimeFrame {
	entry    int
	function string
mut:
	active      int
	block       int = -1
	predecessor int = -1
	branch      int
	definitions map[int]int
	values      map[int]RuntimeSsaValue
	branches    []RuntimeBranch
}

struct RuntimeNode {
	ssa_value int
	thread    string
mut:
	deps []RuntimeSsaEdge
}

fn runtime_ssa_compiler_args(options BuildOptions, work string) ![]string {
	arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	host := os.user_os() + '/' + arch
	if host !in ['linux/amd64', 'linux/arm64', 'macos/arm64'] || options.target != host
		|| options.backend != arch || options.object || options.hot_fn != ''
		|| options.args.any(it in ['-shared', '--shared']) {
		return error('--trace-runtime requires a standalone native executable for the supported host')
	}
	source := os.join_path(work, 'runtime_ssa.c')
	object := os.join_path(work, 'runtime_ssa.o')
	os.write_file(source, $embed_file('compiler/runtime_ssa.c').to_string())!
	compiled := capture(Command{
		executable: executable('clang')!
		args:       ['-std=c11', '-O2', '-fPIC', '-pthread', '-c', source, '-o', object]
	})!
	if compiled.status != 'exited' || compiled.exit_code != 0 {
		return error('building the native SSA recorder failed: ${compiled.stderr}')
	}
	object_arg := shell_argument(object)!
	link_flags := if os.user_os() == 'linux' {
		object_arg + ' -Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc,--wrap=free,--wrap=pthread_mutex_lock,--wrap=pthread_mutex_trylock,--wrap=pthread_mutex_unlock,--wrap=pthread_mutex_init,--wrap=pthread_mutex_destroy'
	} else {
		object_arg
	}
	return ['-vguard-runtime-ssa', '-ldflags', link_flags]
}

fn decode_runtime_events(data []u8) !([]RuntimeSsaEvent, bool) {
	if data.len == 0 {
		return error('the target produced no native SSA events')
	}
	if data.len % runtime_record_size != 0 || data.len / runtime_record_size > runtime_event_limit + 1 {
		return error('incomplete or oversized native SSA event stream')
	}
	mut events := []RuntimeSsaEvent{cap: data.len / runtime_record_size}
	mut truncated := false
	mut process := u64(0)
	mut generations := map[u64]u64{}
	for offset := 0; offset < data.len; offset += runtime_record_size {
		base := u64(offset)
		pid := number(data, base, 8)!
		thread_id := number(data, base + 8, 8)!
		frame := number(data, base + 16, 8)!
		kind := number(data, base + 24, 8)!
		id := number(data, base + 32, 8)!
		payload := number(data, base + 40, 8)!
		width := number(data, base + 48, 8)!
		if process == 0 {
			process = pid
		}
		if pid == 0 || pid != process || thread_id == 0 || kind < 1 || kind > runtime_mutex_reset
			|| (kind < 8 && (frame == 0 || id > 0x7fff_ffff || width > 8))
			|| (kind > 8 && width != 0) {
			return error('invalid or multiprocess native SSA trace')
		}
		if kind == 8 {
			truncated = true
		} else {
			if kind == runtime_thread_start {
				if id == 0 || payload != 0 || frame != 0 {
					return error('invalid native thread lifetime event')
				}
				generations[thread_id] = id
			}
			events << RuntimeSsaEvent{
				thread_generation: generations[thread_id]
				thread_id:         thread_id
				frame:             frame
				kind:              int(kind)
				id:                if kind < 8 { int(id) } else { 0 }
				payload:           payload
				width:             if kind < 8 { int(width) } else { 0 }
				allocation_size:   if kind > 8 { id } else { 0 }
			}
		}
	}
	return events, truncated
}

fn (event RuntimeSsaEvent) frame_key() string {
	return '${event.thread_key()}:${event.frame}'
}

fn (event RuntimeSsaEvent) thread_key() string {
	return '${event.thread_id}:${event.thread_generation}'
}

fn runtime_event_root(events []RuntimeSsaEvent, target int) !int {
	mut root := -1
	mut owner := ''
	for index, event in events {
		if event.kind != 3 || (target >= 0 && event.id != target) {
			continue
		}
		identity := event.thread_key()
		if target >= 0 && owner != '' && owner != identity {
			return error('the mapped SSA instruction was observed on multiple threads')
		}
		owner = identity
		root = index
	}
	if root < 0 {
		return error('the mapped SSA instruction was absent from the native trace')
	}
	return root
}

fn bind_runtime_stop(anchor RuntimeStopAnchor, data []u8, raw_trace []u8, events []RuntimeSsaEvent) !RuntimeStopBinding {
	if data.len == 0 || data.len % runtime_thread_record_size != 0
		|| data.len / runtime_thread_record_size > runtime_event_limit {
		return error('incomplete or oversized native thread identity records')
	}
	if anchor.process != number(raw_trace, 0, 8)! {
		return error('the native trace does not belong to the debugger inferior')
	}
	if anchor.caller && anchor.frame == 0 {
		return error('GDB could not read the frame pointer of the mapped caller')
	}
	mut binding := RuntimeStopBinding{ anchor: anchor }
	for offset := 0; offset < data.len; offset += runtime_thread_record_size {
		base := u64(offset)
		process := number(data, base, 8)!
		lwp := number(data, base + 8, 8)!
		pthread_id := number(data, base + 16, 8)!
		generation := number(data, base + 24, 8)!
		if process != anchor.process || lwp == 0 || lwp > 0x7fff_ffff || pthread_id == 0
			|| generation == 0 || generation > 0xffff_ffff {
			return error('invalid native thread identity record')
		}
		if lwp == anchor.lwp && generation > binding.generation {
			binding = RuntimeStopBinding{ anchor: anchor, pthread_id: pthread_id, generation: generation }
		}
	}
	if binding.generation == 0 {
		return error('the stopped Linux thread was absent from the native trace')
	}
	if !events.any(it.kind == runtime_thread_start && it.thread_id == binding.pthread_id
		&& it.thread_generation == binding.generation) {
		return error('the stopped thread identity has no matching trace lifetime')
	}
	return binding
}

fn (binding RuntimeStopBinding) event_root(events []RuntimeSsaEvent, target int) !int {
	for index := events.len - 1; index >= 0; index-- {
		event := events[index]
		if event.thread_id != binding.pthread_id || event.thread_generation != binding.generation
			|| (binding.anchor.frame != 0 && event.frame != binding.anchor.frame) {
			continue
		}
		if event.kind == 1 {
			break
		}
		if event.kind == 3 {
			if event.id != target {
				return error('the stopped activation last executed a different SSA instruction')
			}
			return index
		}
	}
	return error('the mapped SSA instruction was absent from the stopped activation')
}

fn (binding RuntimeStopBinding) correlation() RuntimeStopCorrelation {
	return RuntimeStopCorrelation{
		evidence: if binding.anchor.frame != 0 {
			'debugger_thread_and_frame_at_stop'
		} else {
			'debugger_thread_at_stop'
		}
		lwp:      binding.anchor.lwp
		frame:    if binding.anchor.frame != 0 { hex_address(binding.anchor.frame) } else { '' }
	}
}

fn (mut node RuntimeNode) add_runtime_edge(sequence int, prior int, value int, kind string, addr string, count int) {
	node.deps << RuntimeSsaEdge{
		from_event:    sequence
		from_value:    node.ssa_value
		to_event:      prior
		to_value:      value
		kind:          kind
		address:       addr
		overlap_bytes: count
		evidence:      if kind == 'observed_cross_thread_ordered_address_overlap' {
			'inferred_from_ordered_address_overlap'
		} else {
			''
		}
	}
}

fn collect_runtime_dependencies(nodes map[int]RuntimeNode, root int) ([]RuntimeSsaEdge, bool) {
	mut pending := [root]
	mut visited := {
		root: true
	}
	mut result := []RuntimeSsaEdge{}
	mut index := 0
	for index < pending.len && index < max_dataflow_nodes {
		for edge in nodes[pending[index]].deps {
			result << edge
			if edge.to_event !in visited {
				visited[edge.to_event] = true
				pending << edge.to_event
			}
		}
		index++
	}
	return result, index < pending.len
}

@[params]
struct RuntimeSsaSliceOptions {
	binding        ?RuntimeStopBinding
	recover_inputs bool
}

fn runtime_ssa_slice(graph SsaGraph, events []RuntimeSsaEvent, target int, incomplete bool, options RuntimeSsaSliceOptions) !RuntimeSsaReport {
	if target >= 0 && incomplete {
		return error('the native SSA event limit was reached before the stop could be verified')
	}
	root := if binding := options.binding {
		binding.event_root(events, target)!
	} else {
		runtime_event_root(events, target)!
	}
	selected_frame := events[root].frame_key()
	mut blocks := map[int]SsaBlock{}
	mut instructions := map[int]SsaInstruction{}
	for block in graph.blocks {
		blocks[block.id] = block
	}
	for instr in graph.instructions {
		instructions[instr.id] = instr
	}
	mut frames := map[string]RuntimeFrame{}
	mut nodes := map[int]RuntimeNode{}
	mut memory := RuntimeMemoryTracker{}
	mut truncated := incomplete
	mut through := if target < 0 { events.len - 1 } else { root }
	if target >= 0 {
		for index in root + 1 .. events.len {
			next := events[index]
			if next.kind >= runtime_heap_allocated || next.frame_key() != selected_frame {
				continue
			}
			if next.kind in [5, 6] && next.id == events[root].id {
				through = index
			}
			break
		}
	}
	for index, event in events {
		if index > through {
			break
		}
		seq := index + 1
		if event.kind in [runtime_mutex_acquire, runtime_mutex_release, runtime_mutex_reset] {
			memory.sync.apply(event, seq, memory.heap.generation_at(event.payload))
			continue
		}
		if event.kind == runtime_thread_start {
			continue
		}
		if event.kind >= runtime_heap_allocated {
			memory.heap.apply(event, seq)!
			continue
		}
		key := event.frame_key()
		if event.kind == 1 {
			block := blocks[event.id] or { return error('runtime frame entry has no SSA block') }
			frames[key] = RuntimeFrame{ entry: seq, function: block.function }
			continue
		}
		mut frame := frames[key] or { return error('native SSA event has no frame entry') }
		match event.kind {
			2 {
				block := blocks[event.id] or { return error('runtime branch has no SSA block') }
				if block.function != frame.function {
					return error('native SSA block belongs to another function')
				}
				if frame.block >= 0 && event.id in blocks[frame.block].successors {
					frame.predecessor = frame.block
					frame.branch = frame.active
					if frame.branches.len < 256 {
						frame.branches << RuntimeBranch{ from_block: frame.block, to_block: event.id, event: seq }
					} else {
						truncated = true
					}
				} else {
					frame.predecessor = -1
					frame.branch = 0
				}
				frame.block = event.id
			}
			3 {
				instr := instructions[event.id] or { return error('runtime instruction is absent from the SSA graph') }
				if instr.block != frame.block {
					return error('runtime instruction does not belong to the observed block')
				}
				mut node := RuntimeNode{ ssa_value: event.id, thread: event.thread_key() }
				if frame.branch > 0 {
					node.add_runtime_edge(seq, frame.branch, nodes[frame.branch].ssa_value,
						'executed_cfg_edge', '', 0)
				}
				for operand_index, operand in instr.operands {
					if operand.role == 'use' {
						if instr.op == 'phi' && (operand_index + 1 >= instr.operands.len
							|| instr.operands[operand_index + 1].role != 'block'
							|| instr.operands[operand_index + 1].id != frame.predecessor) {
							continue
						}
						if prior := frame.definitions[operand.id] {
							node.add_runtime_edge(seq, prior, nodes[prior].ssa_value, 'observed_ssa_definition', '', 0)
						}
					}
				}
				nodes[seq] = node
				frame.active = seq
			}
			4 {
				if event.width !in [1, 2, 4, 8] {
					return error('invalid width for a sampled SSA value')
				}
				if frame.active > 0 {
					instr := instructions[nodes[frame.active].ssa_value]
					if instr.op == 'phi' && !instr.operands.any(it.role == 'block' && it.id == frame.predecessor) {
						continue
					}
				}
				mask := if event.width == 8 { u64(-1) } else { (u64(1) << (event.width * 8)) - 1 }
				frame.values[event.id] = RuntimeSsaValue{
					ssa_value: event.id
					bits:      hex_address(event.payload & mask)
					bytes:     event.width
					event:     seq
				}
				if frame.active > 0 {
					frame.definitions[event.id] = frame.active
				}
			}
			5, 6 {
				if frame.active <= 0 || nodes[frame.active].ssa_value != event.id
					|| event.width !in [1, 2, 4, 8] || event.payload > u64(-1) - u64(event.width - 1) {
					return error('invalid native SSA access event')
				}
				memory.begin(frame.active, seq, event)
			}
			7 {
				if frame.active <= 0 || nodes[frame.active].ssa_value != event.id {
					return error('unmatched native SSA access completion')
				}
				candidates := memory.complete(frame.active, seq)!
				if candidates.len > 0 {
					address := hex_address(memory.accesses[frame.active].event.payload)
					for prior in candidates.keys().sorted() {
						earlier := nodes[prior]
						relation := if earlier.thread == event.thread_key() {
							'observed_same_thread_address_overlap'
						} else {
							'observed_cross_thread_ordered_address_overlap'
						}
						nodes[frame.active].add_runtime_edge(frame.active, prior, earlier.ssa_value,
							relation, address, candidates[prior])
					}
				}
			}
			else {}
		}
		frames[key] = frame
	}
	selected := frames[selected_frame] or { return error('the traced activation is missing') }
	mut values := []RuntimeSsaValue{}
	for id in selected.values.keys().sorted() {
		if values.len == 512 {
			truncated = true
			break
		}
		values << selected.values[id]
	}
	dependencies, limited := collect_runtime_dependencies(nodes, root + 1)
	mut stop_inputs := []StoppedSsaValue{}
	if options.recover_inputs {
		if binding := options.binding {
			if target >= 0 && binding.anchor.frame != 0 && binding.anchor.thread > 0 {
				stop_inputs = sampled_stop_inputs(instructions[events[root].id], selected.values,
					root + 1)
			}
		}
	}
	return RuntimeSsaReport{
		function:         selected.function
		thread_id:        hex_address(events[root].thread_id)
		activation:       selected.entry
		root_event:       root + 1
		root_value:       events[root].id
		values:           values
		branches:         selected.branches
		dependencies:     dependencies
		memory_order:     memory.report()
		stop_correlation: if binding := options.binding {
			?RuntimeStopCorrelation(binding.correlation())
		} else {
			none
		}
		stop_inputs:      stop_inputs
		truncated:        truncated || limited
	}
}

fn (bundle &Bundle) run_runtime_ssa(scenario ExecutionCase, options RunOptions) !Diagnosis {
	if !bundle.manifest.options.trace_runtime || scenario.harness != '' {
		return error('--runtime-ssa requires a standalone executable built with --trace-runtime')
	}
	dir := temp_directory()!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'native-ssa.bin')
	os.write_file(path, '')!
	mut env := scenario.env.clone()
	env['VGUARD_SSA_TRACE_FILE'] = path
	correlate := os.user_os() == 'linux' && !bundle.manifest.options.memory
	identities := os.join_path(dir, 'native-threads.bin')
	if correlate {
		os.write_file(identities, '')!
		env['VGUARD_SSA_THREADS_FILE'] = identities
	}
	report := bundle.run(ExecutionCase{ ...scenario, env: env }, RunOptions{
		...options
		runtime_ssa:         false
		runtime_stop_anchor: correlate
	})!
	collected := bundle.read_runtime_ssa(report, path,
		identities:     if correlate { identities } else { '' }
		recover_inputs: options.recover_ssa
	) or {
		return Diagnosis{ ...report, runtime_ssa_error: err.msg() }
	}
	return with_sampled_stop_inputs(Diagnosis{ ...report, runtime_ssa: collected },
		collected.stop_inputs, options.stack)
}

@[params]
struct RuntimeSsaReadOptions {
	identities     string
	recover_inputs bool
}

fn (bundle &Bundle) read_runtime_ssa(report Diagnosis, path string, options RuntimeSsaReadOptions) !RuntimeSsaReport {
	target := if report.kind == 'exited' {
		-1
	} else {
		location := report.location or { return error('a crash needs a mapped SSA instruction to anchor the runtime trace') }
		if location.ssa_value < 0 {
			return error('the stop has no mapped native SSA instruction')
		}
		location.ssa_value
	}
	if os.file_size(path) > u64(runtime_record_size * (runtime_event_limit + 1)) {
		return error('the native SSA trace exceeded its configured size')
	}
	raw := os.read_bytes(path)!
	events, truncated := decode_runtime_events(raw)!
	mut binding := ?RuntimeStopBinding(none)
	if target >= 0 && options.identities != '' {
		if anchor := report.runtime_stop {
			size := os.file_size(options.identities)
			if size > u64(runtime_thread_record_size * runtime_event_limit) {
				return error('the native thread identity file exceeds its size limit')
			}
			// Existing native artifacts produce the original trace alone.
			if size > 0 {
				binding = bind_runtime_stop(anchor, os.read_bytes(options.identities)!, raw,
					events)!
			}
		}
	}
	return runtime_ssa_slice(bundle.read_ssa_graph()!, events, target, truncated, RuntimeSsaSliceOptions{
		binding:        binding
		recover_inputs: options.recover_inputs
	})
}

fn write_runtime_ssa(mut out strings.Builder, report Diagnosis) {
	if runtime := report.runtime_ssa {
		out.writeln('  = runtime SSA: ${runtime.function} %${runtime.root_value} at event ${runtime.root_event}')
		if stop := runtime.stop_correlation {
			out.writeln('    stopped Linux thread ${stop.lwp} (${stop.evidence})')
		}
		for value in runtime.values {
			out.writeln('    %${value.ssa_value} = ${value.bits} (${value.bytes} bytes, event ${value.event})')
		}
		for branch in runtime.branches {
			out.writeln('    block ${branch.from_block} -> ${branch.to_block} (event ${branch.event})')
		}
		for edge in runtime.dependencies {
			label := if edge.evidence != '' { '${edge.kind}, ${edge.evidence}' } else { edge.kind }
			out.writeln('    event ${edge.from_event} -> ${edge.to_event} (${label})')
		}
		if memory := runtime.memory_order {
			for reuse in memory.reuse {
				out.writeln('    heap ${reuse.address} reused from generation ${reuse.previous} to ${reuse.current}')
			}
			for pair in memory.cross_thread {
				out.writeln('    memory events ${pair.earlier_begin.begin_event} and ${pair.later_begin.begin_event} (${pair.relation})')
			}
			if memory.truncated {
				out.writeln('  = runtime memory report reached its limit')
			}
		}
		if runtime.truncated {
			out.writeln('  = runtime SSA trace or report reached its limit')
		}
	}
	if report.runtime_ssa_error != '' {
		out.writeln('  = note: runtime SSA unavailable (${report.runtime_ssa_error})')
	}
}
