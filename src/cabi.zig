// C ABI Wrapper
//
// Provides a C-compatible interface for the Apex allocator.
// Can be used as a drop-in replacement for malloc/free.

const std = @import("std");
const heap = @import("heap.zig");
const arena_mod = @import("arena.zig");
const stats = @import("stats.zig");
const platform = @import("platform.zig");

// ============= malloc/free compatible interface =============

/// Allocate memory of given size
/// Returns null on failure
export fn apex_malloc(size: usize) ?*anyopaque {
    const ptr = heap.alloc(size) orelse return null;
    return @ptrCast(ptr);
}

/// Free previously allocated memory
/// Safe to call with null
export fn apex_free(ptr: ?*anyopaque) void {
    if (ptr) |p| {
        heap.free(@ptrCast(@alignCast(p)));
    }
}

/// Allocate zeroed memory (count * size bytes)
/// Returns null on failure
export fn apex_calloc(count: usize, size: usize) ?*anyopaque {
    const ptr = heap.calloc(count, size) orelse return null;
    return @ptrCast(ptr);
}

/// Reallocate memory to new size
/// Returns null on failure (original memory unchanged)
export fn apex_realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    if (ptr == null) {
        return apex_malloc(size);
    }

    if (size == 0) {
        apex_free(ptr);
        return null;
    }

    // For realloc, we need old_size. We'll use usable_size as approximation.
    const old_ptr: [*]u8 = @ptrCast(@alignCast(ptr.?));
    const old_size = heap.getHeap().usableSize(old_ptr);

    const new_ptr = heap.realloc(old_ptr, old_size, size) orelse return null;
    return @ptrCast(new_ptr);
}

/// Allocate aligned memory
/// alignment must be a power of 2
/// Returns null on failure
export fn apex_aligned_alloc(alignment: usize, size: usize) ?*anyopaque {
    const ptr = heap.getHeap().allocAligned(size, alignment) orelse return null;
    return @ptrCast(ptr);
}

/// Free aligned allocation
export fn apex_aligned_free(ptr: ?*anyopaque) void {
    if (ptr) |p| {
        heap.getHeap().freeAligned(@ptrCast(@alignCast(p)));
    }
}

/// POSIX memalign compatibility
export fn apex_memalign(alignment: usize, size: usize) ?*anyopaque {
    return apex_aligned_alloc(alignment, size);
}

/// POSIX posix_memalign compatibility
/// Returns 0 on success, error code on failure
export fn apex_posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) c_int {
    // Validate alignment
    if (alignment == 0 or (alignment & (alignment - 1)) != 0) {
        return 22; // EINVAL
    }
    if (alignment < @sizeOf(*anyopaque)) {
        return 22; // EINVAL
    }

    const ptr = apex_aligned_alloc(alignment, size);
    if (ptr == null and size != 0) {
        return 12; // ENOMEM
    }

    memptr.* = ptr;
    return 0;
}

/// Get usable size of allocation
export fn apex_malloc_usable_size(ptr: ?*anyopaque) usize {
    if (ptr == null) return 0;
    return heap.getHeap().usableSize(@ptrCast(@alignCast(ptr.?)));
}

// ============= Arena interface =============

/// Opaque arena handle for C
pub const ApexArena = opaque {};

/// Create a new arena allocator
export fn apex_arena_create() ?*ApexArena {
    const arena_ptr = std.heap.page_allocator.create(arena_mod.Arena) catch return null;
    arena_ptr.* = arena_mod.Arena.init();
    return @ptrCast(arena_ptr);
}

/// Create arena with custom chunk size
export fn apex_arena_create_sized(chunk_size: usize) ?*ApexArena {
    const arena_ptr = std.heap.page_allocator.create(arena_mod.Arena) catch return null;
    arena_ptr.* = arena_mod.Arena.initWithSize(chunk_size);
    return @ptrCast(arena_ptr);
}

