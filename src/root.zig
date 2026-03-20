// Apex - High-performance memory allocator
//
// A modern slab allocator with thread caching, inspired by mimalloc and jemalloc.
// Designed for low fragmentation and high throughput.

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

// Stress tests (test-only)
test {
    _ = @import("tests.zig");
}

// Re-export commonly used items
pub const PAGE_SIZE = config.PAGE_SIZE;
pub const SEGMENT_SIZE = config.SEGMENT_SIZE;
pub const SIZE_CLASSES = config.SIZE_CLASSES;

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

// ============= Initialization =============

/// Initialize the allocator (called automatically on first use)
pub fn init() void {
    heap.init();
}

/// Get the global heap
pub fn getHeap() *heap.Heap {
    return heap.getHeap();
}

// Run all tests
test {
    const std = @import("std");
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
    const std = @import("std");
    var ptr = alloc(64) orelse return error.AllocFailed;
    ptr[0] = 42;

    ptr = realloc(ptr, 64, 256) orelse return error.AllocFailed;
    try std.testing.expectEqual(@as(u8, 42), ptr[0]);

    free(ptr);
}

test "public calloc" {
    const std = @import("std");
    const ptr = calloc(10, 10) orelse return error.AllocFailed;
    // Should be zeroed
    for (ptr[0..100]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
    free(ptr);
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
