module main

const runtime_heap_allocated = 9
const runtime_heap_free_begin = 10
const runtime_heap_free_end = 11
const runtime_heap_realloc_begin = 12
const runtime_heap_realloc_end = 13
const runtime_memory_report_limit = 512

struct RuntimeAllocation {
	address    string
	size       u64
	generation int
	event      int
	operation  string
}

struct RuntimeAddressReuse {
	address          string
	previous         int
	current          int
	retirement_event int
	allocation_event int
}

struct RuntimeHeapRegion {
	generation int
	size       u64
mut:
	pending bool
}

struct RuntimeRetiredRegion {
	generation int
	event      int
}

struct RuntimeHeap {
mut:
	bases      []u64
	live       map[u64]RuntimeHeapRegion
	retired    map[u64]RuntimeRetiredRegion
	operations []RuntimeAllocation
	reuse      []RuntimeAddressReuse
	truncated  bool
}

fn runtime_lower_bound(bases []u64, address u64) int {
	mut lo := 0
	mut hi := bases.len
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if bases[mid] < address {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

fn (heap &RuntimeHeap) generation_at(address u64) int {
	mut index := runtime_lower_bound(heap.bases, address)
	if index == heap.bases.len || heap.bases[index] != address {
		index--
	}
	if index < 0 {
		return 0
	}
	base := heap.bases[index]
	region := heap.live[base]
	if address - base >= region.size {
		return 0
	}
	return if region.pending { -region.generation } else { region.generation }
}

fn (mut heap RuntimeHeap) record(address u64, region RuntimeHeapRegion, event int, operation string) {
	if heap.operations.len >= runtime_memory_report_limit {
		heap.truncated = true
		return
	}
	heap.operations << RuntimeAllocation{
		address:    hex_address(address)
		size:       region.size
		generation: region.generation
		event:      event
		operation:  operation
	}
}

fn (mut heap RuntimeHeap) remove(address u64) ?RuntimeHeapRegion {
	region := heap.live[address] or { return none }
	heap.bases.delete(runtime_lower_bound(heap.bases, address))
	heap.live.delete(address)
	return region
}

fn (mut heap RuntimeHeap) retire(address u64, event int, operation string, observed bool) {
	region := heap.remove(address) or { return }
	if observed {
		heap.retired[address] = RuntimeRetiredRegion{ generation: region.generation, event: event }
	}
	heap.record(address, region, event, operation)
}

fn (mut heap RuntimeHeap) allocate(address u64, size u64, event int, operation string) ! {
	if address == 0 || (size > 0 && size - 1 > u64(-1) - address) {
		return error('invalid native heap allocation extent')
	}
	// A call outside the executable can release an observed allocation without
	// a hook. A new allocation still establishes a fresh lifetime.
	if address in heap.live {
		heap.retire(address, event, 'previous_lifetime_unobserved', false)
	}
	mut index := runtime_lower_bound(heap.bases, address)
	if index > 0 && address - heap.bases[index - 1] < heap.live[heap.bases[index - 1]].size {
		heap.retire(heap.bases[index - 1], event, 'previous_lifetime_unobserved', false)
		index--
	}
	for index < heap.bases.len && heap.bases[index] - address < size {
		heap.retire(heap.bases[index], event, 'previous_lifetime_unobserved', false)
	}
	heap.bases.insert(index, address)
	region := RuntimeHeapRegion{ size: size, generation: event }
	heap.live[address] = region
	heap.record(address, region, event, operation)
	if retired := heap.retired[address] {
		if heap.reuse.len < runtime_memory_report_limit {
			heap.reuse << RuntimeAddressReuse{
				address:          hex_address(address)
				previous:         retired.generation
				current:          event
				retirement_event: retired.event
				allocation_event: event
			}
		} else {
			heap.truncated = true
		}
		heap.retired.delete(address)
	}
}

fn (mut heap RuntimeHeap) apply(event RuntimeSsaEvent, sequence int) ! {
	address := event.payload
	match event.kind {
		runtime_heap_allocated {
			heap.allocate(address, event.allocation_size, sequence, 'allocated')!
		}
		runtime_heap_free_begin, runtime_heap_realloc_begin {
			if address in heap.live {
				heap.live[address].pending = true
			}
		}
		runtime_heap_free_end {
			heap.retire(address, sequence, 'freed', true)
		}
		runtime_heap_realloc_end {
			previous := event.frame
			if address != 0 {
				if previous != 0 {
					heap.retire(previous, sequence, 'reallocated', true)
				}
				heap.allocate(address, event.allocation_size, sequence, 'allocated_by_realloc')!
			} else if previous != 0 && event.allocation_size == 0 {
				// A null zero-size realloc does not have uniform free semantics.
				heap.retire(previous, sequence, 'zero_size_realloc_lifetime_unknown', false)
			} else if previous in heap.live {
				heap.live[previous].pending = false
				heap.record(previous, heap.live[previous], sequence, 'realloc_failed')
			}
		}
		else {}
	}
}
