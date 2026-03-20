// Thread Cache
//
// Per-thread free lists for fast allocation without contention.
// Each thread has its own cache of blocks for each size class.

const std = @import("std");
const config = @import("config.zig");
const segment_mod = @import("segment.zig");
const page_mod = @import("page.zig");
const slab_mod = @import("slab.zig");

// Free list node (stored in the free block itself)
const FreeNode = struct {
    next: ?*FreeNode,
};

// Per-size-class cache
pub const SizeClassCache = struct {
    // Free list head
    head: ?*FreeNode,

    // Number of cached blocks
    count: usize,

    const Self = @This();

    pub fn init() Self {
        return .{
            .head = null,
            .count = 0,
        };
    }

    // Push a block onto the cache
    pub fn push(self: *Self, ptr: [*]u8) void {
        const node: *FreeNode = @ptrCast(@alignCast(ptr));
        node.next = self.head;
        self.head = node;
        self.count += 1;
    }

    // Pop a block from the cache
    pub fn pop(self: *Self) ?[*]u8 {
        const node = self.head orelse return null;
        self.head = node.next;
        self.count -= 1;
        return @ptrCast(node);
    }

    // Check if cache is empty
    pub fn isEmpty(self: *Self) bool {
        return self.head == null;
    }

    // Check if cache is full
    pub fn isFull(self: *Self) bool {
        return self.count >= config.THREAD_CACHE_MAX_BLOCKS;
    }
};

// Per-thread cache
pub const ThreadCache = struct {
    // Caches for each size class
    caches: [config.NUM_SIZE_CLASSES]SizeClassCache,

    // Thread ID that owns this cache
    thread_id: usize,

    // Back-reference to global heap
    heap: *anyopaque, // Will be *Heap when implemented

    // Next cache in global list
    next: ?*ThreadCache,

    const Self = @This();

    pub fn init(tid: usize) Self {
        var caches: [config.NUM_SIZE_CLASSES]SizeClassCache = undefined;
        for (&caches) |*c| {
            c.* = SizeClassCache.init();
        }
        return .{
            .caches = caches,
            .thread_id = tid,
            .heap = undefined,
            .next = null,
        };
    }

    // Allocate from thread cache
    pub fn alloc(self: *Self, size: usize, slab_allocator: *slab_mod.SlabAllocator) ?[*]u8 {
        const class_idx = config.sizeClassIndex(size) orelse return null;

        // Try thread-local cache first
        if (self.caches[class_idx].pop()) |ptr| {
            return ptr;
        }

        // Cache miss - fill from slab allocator
        self.fillCache(class_idx, slab_allocator);

        return self.caches[class_idx].pop();
    }

    // Free to thread cache
    pub fn free(self: *Self, ptr: [*]u8, slab_allocator: *slab_mod.SlabAllocator) void {
        const page = page_mod.pageFromPtr(@ptrCast(ptr));
        if (page.state != .slab) return;

        const class_idx = page.size_class;

        if (self.caches[class_idx].isFull()) {
            // Cache full - flush half to slab allocator
            self.flushCache(class_idx, slab_allocator);
        }

        self.caches[class_idx].push(ptr);
    }

    // Fill cache from slab allocator
    fn fillCache(self: *Self, class_idx: usize, slab_allocator: *slab_mod.SlabAllocator) void {
        var i: usize = 0;
        while (i < config.THREAD_CACHE_FILL_COUNT) : (i += 1) {
            const ptr = slab_allocator.alloc(config.SIZE_CLASSES[class_idx]) orelse break;
            self.caches[class_idx].push(ptr);
        }
    }

    // Flush half the cache to slab allocator
    fn flushCache(self: *Self, class_idx: usize, slab_allocator: *slab_mod.SlabAllocator) void {
        const flush_count = self.caches[class_idx].count / 2;
        var i: usize = 0;
        while (i < flush_count) : (i += 1) {
            const ptr = self.caches[class_idx].pop() orelse break;
            slab_allocator.free(ptr);
        }
    }

    // Flush all caches (call on thread exit)
    pub fn flushAll(self: *Self, slab_allocator: *slab_mod.SlabAllocator) void {
        for (&self.caches) |*cache| {
            while (cache.pop()) |ptr| {
                slab_allocator.free(ptr);
            }
        }
    }

    // Get total cached blocks
    pub fn getTotalCached(self: *Self) usize {
        var total: usize = 0;
        for (self.caches) |cache| {
            total += cache.count;
        }
        return total;
    }
};

// Thread-local storage for current thread's cache
var tls_cache: ?*ThreadCache = null;

// Get or create thread cache
pub fn getThreadCache(slab_allocator: *slab_mod.SlabAllocator) *ThreadCache {
    if (tls_cache) |cache| {
        return cache;
    }

    // Allocate new cache (use slab allocator for the cache struct itself)
    // For now, use a simple static allocation
    // In production, would use a proper thread-local allocator
    _ = slab_allocator;
    @panic("Thread cache allocation not implemented");
}

// Tests
test "size class cache push/pop" {
    var cache = SizeClassCache.init();

    try std.testing.expect(cache.isEmpty());

    // Create some fake pointers
    var blocks: [8]u8 align(8) = undefined;
    const ptr: [*]u8 = &blocks;

    cache.push(ptr);
    try std.testing.expect(!cache.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), cache.count);

    const popped = cache.pop();
    try std.testing.expect(popped != null);
    try std.testing.expect(cache.isEmpty());
}

test "thread cache initialization" {
    var tc = ThreadCache.init(123);

    try std.testing.expectEqual(@as(usize, 123), tc.thread_id);
    try std.testing.expectEqual(@as(usize, 0), tc.getTotalCached());
}

test "thread cache alloc from slab" {
    var segment_cache = segment_mod.SegmentCache.init();
    var slab = slab_mod.SlabAllocator.init(&segment_cache);
    var tc = ThreadCache.init(1);

    // First alloc triggers fill from slab
    const p1 = tc.alloc(32, &slab) orelse return error.AllocFailed;
    p1[0] = 42;

    // Cache should have been filled
    try std.testing.expect(tc.getTotalCached() > 0);

    // Free back to cache
    tc.free(p1, &slab);

    // Should be able to alloc again from cache
    const p2 = tc.alloc(32, &slab) orelse return error.AllocFailed;
    p2[0] = 99; // Verify we got a valid pointer

    tc.flushAll(&slab);
}

test "thread cache flush when full" {
    var segment_cache = segment_mod.SegmentCache.init();
    var slab = slab_mod.SlabAllocator.init(&segment_cache);
    var tc = ThreadCache.init(1);

    // Allocate many blocks
    var ptrs: [300]*u8 = undefined;
    for (&ptrs) |*p| {
        const ptr = tc.alloc(64, &slab) orelse return error.AllocFailed;
        p.* = @ptrCast(ptr);
    }

    // Free them all (will trigger flush when cache gets full)
    for (ptrs) |p| {
        tc.free(@ptrCast(p), &slab);
    }

    // Cache should not exceed max
    const class_idx = config.sizeClassIndex(64).?;
    try std.testing.expect(tc.caches[class_idx].count <= config.THREAD_CACHE_MAX_BLOCKS);

    tc.flushAll(&slab);
}
