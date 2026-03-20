// Slab Allocator
//
// Fast allocation for small objects using size classes.
// Each size class has its own pool of pages.

const std = @import("std");
const config = @import("config.zig");
const segment_mod = @import("segment.zig");
const page_mod = @import("page.zig");

const Segment = segment_mod.Segment;
const Page = page_mod.Page;
const PageState = page_mod.PageState;

// Per-size-class page list
pub const SlabClass = struct {
    // Partial pages (have free blocks)
    partial_head: ?*Page,

    // Full pages
    full_head: ?*Page,

    // Empty pages (can be returned to segment)
    empty_head: ?*Page,

    // Counts
    partial_count: usize,
    full_count: usize,
    empty_count: usize,

    // Size class index
    class_index: u8,

    // Lock for thread safety
    lock: std.Thread.Mutex,

    const Self = @This();

    pub fn init(class_idx: u8) Self {
        return .{
            .partial_head = null,
            .full_head = null,
            .empty_head = null,
            .partial_count = 0,
            .full_count = 0,
            .empty_count = 0,
            .class_index = class_idx,
            .lock = .{},
        };
    }

    // Allocate a block from this size class
    pub fn alloc(self: *Self, cache: *segment_mod.SegmentCache) ?[*]u8 {
        self.lock.lock();
        defer self.lock.unlock();

        // Try partial pages first
        if (self.partial_head) |page| {
            if (page.allocBlock()) |block| {
                // Check if page became full
                if (page.isFull()) {
                    self.moveToFull(page);
                }
                return block;
            }
        }

        // Need a new page
        const page = self.getNewPage(cache) orelse return null;

        if (page.allocBlock()) |block| {
            // Add to partial list (unless somehow already full)
            if (page.isFull()) {
                self.addToFull(page);
            } else {
                self.addToPartial(page);
            }
            return block;
        }

        return null;
    }

    // Free a block back to this size class
    pub fn free(self: *Self, page: *Page, ptr: [*]u8) void {
        self.lock.lock();
        defer self.lock.unlock();

        const was_full = page.isFull();
        page.freeBlock(ptr);

        if (page.isEmpty()) {
            // Move to empty list
            if (was_full) {
                self.removeFromFull(page);
            } else {
                self.removeFromPartial(page);
            }
            self.addToEmpty(page);
        } else if (was_full) {
            // Was full, now has free blocks - move to partial
            self.removeFromFull(page);
            self.addToPartial(page);
        }
    }

    // Get a new page from segment cache
    fn getNewPage(self: *Self, cache: *segment_mod.SegmentCache) ?*Page {
        // Try empty list first
        if (self.empty_head) |page| {
            self.empty_head = page.next_page;
            self.empty_count -= 1;
            // Reinitialize for this size class
            page.initSlab(page.segment, page.index, self.class_index);
            return page;
        }

        // Need to get a page from a segment
        const seg = cache.acquire() orelse return null;
        const page_idx = seg.allocPage() orelse {
            cache.release(seg);
            return null;
        };

        const page: *Page = @ptrCast(@alignCast(seg.pageAddress(page_idx)));
        page.initSlab(seg, page_idx, self.class_index);
        return page;
    }

    // List management using Page.next_page
    fn addToPartial(self: *Self, page: *Page) void {
        page.next_page = self.partial_head;
        self.partial_head = page;
        self.partial_count += 1;
    }

    fn removeFromPartial(self: *Self, page: *Page) void {
        if (self.partial_head == page) {
            self.partial_head = page.next_page;
            self.partial_count -= 1;
            return;
        }
        var prev: ?*Page = self.partial_head;
        while (prev) |p| {
            if (p.next_page == page) {
                p.next_page = page.next_page;
                self.partial_count -= 1;
                return;
            }
            prev = p.next_page;
        }
    }

    fn addToFull(self: *Self, page: *Page) void {
        page.next_page = self.full_head;
        self.full_head = page;
        self.full_count += 1;
    }

    fn moveToFull(self: *Self, page: *Page) void {
        self.removeFromPartial(page);
        self.addToFull(page);
    }

    fn removeFromFull(self: *Self, page: *Page) void {
        if (self.full_head == page) {
            self.full_head = page.next_page;
            self.full_count -= 1;
            return;
        }
        var prev: ?*Page = self.full_head;
        while (prev) |p| {
            if (p.next_page == page) {
                p.next_page = page.next_page;
                self.full_count -= 1;
                return;
            }
            prev = p.next_page;
        }
    }

    fn addToEmpty(self: *Self, page: *Page) void {
        page.next_page = self.empty_head;
        self.empty_head = page;
        self.empty_count += 1;
    }
};