/// Allocate from arena
export fn apex_arena_alloc(arena: ?*ApexArena, size: usize) ?*anyopaque {
    if (arena == null) return null;
    const a: *arena_mod.Arena = @ptrCast(@alignCast(arena.?));
    const ptr = a.alloc(size) orelse return null;
    return @ptrCast(ptr);
}

/// Allocate aligned from arena
export fn apex_arena_alloc_aligned(arena: ?*ApexArena, size: usize, alignment: usize) ?*anyopaque {
    if (arena == null) return null;
    const a: *arena_mod.Arena = @ptrCast(@alignCast(arena.?));
    const ptr = a.allocAligned(size, alignment) orelse return null;
    return @ptrCast(ptr);
}

/// Reset arena (free all allocations, keep memory for reuse)
export fn apex_arena_reset(arena: ?*ApexArena) void {
    if (arena == null) return;
    const a: *arena_mod.Arena = @ptrCast(@alignCast(arena.?));
    a.reset();
}

/// Destroy arena (free all memory)
export fn apex_arena_destroy(arena: ?*ApexArena) void {
    if (arena == null) return;
    const a: *arena_mod.Arena = @ptrCast(@alignCast(arena.?));
    a.deinit();
    std.heap.page_allocator.destroy(a);
}

/// Get arena statistics
export fn apex_arena_get_allocated(arena: ?*ApexArena) usize {
    if (arena == null) return 0;
    const a: *arena_mod.Arena = @ptrCast(@alignCast(arena.?));
    return a.getTotalAllocated();
}

export fn apex_arena_get_capacity(arena: ?*ApexArena) usize {
    if (arena == null) return 0;
    const a: *arena_mod.Arena = @ptrCast(@alignCast(arena.?));
    return a.getTotalCapacity();
}

// ============= Statistics interface =============

/// Statistics structure for C
pub const ApexStats = extern struct {
    total_allocated: u64,
    total_freed: u64,
    allocation_count: u64,
    in_use_bytes: u64,
    slab_allocs: u64,
    slab_active: u64,
    large_allocs: u64,
    huge_allocs: u64,
    segments_allocated: u64,
    segments_freed: u64,
};

/// Get allocator statistics
export fn apex_get_stats(out_stats: *ApexStats) void {
    const h = heap.getHeap();
    const g = stats.getGlobalStats();

    out_stats.total_allocated = h.getTotalAllocated();
    out_stats.total_freed = h.getTotalFreed();
    out_stats.allocation_count = h.getAllocationCount();
    out_stats.in_use_bytes = h.getInUseBytes();
    out_stats.slab_allocs = g.getTotalSlabAllocs();
    out_stats.slab_active = g.getActiveSlabAllocs();
    out_stats.large_allocs = g.large_alloc_count.load(.acquire);
    out_stats.huge_allocs = g.huge_alloc_count.load(.acquire);
    out_stats.segments_allocated = g.segments_allocated.load(.acquire);
    out_stats.segments_freed = g.segments_freed.load(.acquire);
}

// ============= Initialization =============

/// Initialize the allocator (optional - auto-initializes on first use)
export fn apex_init() void {
    heap.init();
}

/// Thread exit cleanup (call when a thread exits)
export fn apex_thread_exit() void {
    heap.onThreadExit();
}

// ============= NUMA Support =============

/// Get number of NUMA nodes
export fn apex_numa_node_count() usize {
    return platform.numaNodeCount();
}

/// Get current thread's NUMA node
export fn apex_numa_current_node() u8 {
    return platform.numaCurrentNode();
}

/// Allocate on specific NUMA node
export fn apex_malloc_on_node(size: usize, node: u8) ?*anyopaque {
    const ptr = platform.mapOnNode(size, std.heap.page_size_min, node) orelse return null;
    return @ptrCast(ptr);
}

// ============= Profiling Hooks =============

/// C profile event structure
pub const CProfileEvent = extern struct {
    event_type: u32,
    ptr: ?*anyopaque,
    size: usize,
    timestamp_ns: u64,
    thread_id: usize,
    numa_node: u8,
};

