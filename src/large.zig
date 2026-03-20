// Large Allocator
//
// Handles allocations larger than slab size classes (> 2048 bytes).
// - Large (2KB-2MB): Uses segment pages
// - Huge (>2MB): Direct mmap with tracking

const std = @import("std");
const config = @import("config.zig");
const segment_mod = @import("segment.zig");
const page_mod = @import("page.zig");
const platform = @import("platform.zig");

const Segment = segment_mod.Segment;
const Page = page_mod.Page;
const PageState = page_mod.PageState;

// Header for huge allocations (direct mmap)
pub const HugeHeader = struct {
    // Actual allocated size (including header)
    size: usize,

    // Next huge allocation in tracking list
    next: ?*HugeHeader,

    // Previous huge allocation
    prev: ?*HugeHeader,

    // Magic number for validation
    magic: u64,

    const MAGIC: u64 = 0xA9EF_DEAD_BEEF_CAFE;
    const HEADER_SIZE: usize = 64; // Aligned to cache line

    pub fn init(self: *HugeHeader, size: usize) void {
        self.size = size;
        self.next = null;
        self.prev = null;
        self.magic = MAGIC;
    }

    pub fn isValid(self: *HugeHeader) bool {
        return self.magic == MAGIC;
    }

    pub fn dataPtr(self: *HugeHeader) [*]u8 {
        const addr = @intFromPtr(self) + HEADER_SIZE;
        return @ptrFromInt(addr);
    }

    pub fn fromDataPtr(ptr: [*]u8) *HugeHeader {
        const addr = @intFromPtr(ptr) - HEADER_SIZE;
        return @ptrFromInt(addr);
    }

    pub fn usableSize(self: *HugeHeader) usize {
        return self.size - HEADER_SIZE;
    }
};

// Large allocator state
pub const LargeAllocator = struct {
    // Segment cache for page-based allocations
    segment_cache: *segment_mod.SegmentCache,

    // Tracking list for huge allocations
    huge_head: ?*HugeHeader,
    huge_count: usize,
    huge_bytes: usize,

    // Lock for thread safety
    lock: std.Thread.Mutex,

    const Self = @This();

    pub fn init(cache: *segment_mod.SegmentCache) Self {
        return .{
            .segment_cache = cache,
            .huge_head = null,
            .huge_count = 0,
            .huge_bytes = 0,
            .lock = .{},
        };
    }

    // Allocate large memory
    pub fn alloc(self: *Self, size: usize) ?[*]u8 {
        if (size <= config.LARGE_THRESHOLD) {
            return null; // Should use slab allocator
        }

        if (size > config.HUGE_THRESHOLD) {
            return self.allocHuge(size);
        }

        return self.allocLarge(size);
    }

    // Allocate using segment pages (2KB - 2MB)
    fn allocLarge(self: *Self, size: usize) ?[*]u8 {
        // Calculate pages needed
        const pages_needed = (size + Page.HEADER_SIZE + config.PAGE_SIZE - 1) / config.PAGE_SIZE;

        if (pages_needed > config.PAGES_PER_SEGMENT - 1) {
            // Too big for segment pages, use huge
            return self.allocHuge(size);
        }

        self.lock.lock();
        defer self.lock.unlock();

        // Get a segment with enough free pages
        const seg = self.segment_cache.acquire() orelse return null;

        // For now, allocate single page for simplicity
        // TODO: support multi-page allocations
        const page_idx = seg.allocPage() orelse {
            self.segment_cache.release(seg);
            return null;
        };

        const page: *Page = @ptrCast(@alignCast(seg.pageAddress(page_idx)));
        page.initLarge(seg, page_idx);

        return page.dataStart();
    }

    // Allocate directly from OS (>2MB)
    fn allocHuge(self: *Self, size: usize) ?[*]u8 {
        // Round up to page boundary and add header
        const total_size = alignUp(size + HugeHeader.HEADER_SIZE, std.heap.page_size_min);

        const ptr = platform.mapMemory(total_size, std.heap.page_size_min) orelse return null;

        const header: *HugeHeader = @ptrCast(@alignCast(ptr));
        header.init(total_size);

        // Add to tracking list
        self.lock.lock();
        defer self.lock.unlock();

        header.next = self.huge_head;
        if (self.huge_head) |head| {
            head.prev = header;
        }
        self.huge_head = header;
        self.huge_count += 1;
        self.huge_bytes += total_size;

        return header.dataPtr();
    }

    // Free large memory
    pub fn free(self: *Self, ptr: [*]u8) void {
        // Check if it's a huge allocation
        const potential_header = HugeHeader.fromDataPtr(ptr);
        if (potential_header.isValid()) {
            self.freeHuge(potential_header);
            return;
        }

        // Must be a page-based allocation
        self.freeLarge(ptr);
    }

    fn freeLarge(self: *Self, ptr: [*]u8) void {
        const page = page_mod.pageFromPtr(@ptrCast(ptr));
        if (page.state != .large) return;

        self.lock.lock();
        defer self.lock.unlock();

        const seg = page.segment;
        seg.freePage(page.index);

        // If segment is empty, return to cache
        if (seg.isEmpty()) {
            self.segment_cache.release(seg);
        }
    }

    fn freeHuge(self: *Self, header: *HugeHeader) void {
        self.lock.lock();
        defer self.lock.unlock();

        // Remove from tracking list
        if (header.prev) |prev| {
            prev.next = header.next;
        } else {
            self.huge_head = header.next;
        }

        if (header.next) |next| {
            next.prev = header.prev;
        }

        self.huge_count -= 1;
        self.huge_bytes -= header.size;

        // Unmap the memory
        platform.unmapMemory(@ptrCast(header), header.size);
    }

    // Reallocate memory
    pub fn realloc(self: *Self, ptr: [*]u8, old_size: usize, new_size: usize) ?[*]u8 {
        if (new_size == 0) {
            self.free(ptr);
            return null;
        }

        if (new_size <= old_size) {
            // Shrinking - could return same pointer
            // For huge allocations, might want to shrink
            return ptr;
        }

        // Growing - need to allocate new and copy
        const new_ptr = self.alloc(new_size) orelse return null;

        // Copy old data
        const copy_size = @min(old_size, new_size);
        @memcpy(new_ptr[0..copy_size], ptr[0..copy_size]);

        self.free(ptr);
        return new_ptr;
    }

    // Get allocation size from pointer
    pub fn getAllocSize(ptr: [*]u8) usize {
        // Check for huge allocation
        const potential_header = HugeHeader.fromDataPtr(ptr);
        if (potential_header.isValid()) {
            return potential_header.usableSize();
        }

        // Page-based allocation
        const page = page_mod.pageFromPtr(@ptrCast(ptr));
        if (page.state == .large) {
            return Page.USABLE_SIZE;
        }

        return 0;
    }

    // Stats
    pub fn getHugeCount(self: *Self) usize {
        return self.huge_count;
    }

    pub fn getHugeBytes(self: *Self) usize {
        return self.huge_bytes;
    }
};

