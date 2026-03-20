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

// Re-export commonly used items
pub const PAGE_SIZE = config.PAGE_SIZE;
pub const SEGMENT_SIZE = config.SEGMENT_SIZE;
pub const SIZE_CLASSES = config.SIZE_CLASSES;

// Public allocator interface (stub)
pub fn alloc(size: usize) ?[*]u8 {
    _ = size;
    return null; // TODO: implement
}

pub fn free(ptr: ?[*]u8) void {
    _ = ptr; // TODO: implement
}

pub fn realloc(ptr: ?[*]u8, old_size: usize, new_size: usize) ?[*]u8 {
    _ = ptr;
    _ = old_size;
    _ = new_size;
    return null; // TODO: implement
}

// Run all tests
test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
