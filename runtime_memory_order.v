module main

struct RuntimeMemoryInterval {
	ssa_value             int
	thread_id             string
	thread_generation     u64 @[omitempty]
	operation             string
	address               string
	bytes                 int
	begin_event           int
	end_event             int @[omitempty]
	allocation_generation int @[omitempty]
}

struct RuntimeMemoryOrderPair {
	earlier_begin   RuntimeMemoryInterval
	later_begin     RuntimeMemoryInterval
	relation        string
	synchronization string @[omitempty]
}

struct RuntimeMemoryReport {
	evidence     string = 'recorded_access_intervals'
	accesses     []RuntimeMemoryInterval
	cross_thread []RuntimeMemoryOrderPair @[omitempty]
	allocations  []RuntimeAllocation      @[omitempty]
	reuse        []RuntimeAddressReuse    @[omitempty]
	truncated    bool
}

struct RuntimeAccess {
	event     RuntimeSsaEvent
	begin     int
	sync_head int
mut:
	generations []int
	candidates  []int
	end         int
}

struct RuntimeMemoryByte {
mut:
	last_reader      int
	last_writer      int
	completed_writer int
	active_writers   int
	writer_overlap   bool
}

struct RuntimeAccessPair {
	older int
	newer int
}

struct RuntimeMemoryTracker {
mut:
	heap      RuntimeHeap
	sync      RuntimeSynchronization
	by_byte   map[u64]RuntimeMemoryByte
	accesses  map[int]RuntimeAccess
	pairs     []RuntimeAccessPair
	truncated bool
}

fn (mut memory RuntimeMemoryTracker) begin(node int, sequence int, event RuntimeSsaEvent) {
	mut access := RuntimeAccess{
		event:       event
		begin:       sequence
		sync_head:   memory.sync.heads[event.thread_key()]
		generations: []int{len: event.width}
		candidates:  []int{len: event.width}
	}
	mut pairs := map[int]bool{}
	for byte in 0 .. event.width {
		address := event.payload + u64(byte)
		generation := memory.heap.generation_at(address)
		access.generations[byte] = generation
		mut state := memory.by_byte[address]
		for prior in [state.last_writer, if event.kind == 6 { state.last_reader } else { 0 }] {
			if prior == 0 || generation < 0 {
				continue
			}
			earlier := memory.accesses[prior]
			if earlier.event.thread_key() != event.thread_key()
				&& earlier.generations[int(address - earlier.event.payload)] == generation {
				pairs[prior] = true
			}
		}
		if event.kind == 6 {
			if state.active_writers == 0 {
				state.writer_overlap = false
			} else {
				state.writer_overlap = true
				state.completed_writer = 0
			}
			state.last_writer = node
			state.active_writers++
		} else {
			state.last_reader = node
			if generation >= 0 && state.active_writers == 0 && state.completed_writer != 0 {
				earlier := memory.accesses[state.completed_writer]
				if earlier.generations[int(address - earlier.event.payload)] == generation {
					access.candidates[byte] = state.completed_writer
				}
			}
		}
		memory.by_byte[address] = state
	}
	memory.accesses[node] = access
	for prior in pairs.keys().sorted() {
		if memory.pairs.len >= runtime_memory_report_limit {
			memory.truncated = true
			break
		}
		memory.pairs << RuntimeAccessPair{ older: prior, newer: node }
	}
}

fn (mut memory RuntimeMemoryTracker) complete(node int, sequence int) !map[int]int {
	mut access := memory.accesses[node] or { return error('native SSA access completed without an address') }
	if access.end != 0 {
		return error('duplicate native SSA access completion')
	}
	mut candidates := map[int]int{}
	for byte in 0 .. access.event.width {
		address := access.event.payload + u64(byte)
		generation := memory.heap.generation_at(address)
		same_lifetime := generation >= 0 && generation == access.generations[byte]
		mut state := memory.by_byte[address]
		if access.event.kind == 6 {
			state.active_writers--
			if same_lifetime && !state.writer_overlap {
				state.completed_writer = node
			}
			memory.by_byte[address] = state
		} else {
			prior := access.candidates[byte]
			// A write that started after this read's first hook may have raced
			// with the read, even when it is complete at the second hook.
			if prior != 0 && same_lifetime && state.last_writer == prior {
				candidates[prior]++
			}
		}
	}
	access.end = sequence
	memory.accesses[node] = access
	return candidates
}

fn (access RuntimeAccess) report_interval() RuntimeMemoryInterval {
	first := access.generations[0]
	generation := if first > 0 && access.generations.all(it == first) { first } else { 0 }
	return RuntimeMemoryInterval{
		ssa_value:             access.event.id
		thread_id:             hex_address(access.event.thread_id)
		thread_generation:     access.event.thread_generation
		operation:             if access.event.kind == 5 { 'read' } else { 'write' }
		address:               hex_address(access.event.payload)
		bytes:                 access.event.width
		begin_event:           access.begin
		end_event:             access.end
		allocation_generation: generation
	}
}

fn (memory &RuntimeMemoryTracker) report() ?RuntimeMemoryReport {
	if memory.accesses.len == 0 && memory.heap.operations.len == 0 {
		return none
	}
	mut accesses := []RuntimeMemoryInterval{}
	keys := memory.accesses.keys().sorted()
	start := if keys.len > runtime_memory_report_limit {
		keys.len - runtime_memory_report_limit
	} else {
		0
	}
	for key in keys[start..] {
		accesses << memory.accesses[key].report_interval()
	}
	mut pairs := []RuntimeMemoryOrderPair{}
	for pair in memory.pairs {
		older := memory.accesses[pair.older]
		newer := memory.accesses[pair.newer]
		relation := if older.end > 0 && older.end < newer.begin {
			'completed_before_start'
		} else {
			'intervals_intersect'
		}
		pairs << RuntimeMemoryOrderPair{
			earlier_begin:   older.report_interval()
			later_begin:     newer.report_interval()
			relation:        relation
			synchronization: if memory.sync.proves_order(older, newer) {
				'recorded_mutex_happens_before'
			} else {
				''
			}
		}
	}
	return RuntimeMemoryReport{
		accesses:     accesses
		cross_thread: pairs
		allocations:  memory.heap.operations
		reuse:        memory.heap.reuse
		truncated:    start > 0 || memory.truncated || memory.heap.truncated
	}
}
