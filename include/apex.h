/*
 * Apex Memory Allocator - C API Header
 *
 * A high-performance memory allocator with:
 * - Slab allocation for small objects
 * - Thread-local caching
 * - NUMA awareness
 * - Arena allocator support
 *
 * Usage:
 *   void* ptr = apex_malloc(100);
 *   apex_free(ptr);
 */

#ifndef APEX_H
#define APEX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============= Version ============= */

#define APEX_VERSION_MAJOR 1
#define APEX_VERSION_MINOR 0
#define APEX_VERSION_PATCH 0
#define APEX_VERSION_STRING "1.0.0"

/* Returns version string */
const char* apex_version(void);

/* ============= Core Allocation ============= */

/*
 * Allocate memory of given size.
 * Returns NULL on failure.
 */
void* apex_malloc(size_t size);

/*
 * Free previously allocated memory.
 * Safe to call with NULL.
 */
void apex_free(void* ptr);

/*
 * Allocate zeroed memory (count * size bytes).
 * Returns NULL on failure.
 */
void* apex_calloc(size_t count, size_t size);

/*
 * Reallocate memory to new size.
 * Returns NULL on failure (original memory unchanged).
 */
void* apex_realloc(void* ptr, size_t size);

/* ============= Aligned Allocation ============= */

/*
 * Allocate aligned memory.
 * alignment must be a power of 2.
 * Returns NULL on failure.
 */
void* apex_aligned_alloc(size_t alignment, size_t size);

/*
 * Free aligned allocation.
 */
void apex_aligned_free(void* ptr);

/*
 * POSIX memalign compatibility.
 */
void* apex_memalign(size_t alignment, size_t size);

/*
 * POSIX posix_memalign compatibility.
 * Returns 0 on success, error code on failure.
 */
int apex_posix_memalign(void** memptr, size_t alignment, size_t size);

/*
 * Get usable size of allocation.
 */
size_t apex_malloc_usable_size(void* ptr);

/* ============= Arena Allocator ============= */

/* Opaque arena handle */
typedef struct ApexArena ApexArena;

/*
 * Create a new arena allocator.
 * Returns NULL on failure.
 */
ApexArena* apex_arena_create(void);

/*
 * Create arena with custom chunk size.
 */
ApexArena* apex_arena_create_sized(size_t chunk_size);

/*
 * Allocate from arena.
 */
void* apex_arena_alloc(ApexArena* arena, size_t size);

/*
 * Allocate aligned from arena.
 */
void* apex_arena_alloc_aligned(ApexArena* arena, size_t size, size_t alignment);

/*
 * Reset arena (free all allocations, keep memory for reuse).
 */
void apex_arena_reset(ApexArena* arena);

/*
 * Destroy arena (free all memory).
 */
void apex_arena_destroy(ApexArena* arena);

/*
 * Get bytes allocated from arena.
 */
size_t apex_arena_get_allocated(ApexArena* arena);

/*
 * Get arena capacity.
 */
size_t apex_arena_get_capacity(ApexArena* arena);

/* ============= Statistics ============= */

/* Statistics structure */
typedef struct {
    uint64_t total_allocated;
    uint64_t total_freed;
    uint64_t allocation_count;
    uint64_t in_use_bytes;
    uint64_t slab_allocs;
    uint64_t slab_active;
    uint64_t large_allocs;
    uint64_t huge_allocs;
    uint64_t segments_allocated;
    uint64_t segments_freed;
} ApexStats;

/*
 * Get allocator statistics.
 */
void apex_get_stats(ApexStats* stats);

/* ============= Lifecycle ============= */

/*
 * Initialize the allocator (optional - auto-initializes on first use).
 */
void apex_init(void);

/*
 * Thread exit cleanup (call when a thread exits).
 * Important for proper thread cache cleanup.
 */
void apex_thread_exit(void);

/* ============= NUMA Support ============= */

/*
 * Get number of NUMA nodes.
 */
size_t apex_numa_node_count(void);

/*
 * Get current thread's NUMA node.
 */
uint8_t apex_numa_current_node(void);

/*
 * Allocate on specific NUMA node.
 */
void* apex_malloc_on_node(size_t size, uint8_t node);

/* ============= Configuration ============= */

/* Size class thresholds */
#define APEX_SMALL_THRESHOLD  2048
#define APEX_MEDIUM_THRESHOLD (32 * 1024)
#define APEX_HUGE_THRESHOLD   (2 * 1024 * 1024)

/* Page and segment sizes */
#define APEX_PAGE_SIZE     (64 * 1024)
#define APEX_SEGMENT_SIZE  (2 * 1024 * 1024)

/* ============= Profiling Hooks ============= */

/* Profile event types */
typedef enum {
    APEX_EVENT_ALLOC = 0,
    APEX_EVENT_FREE = 1,
    APEX_EVENT_REALLOC = 2,
    APEX_EVENT_MMAP = 3,
    APEX_EVENT_MUNMAP = 4,
} ApexEventType;

/* Profile event structure */
typedef struct {
    ApexEventType event_type;
    void* ptr;
    size_t size;
    uint64_t timestamp_ns;
    size_t thread_id;
    uint8_t numa_node;
} ApexProfileEvent;

/* Profile callback type */
typedef void (*ApexProfileCallback)(ApexProfileEvent event);

/*
 * Enable profiling with callback.
 */
void apex_enable_profiling(ApexProfileCallback callback);

/*
 * Disable profiling.
 */
void apex_disable_profiling(void);

#ifdef __cplusplus
}
#endif

#endif /* APEX_H */
