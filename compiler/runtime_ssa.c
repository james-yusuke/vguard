#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#endif

enum {
    max_events = 65536, limit_event = 8,
    heap_allocated = 9, heap_free_begin = 10, heap_free_end = 11,
    heap_realloc_begin = 12, heap_realloc_end = 13,
    thread_started = 14, mutex_acquired = 15, mutex_released = 16, mutex_reset = 17
};
static pthread_once_t trace_once = PTHREAD_ONCE_INIT;
static atomic_uint trace_position;
static int trace_fd = -1;
#ifdef __linux__
static int thread_fd = -1;
#endif
static atomic_uint next_thread;
static _Thread_local unsigned trace_thread;

static void open_trace(void) {
    const char *path = getenv("VGUARD_SSA_TRACE_FILE");
    if (path && *path)
        trace_fd = open(path, O_WRONLY | O_APPEND | O_CLOEXEC);
#ifdef __linux__
    const char *threads = getenv("VGUARD_SSA_THREADS_FILE");
    if (trace_fd >= 0 && threads && *threads)
        thread_fd = open(threads, O_WRONLY | O_APPEND | O_CLOEXEC);
#endif
}

static int append_record(int fd, const uint64_t *data, size_t bytes) {
    ssize_t written;
    do {
        written = write(fd, data, bytes);
    } while (written < 0 && errno == EINTR);
    return written == (ssize_t)bytes;
}

static int write_event(uint64_t kind, uint64_t id, uintptr_t frame,
                        uint64_t payload, uint64_t width) {
    if (atomic_load_explicit(&trace_position, memory_order_relaxed) <= max_events) {
        unsigned position = atomic_fetch_add_explicit(&trace_position, 1, memory_order_relaxed);
        if (position <= max_events) {
            const uint64_t data[] = {
                (uint64_t)getpid(), (uintptr_t)pthread_self(), frame,
                position == max_events ? limit_event : kind, id, payload, width
            };
            return append_record(trace_fd, data, sizeof data) && position < max_events;
        }
    }
    return 0;
}

void vguard_ssa_event(uint64_t kind, uint64_t id, uintptr_t frame,
                     uint64_t payload, uint64_t width) {
    int saved_errno = errno;
    pthread_once(&trace_once, open_trace);
    if (trace_fd >= 0) {
        if (!trace_thread) {
            trace_thread = atomic_fetch_add_explicit(&next_thread, 1, memory_order_relaxed) + 1;
            int started = write_event(thread_started, trace_thread, 0, 0, 0);
#ifdef __linux__
            if (started && thread_fd >= 0) {
                long tid = syscall(SYS_gettid);
                if (tid > 0) {
                    const uint64_t identity[] = {
                        (uint64_t)getpid(), (uint64_t)tid,
                        (uintptr_t)pthread_self(), trace_thread
                    };
                    append_record(thread_fd, identity, sizeof identity);
                }
            }
#else
            (void)started;
#endif
        }
        write_event(kind, id, frame, payload, width);
    }
    errno = saved_errno;
}

#ifdef __linux__
void *__real_malloc(size_t);
void *__real_calloc(size_t, size_t);
void *__real_realloc(void *, size_t);
void __real_free(void *);
int __real_pthread_mutex_lock(pthread_mutex_t *);
int __real_pthread_mutex_trylock(pthread_mutex_t *);
int __real_pthread_mutex_unlock(pthread_mutex_t *);
int __real_pthread_mutex_init(pthread_mutex_t *, const pthread_mutexattr_t *);
int __real_pthread_mutex_destroy(pthread_mutex_t *);

// Keep the allocator operation and its boundary records in the same order.
// References inside shared libraries may bypass these executable-level hooks.
static pthread_mutex_t heap_lock = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local int inside_heap_hook;

static int lock_traced_heap(void) {
    if (inside_heap_hook)
        return 0;
    inside_heap_hook = 1;
    int saved_errno = errno;
    pthread_once(&trace_once, open_trace);
    int tracing = trace_fd >= 0;
    if (tracing)
        __real_pthread_mutex_lock(&heap_lock);
    else
        inside_heap_hook = 0;
    errno = saved_errno;
    return tracing;
}