/// C profile callback type
pub const CProfileCallback = *const fn (CProfileEvent) callconv(.c) void;

var c_callback: ?CProfileCallback = null;

fn zigProfileCallback(event: platform.ProfileEvent) void {
    if (c_callback) |cb| {
        cb(.{
            .event_type = @intFromEnum(event.event_type),
            .ptr = if (event.ptr) |p| @ptrCast(p) else null,
            .size = event.size,
            .timestamp_ns = event.timestamp_ns,
            .thread_id = event.thread_id,
            .numa_node = event.numa_node,
        });
    }
}

/// Enable profiling with C callback
export fn apex_enable_profiling(callback: CProfileCallback) void {
    c_callback = callback;
    platform.enableProfiling(zigProfileCallback);
}

/// Disable profiling
export fn apex_disable_profiling() void {
    platform.disableProfiling();
    c_callback = null;
}

// ============= Version =============

/// Version string
export fn apex_version() [*:0]const u8 {
    return "1.0.0";
}

// ============= Tests =============

test "C ABI: malloc/free" {
    const ptr = apex_malloc(100);
    try std.testing.expect(ptr != null);

    const p: [*]u8 = @ptrCast(@alignCast(ptr.?));
    p[0] = 42;
    p[99] = 99;

    apex_free(ptr);
}

test "C ABI: calloc" {
    const ptr = apex_calloc(10, 10);
    try std.testing.expect(ptr != null);

    const p: [*]u8 = @ptrCast(@alignCast(ptr.?));
    for (p[0..100]) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }

    apex_free(ptr);
}

test "C ABI: realloc" {
    var ptr = apex_malloc(64);
    try std.testing.expect(ptr != null);

    var p: [*]u8 = @ptrCast(@alignCast(ptr.?));
    p[0] = 0xAB;

    ptr = apex_realloc(ptr, 256);
    try std.testing.expect(ptr != null);

    p = @ptrCast(@alignCast(ptr.?));
    try std.testing.expectEqual(@as(u8, 0xAB), p[0]);

    apex_free(ptr);
}

test "C ABI: aligned_alloc" {
    const alignments = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 4096 };

    for (alignments) |alignment| {
        const ptr = apex_aligned_alloc(alignment, 100);
        if (ptr) |p| {
            const addr = @intFromPtr(p);
            try std.testing.expectEqual(@as(usize, 0), addr % alignment);
            apex_aligned_free(ptr);
        }
    }
}

test "C ABI: posix_memalign" {
    var ptr: ?*anyopaque = null;

    const result = apex_posix_memalign(&ptr, 256, 100);
    try std.testing.expectEqual(@as(c_int, 0), result);
    try std.testing.expect(ptr != null);

    const addr = @intFromPtr(ptr.?);
    try std.testing.expectEqual(@as(usize, 0), addr % 256);

    apex_free(ptr);
}

test "C ABI: arena" {
    const arena = apex_arena_create();
    try std.testing.expect(arena != null);

    const p1 = apex_arena_alloc(arena, 100);
    try std.testing.expect(p1 != null);

    const p2 = apex_arena_alloc(arena, 200);
    try std.testing.expect(p2 != null);

    try std.testing.expect(apex_arena_get_allocated(arena) >= 300);

    apex_arena_reset(arena);
    try std.testing.expectEqual(@as(usize, 0), apex_arena_get_allocated(arena));

    apex_arena_destroy(arena);
}

test "C ABI: stats" {
    apex_init();

    const ptr = apex_malloc(64);
    apex_free(ptr);

    var s: ApexStats = undefined;
    apex_get_stats(&s);

    try std.testing.expect(s.allocation_count > 0);
}

test "C ABI: usable_size" {
    const ptr = apex_malloc(50);
    try std.testing.expect(ptr != null);

    const usable = apex_malloc_usable_size(ptr);
    try std.testing.expect(usable >= 50); // At least requested size

    apex_free(ptr);
}
