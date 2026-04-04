const std = @import("std");
const builtin = @import("builtin");

// Page and segment sizes
pub const PAGE_SIZE: usize = 64 * 1024; // 64KB pages
pub const SEGMENT_SIZE: usize = 2 * 1024 * 1024; // 2MB segments
pub const PAGES_PER_SEGMENT: usize = SEGMENT_SIZE / PAGE_SIZE; // 32 pages

// Segment alignment (must be 2MB for efficient lookup)
pub const SEGMENT_ALIGNMENT: usize = SEGMENT_SIZE;

// Size classes for slab allocator (bytes)
// Designed to minimize internal fragmentation while covering common sizes
pub const SIZE_CLASSES = [_]usize{
    8, 16, 32, 48, 64, 80, 96, 112, 128,
    192, 256, 384, 512, 768, 1024, 1536, 2048,
};
pub const NUM_SIZE_CLASSES: usize = SIZE_CLASSES.len;

// Allocation class thresholds (per spec 2.2)
// Small: 8-2048 bytes (slab allocation)
// Medium: 2KB-32KB (page allocation)
// Large: 32KB-2MB (segment allocation)
// Huge: >2MB (direct mmap)
pub const SMALL_THRESHOLD: usize = 2048; // Max size for slab allocation
pub const MEDIUM_THRESHOLD: usize = 32 * 1024; // Max size for page allocation
pub const LARGE_THRESHOLD: usize = SMALL_THRESHOLD; // Legacy alias
pub const HUGE_THRESHOLD: usize = SEGMENT_SIZE; // Above this = direct mmap

// Thread cache configuration
pub const THREAD_CACHE_MAX_BLOCKS: usize = 256; // Max blocks per size class in thread cache
pub const THREAD_CACHE_FILL_COUNT: usize = 32; // Blocks to fill from heap at once
pub const THREAD_CACHE_MAX_PAGES: usize = 4; // Max pages in per-thread page pool

// Segment cache configuration
pub const SEGMENT_CACHE_MAX: usize = 4; // Max cached free segments

// Huge page sizes (for huge page support)
pub const HUGE_PAGE_2MB: usize = 2 * 1024 * 1024;
pub const HUGE_PAGE_1GB: usize = 1024 * 1024 * 1024;

// Performance targets (for validation)
pub const TARGET_SMALL_ALLOC_NS: u64 = 50; // <50ns average
pub const TARGET_SMALL_FREE_NS: u64 = 30; // <30ns average
pub const TARGET_FRAGMENTATION_PCT: u64 = 20; // <20% overhead

// Platform detection
pub const Platform = enum {
    linux,
    macos,
    windows,
    other,
};

pub const current_platform: Platform = switch (builtin.os.tag) {
    .linux => .linux,
    .macos => .macos,
    .windows => .windows,
    else => .other,
};

// NUMA configuration
pub const NUMA_MAX_NODES: usize = 8;
pub const NUMA_ENABLED: bool = current_platform == .linux;

// Get size class index for a given size
pub fn sizeClassIndex(size: usize) ?usize {
    if (size == 0) return 0;
    for (SIZE_CLASSES, 0..) |class_size, i| {
        if (size <= class_size) return i;
    }
    return null; // Size too large for slab allocation
}

// Get size class for a given size
pub fn sizeClass(size: usize) ?usize {
    const idx = sizeClassIndex(size) orelse return null;
    return SIZE_CLASSES[idx];
}

// Calculate blocks per page for a size class
pub fn blocksPerPage(class_size: usize) usize {
    if (class_size == 0) return 0;
    // Reserve space for page header (64 bytes)
    const usable = PAGE_SIZE - 64;
    return usable / class_size;
}

// Determine allocation class for a size
pub const AllocClass = enum {
    small, // Slab allocation
    medium, // Page allocation
    large, // Segment allocation
    huge, // Direct mmap
};

pub fn allocClass(size: usize) AllocClass {
    if (size <= SMALL_THRESHOLD) return .small;
    if (size <= MEDIUM_THRESHOLD) return .medium;
    if (size <= HUGE_THRESHOLD) return .large;
    return .huge;
}

// Pages needed for a medium allocation
pub fn pagesForMedium(size: usize) usize {
    return (size + PAGE_SIZE - 1) / PAGE_SIZE;
}

test "size class lookup" {
    const testing = std.testing;

    try testing.expectEqual(@as(?usize, 0), sizeClassIndex(0));
    try testing.expectEqual(@as(?usize, 0), sizeClassIndex(1));
    try testing.expectEqual(@as(?usize, 0), sizeClassIndex(8));
    try testing.expectEqual(@as(?usize, 1), sizeClassIndex(9));
    try testing.expectEqual(@as(?usize, 1), sizeClassIndex(16));
    try testing.expectEqual(@as(?usize, 3), sizeClassIndex(33));
    try testing.expectEqual(@as(?usize, 3), sizeClassIndex(48));
    try testing.expectEqual(@as(?usize, 16), sizeClassIndex(2048));
    try testing.expectEqual(@as(?usize, null), sizeClassIndex(2049));
}

test "size class values" {
    const testing = std.testing;

    try testing.expectEqual(@as(?usize, 8), sizeClass(1));
    try testing.expectEqual(@as(?usize, 16), sizeClass(9));
    try testing.expectEqual(@as(?usize, 48), sizeClass(33));
    try testing.expectEqual(@as(?usize, 2048), sizeClass(2048));
    try testing.expectEqual(@as(?usize, null), sizeClass(2049));
}

test "blocks per page" {
    const testing = std.testing;

    // 64KB page - 64 byte header = 65472 bytes usable
    // 8 byte blocks: 65472 / 8 = 8184 blocks
    try testing.expectEqual(@as(usize, 8184), blocksPerPage(8));
    // 2048 byte blocks: 65472 / 2048 = 31 blocks
    try testing.expectEqual(@as(usize, 31), blocksPerPage(2048));
}

test "allocation class" {
    const testing = std.testing;

    try testing.expectEqual(AllocClass.small, allocClass(64));
    try testing.expectEqual(AllocClass.small, allocClass(2048));
    try testing.expectEqual(AllocClass.medium, allocClass(2049));
    try testing.expectEqual(AllocClass.medium, allocClass(32 * 1024));
    try testing.expectEqual(AllocClass.large, allocClass(32 * 1024 + 1));
    try testing.expectEqual(AllocClass.large, allocClass(2 * 1024 * 1024));
    try testing.expectEqual(AllocClass.huge, allocClass(2 * 1024 * 1024 + 1));
}

test "platform detection" {
    const testing = std.testing;

    // Should be one of the known platforms
    try testing.expect(current_platform == .linux or
        current_platform == .macos or
        current_platform == .windows or
        current_platform == .other);
}
