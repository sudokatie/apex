// Heap Coordinator
//
// Global allocator state that coordinates all subsystems.
// Provides the public allocation interface.

const std = @import("std");
const config = @import("config.zig");
const segment_mod = @import("segment.zig");
const page_mod = @import("page.zig");
const slab_mod = @import("slab.zig");
const large_mod = @import("large.zig");
const thread_cache_mod = @import("thread_cache.zig");
const platform = @import("platform.zig");

const Atomic = std.atomic.Value;

// Global heap state
pub const Heap = struct {
    // Segment cache (shared by slab and large allocators)
    segment_cache: segment_mod.SegmentCache,

    // Slab allocator for small allocations
    slab: slab_mod.SlabAllocator,

    // Large allocator for big allocations
    large: large_mod.LargeAllocator,

    // Allocation statistics
    total_allocated: Atomic(usize),
    total_freed: Atomic(usize),
    allocation_count: Atomic(usize),

    // Initialization flag
    initialized: bool,

    const Self = @This();

    pub fn init() Self {
        return .{
            .segment_cache = segment_mod.SegmentCache.init(),
            .slab = undefined, // Will be set in initAllocators
            .large = undefined, // Will be set in initAllocators
            .total_allocated = Atomic(usize).init(0),
            .total_freed = Atomic(usize).init(0),
            .allocation_count = Atomic(usize).init(0),
            .initialized = false,
        };
    }

    // Must be called after init to set up allocators with correct pointers
    pub fn initAllocators(self: *Self) void {
        self.slab = slab_mod.SlabAllocator.init(&self.segment_cache);
        self.large = large_mod.LargeAllocator.init(&self.segment_cache);
        self.initialized = true;
    }

    // Main allocation entry point
    pub fn alloc(self: *Self, size: usize) ?[*]u8 {
        if (size == 0) return null;

        const ptr = if (size <= config.LARGE_THRESHOLD)
            self.slab.alloc(size)
        else
            self.large.alloc(size);

        if (ptr != null) {
            _ = self.total_allocated.fetchAdd(size, .monotonic);
            _ = self.allocation_count.fetchAdd(1, .monotonic);
        }

        return ptr;
    }

    // Allocation with alignment
    pub fn allocAligned(self: *Self, size: usize, alignment: usize) ?[*]u8 {
        // For now, rely on natural alignment from size classes
        // TODO: proper aligned allocation
        _ = alignment;
        return self.alloc(size);
    }

    // Free memory
    pub fn free(self: *Self, ptr: ?[*]u8) void {
        const p = ptr orelse return;

        // Determine allocation type from pointer
        const page = page_mod.pageFromPtr(@ptrCast(p));

        switch (page.state) {
            .slab => {
                const size = config.SIZE_CLASSES[page.size_class];
                self.slab.free(p);
                _ = self.total_freed.fetchAdd(size, .monotonic);
            },
            .large => {
                self.large.free(p);
                _ = self.total_freed.fetchAdd(page_mod.Page.USABLE_SIZE, .monotonic);
            },
            else => {
                // Might be a huge allocation
                self.large.free(p);
            },
        }
    }

    // Realloc
    pub fn realloc(self: *Self, ptr: ?[*]u8, old_size: usize, new_size: usize) ?[*]u8 {
        const p = ptr orelse return self.alloc(new_size);

        if (new_size == 0) {
            self.free(p);
            return null;
        }

        // Check if we can keep the same allocation
        const page = page_mod.pageFromPtr(@ptrCast(p));
        if (page.state == .slab) {
            const class_size = config.SIZE_CLASSES[page.size_class];
            if (new_size <= class_size) {
                // Fits in current size class
                return p;
            }
        }

        // Need to allocate new and copy
        const new_ptr = self.alloc(new_size) orelse return null;
        const copy_size = @min(old_size, new_size);
        @memcpy(new_ptr[0..copy_size], p[0..copy_size]);
        self.free(p);

        return new_ptr;
    }

    // Calloc (allocate zeroed memory)
    pub fn calloc(self: *Self, count: usize, size: usize) ?[*]u8 {
        const total = count * size;
        const ptr = self.alloc(total) orelse return null;
        @memset(ptr[0..total], 0);
        return ptr;
    }

    // Get usable size for allocation
    pub fn usableSize(self: *Self, ptr: [*]u8) usize {
        _ = self;
        const page = page_mod.pageFromPtr(@ptrCast(ptr));

        return switch (page.state) {
            .slab => config.SIZE_CLASSES[page.size_class],
            .large => page_mod.Page.USABLE_SIZE,
            else => large_mod.LargeAllocator.getAllocSize(ptr),
        };
    }

    // Statistics
    pub fn getTotalAllocated(self: *Self) usize {
        return self.total_allocated.load(.acquire);
    }

    pub fn getTotalFreed(self: *Self) usize {
        return self.total_freed.load(.acquire);
    }

    pub fn getAllocationCount(self: *Self) usize {
        return self.allocation_count.load(.acquire);
    }

    pub fn getInUseBytes(self: *Self) usize {
        const allocated = self.total_allocated.load(.acquire);
        const freed = self.total_freed.load(.acquire);
        return if (allocated > freed) allocated - freed else 0;
    }
};