static void unlock_traced_heap(void) {
    int saved_errno = errno;
    __real_pthread_mutex_unlock(&heap_lock);
    inside_heap_hook = 0;
    errno = saved_errno;
}

void *__wrap_malloc(size_t size) {
    int tracing = lock_traced_heap();
    void *result = __real_malloc(size);
    if (tracing) {
        if (result)
            vguard_ssa_event(heap_allocated, size, 0, (uintptr_t)result, 0);
        unlock_traced_heap();
    }
    return result;
}

void *__wrap_calloc(size_t count, size_t size) {
    int tracing = lock_traced_heap();
    void *result = __real_calloc(count, size);
    if (tracing) {
        if (result && (!size || count <= SIZE_MAX / size))
            vguard_ssa_event(heap_allocated, count * size, 0, (uintptr_t)result, 0);
        unlock_traced_heap();
    }
    return result;
}

void __wrap_free(void *pointer) {
    uintptr_t address = (uintptr_t)pointer;
    int tracing = address && lock_traced_heap();
    if (tracing)
        vguard_ssa_event(heap_free_begin, 0, 0, address, 0);
    __real_free(pointer);
    if (tracing) {
        vguard_ssa_event(heap_free_end, 0, 0, address, 0);
        unlock_traced_heap();
    }
}

void *__wrap_realloc(void *pointer, size_t size) {
    uintptr_t address = (uintptr_t)pointer;
    int tracing = lock_traced_heap();
    if (tracing && address)
        vguard_ssa_event(heap_realloc_begin, 0, 0, address, 0);
    void *result = __real_realloc(pointer, size);
    if (tracing) {
        vguard_ssa_event(heap_realloc_end, size, address, (uintptr_t)result, 0);
        unlock_traced_heap();
    }
    return result;
}

// Serialize publication of a successful unlock with publication of acquisitions.
// The gate is never held while waiting for an application mutex.
static pthread_mutex_t mutex_events_lock = PTHREAD_MUTEX_INITIALIZER;

static void record_mutex_acquisition(pthread_mutex_t *mutex, int result) {
    if (result || trace_fd < 0)
        return;
    __real_pthread_mutex_lock(&mutex_events_lock);
    vguard_ssa_event(mutex_acquired, 0, 0, (uintptr_t)mutex, 0);
    __real_pthread_mutex_unlock(&mutex_events_lock);
}

int __wrap_pthread_mutex_lock(pthread_mutex_t *mutex) {
    pthread_once(&trace_once, open_trace);
    int result = __real_pthread_mutex_lock(mutex);
    record_mutex_acquisition(mutex, result);
    return result;
}

int __wrap_pthread_mutex_trylock(pthread_mutex_t *mutex) {
    pthread_once(&trace_once, open_trace);
    int result = __real_pthread_mutex_trylock(mutex);
    record_mutex_acquisition(mutex, result);
    return result;
}

static int mutex_boundary(pthread_mutex_t *mutex, const pthread_mutexattr_t *attributes, int operation) {
    pthread_once(&trace_once, open_trace);
    int tracing = trace_fd >= 0;
    if (tracing)
        __real_pthread_mutex_lock(&mutex_events_lock);
    int result;
    switch (operation) {
        case 0: result = __real_pthread_mutex_init(mutex, attributes); break;
        case 1: result = __real_pthread_mutex_destroy(mutex); break;
        default: result = __real_pthread_mutex_unlock(mutex); break;
    }
    if (tracing) {
        if (!result)
            vguard_ssa_event(operation == 2 ? mutex_released : mutex_reset, 0, 0,
                             (uintptr_t)mutex, 0);
        __real_pthread_mutex_unlock(&mutex_events_lock);
    }
    return result;
}

int __wrap_pthread_mutex_init(pthread_mutex_t *mutex, const pthread_mutexattr_t *attributes) {
    return mutex_boundary(mutex, attributes, 0);
}

int __wrap_pthread_mutex_destroy(pthread_mutex_t *mutex) {
    return mutex_boundary(mutex, NULL, 1);
}

int __wrap_pthread_mutex_unlock(pthread_mutex_t *mutex) {
    return mutex_boundary(mutex, NULL, 2);
}
#endif
