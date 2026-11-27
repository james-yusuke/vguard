#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

void __sanitizer_cov_trace_pc(void) {}

static void record_memory(const void *address, const void *pc, unsigned size, char operation) {
    int saved_errno = errno;
    Dl_info image;
    if (dladdr(pc, &image) && (uintptr_t)pc >= (uintptr_t)image.dli_fbase) {
        uintptr_t offset = (uintptr_t)pc - (uintptr_t)image.dli_fbase;
        fprintf(stderr, "\036VGUARD\tmemory\t%c\t%u\t0x%" PRIxPTR "\t0x%" PRIxPTR
                        "\t%lu\t%" PRIuPTR "\n",
                operation, size, (uintptr_t)address, offset, (unsigned long)getpid(),
                (uintptr_t)pthread_self());
    }
    errno = saved_errno;
}

// Clang inserts these callbacks immediately before the corresponding IR access.
#define CALLBACK(name, width, operation) \
    void __sanitizer_cov_##name##width(void *address) { \
        record_memory(address, __builtin_extract_return_addr(__builtin_return_address(0)), \
                      width, operation); \
    }

#define CALLBACKS(width) \
    CALLBACK(load, width, 'r') \
    CALLBACK(store, width, 'w')

CALLBACKS(1)
CALLBACKS(2)
CALLBACKS(4)
CALLBACKS(8)
CALLBACKS(16)