// Slab allocator managing all size classes
pub const SlabAllocator = struct {
    classes: [config.NUM_SIZE_CLASSES]SlabClass,
    segment_cache: *segment_mod.SegmentCache,

    const Self = @This();

    pub fn init(cache: *segment_mod.SegmentCache) Self {
        var classes: [config.NUM_SIZE_CLASSES]SlabClass = undefined;
        for (&classes, 0..) |*c, i| {
            c.* = SlabClass.init(@intCast(i));
        }
        return .{
            .classes = classes,
            .segment_cache = cache,
        };
    }

    // Allocate memory of given size
    pub fn alloc(self: *Self, size: usize) ?[*]u8 {
        const class_idx = config.sizeClassIndex(size) orelse return null;
        return self.classes[class_idx].alloc(self.segment_cache);
    }

    // Free memory
    pub fn free(self: *Self, ptr: [*]u8) void {
        const page = page_mod.pageFromPtr(@ptrCast(ptr));
        if (page.state != .slab) return;

        const class_idx = page.size_class;
        self.classes[class_idx].free(page, ptr);
    }

    // Get size class for an allocation
    pub fn getAllocSize(ptr: [*]u8) usize {
        const page = page_mod.pageFromPtr(@ptrCast(ptr));
        if (page.state != .slab) return 0;
        return config.SIZE_CLASSES[page.size_class];
    }
};

// Tests
test "slab class initialization" {
    const class = SlabClass.init(0);
    try std.testing.expect(class.partial_head == null);
    try std.testing.expect(class.full_head == null);
    try std.testing.expect(class.empty_head == null);
}

test "slab allocator basic" {
    var cache = segment_mod.SegmentCache.init();
    var slab = SlabAllocator.init(&cache);

    // Allocate various sizes
    const p1 = slab.alloc(8) orelse return error.AllocFailed;
    const p2 = slab.alloc(64) orelse return error.AllocFailed;
    const p3 = slab.alloc(256) orelse return error.AllocFailed;

    // Should be able to write to them
    p1[0] = 1;
    p2[0] = 2;
    p3[0] = 3;

    // Free them
    slab.free(p1);
    slab.free(p2);
    slab.free(p3);
}

test "slab allocation reuses freed blocks" {
    var cache = segment_mod.SegmentCache.init();
    var slab = SlabAllocator.init(&cache);

    const p1 = slab.alloc(64) orelse return error.AllocFailed;
    const addr1 = @intFromPtr(p1);

    slab.free(p1);

    const p2 = slab.alloc(64) orelse return error.AllocFailed;
    const addr2 = @intFromPtr(p2);

    // Should reuse same address
    try std.testing.expectEqual(addr1, addr2);

    slab.free(p2);
}

test "slab many allocations" {
    var cache = segment_mod.SegmentCache.init();
    var slab = SlabAllocator.init(&cache);

    var ptrs: [100]*u8 = undefined;

    // Allocate 100 blocks
    for (&ptrs) |*p| {
        const ptr = slab.alloc(32) orelse return error.AllocFailed;
        p.* = @ptrCast(ptr);
    }

    // Free all
    for (ptrs) |p| {
        slab.free(@ptrCast(p));
    }
}