// Align up to boundary
fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

// Tests
test "large allocation basic" {
    var cache = segment_mod.SegmentCache.init();
    var large = LargeAllocator.init(&cache);

    // Allocate 4KB (uses page)
    const p1 = large.alloc(4096) orelse return error.AllocFailed;
    p1[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), p1[0]);

    large.free(p1);
}

test "huge allocation" {
    var cache = segment_mod.SegmentCache.init();
    var large = LargeAllocator.init(&cache);

    // Allocate 4MB (uses direct mmap)
    const size = 4 * 1024 * 1024;
    const p1 = large.alloc(size) orelse return error.AllocFailed;

    try std.testing.expectEqual(@as(usize, 1), large.getHugeCount());

    // Write to ends
    p1[0] = 1;
    p1[size - 1] = 2;

    large.free(p1);
    try std.testing.expectEqual(@as(usize, 0), large.getHugeCount());
}

test "huge header validation" {
    var header: HugeHeader = undefined;
    header.init(4096);

    try std.testing.expect(header.isValid());
    try std.testing.expectEqual(@as(usize, 4096 - HugeHeader.HEADER_SIZE), header.usableSize());
}

test "realloc grow" {
    var cache = segment_mod.SegmentCache.init();
    var large = LargeAllocator.init(&cache);

    // Allocate 4KB
    var p1 = large.alloc(4096) orelse return error.AllocFailed;
    p1[0] = 99;

    // Realloc to 8KB
    const p2 = large.realloc(p1, 4096, 8192) orelse return error.AllocFailed;

    // Data should be preserved
    try std.testing.expectEqual(@as(u8, 99), p2[0]);

    large.free(p2);
}

test "realloc shrink" {
    var cache = segment_mod.SegmentCache.init();
    var large = LargeAllocator.init(&cache);

    // Allocate 8KB
    const p1 = large.alloc(8192) orelse return error.AllocFailed;
    p1[0] = 77;

    // Shrink to 4KB
    const p2 = large.realloc(p1, 8192, 4096) orelse return error.AllocFailed;

    // Should return same pointer (or at least preserve data)
    try std.testing.expectEqual(@as(u8, 77), p2[0]);

    large.free(p2);
}

test "multiple huge allocations" {
    var cache = segment_mod.SegmentCache.init();
    var large = LargeAllocator.init(&cache);

    const size = 3 * 1024 * 1024;
    var ptrs: [5]*u8 = undefined;

    // Allocate 5 huge blocks
    for (&ptrs, 0..) |*p, i| {
        const ptr = large.alloc(size) orelse return error.AllocFailed;
        ptr[0] = @intCast(i);
        p.* = @ptrCast(ptr);
    }

    try std.testing.expectEqual(@as(usize, 5), large.getHugeCount());

    // Free all
    for (ptrs) |p| {
        large.free(@ptrCast(p));
    }

    try std.testing.expectEqual(@as(usize, 0), large.getHugeCount());
}