// Global heap instance
var global_heap: Heap = undefined;
var heap_initialized: bool = false;

// Initialize global heap (call once at startup)
pub fn init() void {
    if (!heap_initialized) {
        global_heap = Heap.init();
        global_heap.initAllocators();
        heap_initialized = true;
    }
}

// Get global heap
pub fn getHeap() *Heap {
    if (!heap_initialized) {
        init();
    }
    return &global_heap;
}

// Convenience functions using global heap
pub fn alloc(size: usize) ?[*]u8 {
    return getHeap().alloc(size);
}

pub fn free(ptr: ?[*]u8) void {
    getHeap().free(ptr);
}

pub fn realloc(ptr: ?[*]u8, old_size: usize, new_size: usize) ?[*]u8 {
    return getHeap().realloc(ptr, old_size, new_size);
}

pub fn calloc(count: usize, size: usize) ?[*]u8 {
    return getHeap().calloc(count, size);
}

// Tests
test "heap basic alloc/free" {
    var heap = Heap.init();
    heap.initAllocators();

    const p1 = heap.alloc(32) orelse return error.AllocFailed;
    p1[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), p1[0]);

    heap.free(p1);
}

test "heap various sizes" {
    var heap = Heap.init();
    heap.initAllocators();

    // Small (slab)
    const small = heap.alloc(64) orelse return error.AllocFailed;
    small[0] = 1;

    // Medium (slab)
    const medium = heap.alloc(1024) orelse return error.AllocFailed;
    medium[0] = 2;

    // Large (pages)
    const large_alloc = heap.alloc(8192) orelse return error.AllocFailed;
    large_alloc[0] = 3;

    // Huge (direct mmap)
    const huge = heap.alloc(4 * 1024 * 1024) orelse return error.AllocFailed;
    huge[0] = 4;

    heap.free(small);
    heap.free(medium);
    heap.free(large_alloc);
    heap.free(huge);
}

test "heap realloc grow" {
    var heap = Heap.init();
    heap.initAllocators();

    var p = heap.alloc(32) orelse return error.AllocFailed;
    p[0] = 99;

    p = heap.realloc(p, 32, 128) orelse return error.AllocFailed;
    try std.testing.expectEqual(@as(u8, 99), p[0]);

    p = heap.realloc(p, 128, 4096) orelse return error.AllocFailed;
    try std.testing.expectEqual(@as(u8, 99), p[0]);

    heap.free(p);
}

test "heap calloc" {
    var heap = Heap.init();
    heap.initAllocators();

    const p = heap.calloc(10, 100) orelse return error.AllocFailed;

    // Should be zeroed
    for (p[0..1000]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }

    heap.free(p);
}

test "heap statistics" {
    var heap = Heap.init();
    heap.initAllocators();

    const p1 = heap.alloc(64) orelse return error.AllocFailed;
    const p2 = heap.alloc(128) orelse return error.AllocFailed;

    try std.testing.expect(heap.getAllocationCount() >= 2);
    try std.testing.expect(heap.getTotalAllocated() >= 192);

    heap.free(p1);
    heap.free(p2);
}

test "heap null free is safe" {
    var heap = Heap.init();
    heap.initAllocators();
    heap.free(null); // Should not crash
}
