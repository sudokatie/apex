// Apex - High-performance memory allocator
//
// A modern slab allocator with thread caching, inspired by mimalloc and jemalloc.
// Designed for low fragmentation and high throughput.

const std = @import("std");
pub const config = @import("config.zig");

// Platform abstraction (OS-specific memory operations)
pub const platform = @import("platform.zig");

// Core allocator
pub const segment = @import("segment.zig");
pub const page = @import("page.zig");
pub const slab = @import("slab.zig");
pub const large = @import("large.zig");
pub const thread_cache = @import("thread_cache.zig");
pub const heap = @import("heap.zig");
pub const arena = @import("arena.zig");
pub const stats = @import("stats.zig");

// C ABI wrapper
pub const cabi = @import("cabi.zig");

// Stress tests (test-only)
test {
    _ = @import("tests.zig");
}

// Re-export commonly used items
pub const PAGE_SIZE = config.PAGE_SIZE;
pub const SEGMENT_SIZE = config.SEGMENT_SIZE;
pub const SIZE_CLASSES = config.SIZE_CLASSES;

// Build configuration re-exports
pub const BuildMode = heap.BuildMode;
pub const build_mode = heap.build_mode;
pub const enable_stats = heap.enable_stats;
pub const enable_bounds_check = heap.enable_bounds_check;
pub const enable_logging = heap.enable_logging;

// ============= Public Allocator Interface =============

/// Allocate memory of given size
pub fn alloc(size: usize) ?[*]u8 {
    return heap.alloc(size);
}

/// Free previously allocated memory
pub fn free(ptr: ?[*]u8) void {
    heap.free(ptr);
}

/// Reallocate memory to new size
pub fn realloc(ptr: ?[*]u8, old_size: usize, new_size: usize) ?[*]u8 {
    return heap.realloc(ptr, old_size, new_size);
}

/// Allocate zeroed memory (count * size bytes)
pub fn calloc(count: usize, size: usize) ?[*]u8 {
    return heap.calloc(count, size);
}

/// Allocate memory with specific alignment
pub fn allocAligned(size: usize, alignment: usize) ?[*]u8 {
    return heap.getHeap().allocAligned(size, alignment);
}

/// Free aligned allocation
pub fn freeAligned(ptr: ?[*]u8) void {
    heap.getHeap().freeAligned(ptr);
}

// ============= Arena Allocator Interface =============

/// Create a new arena allocator
pub fn createArena() arena.Arena {
    return arena.Arena.init();
}

/// Create arena with custom chunk size
pub fn createArenaWithSize(chunk_size: usize) arena.Arena {
    return arena.Arena.initWithSize(chunk_size);
}

/// Allocate memory from arena
pub fn arenaAlloc(a: *arena.Arena, size: usize) ?[*]u8 {
    return a.alloc(size);
}

/// Allocate aligned memory from arena
pub fn arenaAllocAligned(a: *arena.Arena, size: usize, alignment: usize) ?[*]u8 {
    return a.allocAligned(size, alignment);
}

/// Reset arena (keep chunks, reset offsets)
pub fn arenaReset(a: *arena.Arena) void {
    a.reset();
}

/// Destroy arena and free all memory
pub fn destroyArena(a: *arena.Arena) void {
    a.deinit();
}

// ============= Statistics Interface =============

/// Get global allocator statistics
pub fn getStats() *stats.GlobalStats {
    return stats.getGlobalStats();
}

/// Print statistics summary to writer
pub fn printStats(writer: anytype) !void {
    try getStats().printSummary(writer);
}

/// Export statistics as JSON
pub fn statsToJson(writer: anytype) !void {
    try getStats().toJson(writer);
}

/// Get fragmentation percentage
pub fn getFragmentation() f64 {
    return getStats().getFragmentationPercent();
}

/// Get cache hit rate (0.0-1.0)
pub fn getCacheHitRate() f64 {
    return getStats().getCacheHitRate();
}

// ============= NUMA Interface =============

/// Get number of NUMA nodes
pub fn numaNodeCount() usize {
    return platform.numaNodeCount();
}

/// Get current thread's NUMA node
pub fn numaCurrentNode() u8 {
    return platform.numaCurrentNode();
}

/// Allocate on specific NUMA node
pub fn allocOnNode(size: usize, node: u8) ?[*]u8 {
    return platform.mapOnNode(size, std.heap.page_size_min, node);
}

/// Check if NUMA is available
pub fn numaAvailable() bool {
    return platform.numaNodeCount() > 1;
}

// ============= Huge Page Interface =============

/// Check if huge pages are available
pub fn hugePageAvailable() bool {
    return platform.hugePageAvailable(config.HUGE_PAGE_2MB);
}

/// Allocate using huge pages (falls back to regular if unavailable)
pub fn allocHugePages(size: usize) ?[*]u8 {
    return platform.mapHugePages(size, config.HUGE_PAGE_2MB);
}

// ============= Profiling Interface =============

pub const ProfileEvent = platform.ProfileEvent;
pub const ProfileCallback = platform.ProfileCallback;

/// Enable memory profiling
pub fn enableProfiling(callback: ProfileCallback) void {
    platform.enableProfiling(callback);
}

/// Disable memory profiling
pub fn disableProfiling() void {
    platform.disableProfiling();
}

/// Check if profiling is enabled
pub fn isProfilingEnabled() bool {
    return platform.isProfilingEnabled();
}

// ============= Initialization =============

/// Initialize the allocator (called automatically on first use)
pub fn init() void {
    heap.init();
}

/// Get the global heap
pub fn getHeap() *heap.Heap {
    return heap.getHeap();
}

/// Thread exit cleanup - call when a thread exits
pub fn onThreadExit() void {
    heap.onThreadExit();
}

// Run all tests
test {
    std.testing.refAllDecls(@This());
}

// ============= Tests =============

test "public alloc/free" {
    const ptr = alloc(128) orelse return error.AllocFailed;
    ptr[0] = 42;
    ptr[127] = 99;
    free(ptr);
}

test "public realloc" {
    var ptr = alloc(64) orelse return error.AllocFailed;
    ptr[0] = 42;

    ptr = realloc(ptr, 64, 256) orelse return error.AllocFailed;
    try std.testing.expectEqual(@as(u8, 42), ptr[0]);

    free(ptr);
}

test "public calloc" {
    const ptr = calloc(10, 10) orelse return error.AllocFailed;
    // Should be zeroed
    for (ptr[0..100]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
    free(ptr);
}

test "public aligned alloc" {
    const alignments = [_]usize{ 32, 64, 128, 256, 512, 1024 };
    for (alignments) |alignment| {
        const ptr = allocAligned(100, alignment) orelse continue;
        const addr = @intFromPtr(ptr);
        try std.testing.expectEqual(@as(usize, 0), addr % alignment);
        freeAligned(ptr);
    }
}

test "arena interface" {
    var a = createArena();
    defer destroyArena(&a);

    const p1 = arenaAlloc(&a, 100) orelse return error.AllocFailed;
    const p2 = arenaAlloc(&a, 200) orelse return error.AllocFailed;

    p1[0] = 1;
    p2[0] = 2;

    arenaReset(&a);

    // Can allocate again after reset
    const p3 = arenaAlloc(&a, 50) orelse return error.AllocFailed;
    p3[0] = 3;
}

test "stats interface" {
    const s = getStats();
    _ = s.getTotalSlabAllocs();
    _ = s.getActiveSlabAllocs();
}

test "build mode" {
    // Verify build mode is set
    _ = build_mode;
    _ = enable_stats;
    _ = enable_bounds_check;
    _ = enable_logging;
}
