module main

const runtime_thread_start = 14
const runtime_mutex_acquire = 15
const runtime_mutex_release = 16
const runtime_mutex_reset = 17

struct RuntimeSyncEvent {
	thread   string
	previous int
	handoff  int
}

struct RuntimeSynchronization {
mut:
	heads    map[string]int
	releases map[string]int
	events   map[int]RuntimeSyncEvent
}

fn (mut sync RuntimeSynchronization) apply(event RuntimeSsaEvent, sequence int, generation int) {
	if generation < 0 {
		return
	}
	mutex := '${event.payload}:${generation}'
	if event.kind == runtime_mutex_reset {
		sync.releases.delete(mutex)
		return
	}
	identity := event.thread_key()
	handoff := if event.kind == runtime_mutex_acquire { sync.releases[mutex] } else { 0 }
	sync.events[sequence] = RuntimeSyncEvent{ thread: identity, previous: sync.heads[identity], handoff: handoff }
	sync.heads[identity] = sequence
	if event.kind == runtime_mutex_release {
		sync.releases[mutex] = sequence
	}
}

fn (sync &RuntimeSynchronization) proves_order(older RuntimeAccess, newer RuntimeAccess) bool {
	if older.end <= 0 || older.end >= newer.begin || newer.sync_head <= 0 {
		return false
	}
	identity := older.event.thread_key()
	mut pending := [newer.sync_head]
	mut seen := map[int]bool{}
	for pending.len > 0 && seen.len < 4096 {
		id := pending.pop()
		if id <= older.end || id in seen {
			continue
		}
		seen[id] = true
		event := sync.events[id]
		if event.thread == identity {
			return true
		}
		pending << event.previous
		pending << event.handoff
	}
	return false
}
