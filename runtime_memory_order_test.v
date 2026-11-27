module main

import json2
import os

fn test_mutex_order_does_not_cross_thread_or_mutex_reuse_without_a_recorded_handoff() {
	mut sync := RuntimeSynchronization{}
	old := RuntimeSsaEvent{ thread_id: 11, thread_generation: 1, payload: 0x1000 }
	new := RuntimeSsaEvent{ thread_id: 12, thread_generation: 2, payload: 0x1000 }
	older := RuntimeAccess{ event: old, begin: 1, end: 2 }
	sync.apply(RuntimeSsaEvent{ ...old, kind: runtime_mutex_release }, 3, 0)
	sync.apply(RuntimeSsaEvent{ ...new, kind: runtime_mutex_acquire }, 4, 0)
	assert sync.proves_order(older, RuntimeAccess{ event: new, begin: 5, sync_head: sync.heads[new.thread_key()] })
	reused := RuntimeSsaEvent{ ...new, thread_generation: 3 }
	assert !sync.proves_order(older, RuntimeAccess{ event: reused, begin: 6, sync_head: sync.heads[reused.thread_key()] })
	sync.apply(RuntimeSsaEvent{ ...old, kind: runtime_mutex_reset }, 7, 0)
	sync.apply(RuntimeSsaEvent{ ...reused, kind: runtime_mutex_acquire }, 8, 0)
	assert !sync.proves_order(older, RuntimeAccess{ event: reused, begin: 9, sync_head: sync.heads[reused.thread_key()] })
}

fn test_memory_order_keeps_intersecting_hooks_and_allocation_epochs_distinct() {
	mut memory := RuntimeMemoryTracker{}
	write := RuntimeSsaEvent{ kind: 6, width: 8, payload: 0x1010, thread_id: 1 }
	read := RuntimeSsaEvent{ ...write, kind: 5, thread_id: 2 }
	memory.heap.apply(RuntimeSsaEvent{
		kind:            runtime_heap_allocated
		payload:         0x1000
		allocation_size: 32
	}, 1) or { panic(err) }
	memory.begin(2, 2, write)
	memory.begin(3, 3, read)
	assert (memory.complete(2, 4) or { panic(err) }).len == 0
	assert (memory.complete(3, 5) or { panic(err) }).len == 0
	memory.begin(6, 6, read)
	assert (memory.complete(6, 7) or { panic(err) }) == {
		2: 8
	}
	memory.heap.apply(RuntimeSsaEvent{ kind: runtime_heap_realloc_begin, payload: 0x1000 }, 8) or {
		panic(err)
	}
	assert memory.heap.generation_at(0x1010) == -1
	memory.heap.apply(RuntimeSsaEvent{
		kind:            runtime_heap_realloc_end
		frame:           0x1000
		allocation_size: u64(1) << 62
	}, 9) or { panic(err) }
	assert memory.heap.generation_at(0x1010) == 1
	memory.heap.apply(RuntimeSsaEvent{ kind: runtime_heap_realloc_begin, payload: 0x1000 }, 10) or {
		panic(err)
	}
	memory.heap.apply(RuntimeSsaEvent{
		kind:            runtime_heap_realloc_end
		frame:           0x1000
		payload:         0x1000
		allocation_size: 32
	}, 11) or { panic(err) }
	memory.begin(12, 12, read)
	assert (memory.complete(12, 13) or { panic(err) }).len == 0
	report := memory.report() or { panic('missing synthetic memory order') }
	assert report.cross_thread.len == 2
	assert report.cross_thread[0].relation == 'intervals_intersect'
	assert report.cross_thread[1].relation == 'completed_before_start'
	assert report.accesses.last().allocation_generation == 11
	assert report.reuse == [RuntimeAddressReuse{
		address:          '0x1000'
		previous:         1
		current:          11
		retirement_event: 11
		allocation_event: 11
	}]
}

fn test_linux_native_ssa_observes_a_thread_handoff_and_heap_address_reuse() {
	compiler := os.getenv('VGUARD_TEST_COMPILER')
	arch := $if amd64 { 'amd64' } $else $if arm64 { 'arm64' } $else { '' }
	if compiler == '' || os.user_os() != 'linux' || arch == '' {
		return
	}
	dir := temp_directory() or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'handoff.v')
	os.write_file(source, 'module main

fn C.malloc(size u64) voidptr
fn C.calloc(count u64, size u64) voidptr
fn C.free(pointer voidptr)
fn C.pthread_mutex_init(voidptr, voidptr) int
fn C.pthread_mutex_lock(voidptr) int
fn C.pthread_mutex_unlock(voidptr) int
fn C.pthread_mutex_destroy(voidptr) int

@[noinline]
fn write_shared(pointer &u64, mutex voidptr) {
	assert C.pthread_mutex_lock(mutex) == 0
	unsafe { *pointer = 42 }
	assert C.pthread_mutex_unlock(mutex) == 0
}

@[noinline]
fn read_shared(pointer &u64) u64 {
	return unsafe { *pointer }
}

fn main() {
	first := &u64(C.malloc(32))
	assert first != unsafe { nil }
	address := uint(first)
	mut mutex := [16]u64{}
	assert C.pthread_mutex_init(&mutex[0], unsafe { nil }) == 0
	worker := spawn write_shared(first, &mutex[0])
	worker.wait()
	assert C.pthread_mutex_lock(&mutex[0]) == 0
	assert read_shared(first) == 42
	assert C.pthread_mutex_unlock(&mutex[0]) == 0
	assert C.pthread_mutex_destroy(&mutex[0]) == 0
	C.free(first)
	second := &u64(C.malloc(32))
	assert uint(second) == address
	unsafe { *second = 9 }
	assert read_shared(second) == 9
	C.free(second)
	zeroed := &u64(C.calloc(2, 8))
	assert zeroed != unsafe { nil }
	assert read_shared(zeroed) == 0
	C.free(zeroed)
}
') or { panic(err) }
	manifest := build(BuildOptions{
		source:        source
		compiler:      os.real_path(compiler)
		target:        'linux/' + arch
		backend:       arch
		trace_runtime: true
		args:          ['-gc', 'none']
	}, os.join_path(dir, 'build'), false) or { panic(err) }
	bundle := open_bundle(manifest) or { panic(err) }
	trace := os.join_path(dir, 'runtime.bin')
	os.write_file(trace, '') or { panic(err) }
	outcome := (ExecutionCase{
		env: {
			'VGUARD_SSA_TRACE_FILE': trace
		}
	}).run_binary(bundle.artifact) or {
		panic(err)
	}
	assert outcome.status == 'exited' && outcome.exit_code == 0, outcome.stderr
	base_report := ordinary_diagnosis(outcome)
	assert !json2.encode(base_report).contains('"runtime_ssa"')
	observed := bundle.read_runtime_ssa(base_report, trace) or { panic(err) }
	memory := observed.memory_order or { panic('missing recorded memory order: ${json2.encode(observed)}') }
	assert memory.evidence == 'recorded_access_intervals'
	graph := bundle.read_ssa_graph() or { panic(err) }
	reader_loads := graph.instructions.filter(it.function == 'read_shared' && it.op == 'load').map(it.id)
	mut handoff := false
	mut retirement := 0
	for pair in memory.cross_thread {
		writer := pair.earlier_begin
		reader := pair.later_begin
		if writer.address != reader.address || writer.bytes != 8 || reader.bytes != 8
			|| writer.operation != 'write' || reader.operation != 'read'
			|| reader.ssa_value !in reader_loads
			|| writer.allocation_generation == 0 || writer.allocation_generation != reader.allocation_generation
			|| !memory.reuse.any(it.address == reader.address && it.previous == reader.allocation_generation) {
			continue
		}
		assert pair.relation == 'completed_before_start'
		assert pair.synchronization == 'recorded_mutex_happens_before'
		assert writer.thread_generation != 0 && reader.thread_generation != 0
		assert writer.thread_id != reader.thread_id && writer.end_event < reader.begin_event
		reused := memory.reuse.filter(it.address == reader.address && it.previous == reader.allocation_generation)[0]
		assert reader.end_event < reused.retirement_event
		assert reused.retirement_event < reused.allocation_event
		assert memory.accesses.any(it.address == reader.address && it.operation == 'read'
			&& it.allocation_generation == reused.current && it.begin_event > reused.allocation_event)
		handoff = true
		retirement = reused.retirement_event
	}
	assert handoff, json2.encode(memory)
	assert memory.allocations.any(it.operation == 'allocated' && it.size == 16)
	ret := graph.instructions.filter(it.function == 'read_shared' && it.op == 'ret')
	assert ret.len == 1
	data := os.read_bytes(trace) or { panic(err) }
	events, truncated := decode_runtime_events(data) or { panic(err) }
	assert !truncated
	slice := runtime_ssa_slice(graph, events[..retirement - 1], ret[0].id, false) or { panic(err) }
	assert slice.dependencies.any(it.kind == 'observed_cross_thread_ordered_address_overlap'
		&& it.evidence == 'inferred_from_ordered_address_overlap' && it.overlap_bytes == 8)
	history_path := record_native_history(bundle, ExecutionCase{}, os.join_path(dir, 'history')) or { panic(err) }
	history := open_history(history_path) or { panic(err) }
	native := history.native or { panic('missing native event metadata') }
	state := replay_native_history(history_path, history, native.events) or { panic(err) }
	assert state.evidence == 'replayed_native_ssa_samples'
	order := state.ssa.memory_order or { panic('missing replayed memory order') }
	assert order.reuse.len > 0
	assert order.cross_thread.any(it.synchronization == 'recorded_mutex_happens_before')
}
