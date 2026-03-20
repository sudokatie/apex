// Page Manager
//
// Manages 64KB pages within segments.
// Each page can be used for slab allocation or large allocations.

const std = @import("std");
const config = @import("config.zig");
const segment_mod = @import("segment.zig");

const Segment = segment_mod.Segment;
const Atomic = std.atomic.Value;

// Page state
pub const PageState = enum(u8) {
    free = 0,
    slab = 1, // Used for slab allocation
    large = 2, // Used for large allocation
    huge = 3, // Part of huge allocation spanning multiple pages
};

// Page header - located at the start of each 64KB page
pub const Page = struct {
    // Back-pointer to containing segment
    segment: *Segment,

    // Page index within segment (0-31)
    index: u5,

    // Current state
    state: PageState,

    // Size class index (for slab pages)
    size_class: u8,

    // Number of allocated blocks (for slab pages)
    used_blocks: Atomic(u16),

    // Free list head index (for slab pages)
    free_list_head: u16,

    // Total blocks in page (for slab pages)
    total_blocks: u16,

    // Reserved for alignment (to 64 bytes)
    _reserved: [46]u8,

    const Self = @This();

    // Header size (64 bytes)
    pub const HEADER_SIZE: usize = 64;

    // Usable size per page (64KB - 64 bytes)
    pub const USABLE_SIZE: usize = config.PAGE_SIZE - HEADER_SIZE;

    // Initialize a page for slab allocation
    pub fn initSlab(self: *Self, seg: *Segment, page_idx: u5, size_class_idx: u8) void {
        self.segment = seg;
        self.index = page_idx;
        self.state = .slab;
        self.size_class = size_class_idx;

        const block_size = config.SIZE_CLASSES[size_class_idx];
        const total = @as(u16, @intCast(USABLE_SIZE / block_size));
        self.total_blocks = total;
        self.used_blocks = Atomic(u16).init(0);
        self.free_list_head = 0; // Index of first free block

        // Initialize free list: each block points to next
        self.initFreeList(block_size, total);
    }

    // Initialize the free list within the page
    fn initFreeList(self: *Self, block_size: usize, total_blocks: u16) void {
        const data_start = @intFromPtr(self) + HEADER_SIZE;

        var i: u16 = 0;
        while (i < total_blocks - 1) : (i += 1) {
            const block_addr = data_start + @as(usize, i) * block_size;
            const next_ptr: *u16 = @ptrFromInt(block_addr);
            next_ptr.* = i + 1; // Point to next block
        }

        // Last block points to sentinel
        const last_addr = data_start + @as(usize, total_blocks - 1) * block_size;
        const last_ptr: *u16 = @ptrFromInt(last_addr);
        last_ptr.* = 0xFFFF; // End marker
    }

    // Initialize a page for large allocation
    pub fn initLarge(self: *Self, seg: *Segment, page_idx: u5) void {
        self.segment = seg;
        self.index = page_idx;
        self.state = .large;
        self.size_class = 0;
        self.used_blocks = Atomic(u16).init(0);
        self.free_list_head = 0;
        self.total_blocks = 0;
    }

    // Get pointer to usable data area
    pub fn dataStart(self: *Self) [*]u8 {
        const addr = @intFromPtr(self) + HEADER_SIZE;
        return @ptrFromInt(addr);
    }

    // Allocate a block from this slab page
    // Returns pointer to block or null if page is full
    pub fn allocBlock(self: *Self) ?[*]u8 {
        if (self.state != .slab) return null;
        if (self.free_list_head == 0xFFFF) return null; // Full

        const block_size = config.SIZE_CLASSES[self.size_class];
        const data_start = @intFromPtr(self) + HEADER_SIZE;

        // Get the free block
        const block_idx = self.free_list_head;
        const block_addr = data_start + @as(usize, block_idx) * block_size;

        // Update free list to next
        const next_ptr: *u16 = @ptrFromInt(block_addr);
        self.free_list_head = next_ptr.*;

        _ = self.used_blocks.fetchAdd(1, .monotonic);

        return @ptrFromInt(block_addr);
    }

    // Free a block back to this slab page
    pub fn freeBlock(self: *Self, ptr: [*]u8) void {
        if (self.state != .slab) return;

        const block_size = config.SIZE_CLASSES[self.size_class];
        const data_start = @intFromPtr(self) + HEADER_SIZE;
        const ptr_addr = @intFromPtr(ptr);

        // Calculate block index
        const offset = ptr_addr - data_start;
        const block_idx = @as(u16, @intCast(offset / block_size));

        // Push onto free list
        const next_ptr: *u16 = @ptrCast(@alignCast(ptr));
        next_ptr.* = self.free_list_head;
        self.free_list_head = block_idx;

        _ = self.used_blocks.fetchSub(1, .monotonic);
    }

    // Check if page has free blocks
    pub fn hasFreeBlocks(self: *Self) bool {
        return self.free_list_head != 0xFFFF;
    }

    // Check if page is empty (no blocks allocated)
    pub fn isEmpty(self: *Self) bool {
        return self.used_blocks.load(.acquire) == 0;
    }

    // Check if page is full
    pub fn isFull(self: *Self) bool {
        return self.free_list_head == 0xFFFF;
    }
};

// Get page from any pointer within it
pub fn pageFromPtr(ptr: *anyopaque) *Page {
    const addr = @intFromPtr(ptr);
    const page_addr = addr & ~(config.PAGE_SIZE - 1);
    return @ptrFromInt(page_addr);
}

// Get page index within segment from pointer
pub fn pageIndexFromPtr(ptr: *anyopaque) u5 {
    const addr = @intFromPtr(ptr);
    const segment_base = addr & ~(config.SEGMENT_ALIGNMENT - 1);
    const offset = addr - segment_base;
    return @intCast(offset / config.PAGE_SIZE);
}

// Tests
test "page initialization for slab" {
    const seg = segment_mod.allocateSegment() orelse return error.AllocFailed;
    defer segment_mod.releaseSegment(seg);

    const page_idx = seg.allocPage() orelse return error.AllocFailed;
    const page_ptr: *Page = @ptrCast(@alignCast(seg.pageAddress(page_idx)));

    // Initialize for size class 0 (8 bytes)
    page_ptr.initSlab(seg, page_idx, 0);

    try std.testing.expectEqual(PageState.slab, page_ptr.state);
    try std.testing.expectEqual(@as(u8, 0), page_ptr.size_class);
    try std.testing.expect(page_ptr.total_blocks > 0);
    try std.testing.expect(page_ptr.hasFreeBlocks());
}

test "page block allocation" {
    const seg = segment_mod.allocateSegment() orelse return error.AllocFailed;
    defer segment_mod.releaseSegment(seg);

    const page_idx = seg.allocPage() orelse return error.AllocFailed;
    const page_ptr: *Page = @ptrCast(@alignCast(seg.pageAddress(page_idx)));

    // Size class 4 (64 bytes)
    page_ptr.initSlab(seg, page_idx, 4);

    // Allocate a few blocks
    const b1 = page_ptr.allocBlock() orelse return error.AllocFailed;
    const b2 = page_ptr.allocBlock() orelse return error.AllocFailed;
    const b3 = page_ptr.allocBlock() orelse return error.AllocFailed;

    // Blocks should be in usable area
    const data_start = @intFromPtr(page_ptr.dataStart());
    try std.testing.expect(@intFromPtr(b1) >= data_start);
    try std.testing.expect(@intFromPtr(b2) >= data_start);
    try std.testing.expect(@intFromPtr(b3) >= data_start);

    // Should be able to write to them
    b1[0] = 1;
    b2[0] = 2;
    b3[0] = 3;

    try std.testing.expectEqual(@as(u16, 3), page_ptr.used_blocks.load(.acquire));
}

test "page block free" {
    const seg = segment_mod.allocateSegment() orelse return error.AllocFailed;
    defer segment_mod.releaseSegment(seg);

    const page_idx = seg.allocPage() orelse return error.AllocFailed;
    const page_ptr: *Page = @ptrCast(@alignCast(seg.pageAddress(page_idx)));

    page_ptr.initSlab(seg, page_idx, 4); // 64 bytes

    const b1 = page_ptr.allocBlock() orelse return error.AllocFailed;
    const b2 = page_ptr.allocBlock() orelse return error.AllocFailed;

    try std.testing.expectEqual(@as(u16, 2), page_ptr.used_blocks.load(.acquire));

    page_ptr.freeBlock(b1);
    try std.testing.expectEqual(@as(u16, 1), page_ptr.used_blocks.load(.acquire));

    page_ptr.freeBlock(b2);
    try std.testing.expect(page_ptr.isEmpty());
}

test "page from pointer lookup" {
    const seg = segment_mod.allocateSegment() orelse return error.AllocFailed;
    defer segment_mod.releaseSegment(seg);

    const page_idx = seg.allocPage() orelse return error.AllocFailed;
    const page_ptr: *Page = @ptrCast(@alignCast(seg.pageAddress(page_idx)));

    page_ptr.initSlab(seg, page_idx, 4);

    const block = page_ptr.allocBlock() orelse return error.AllocFailed;

    // Should find page from block pointer
    const found = pageFromPtr(@ptrCast(block));
    try std.testing.expectEqual(page_ptr, found);
}

test "fill and exhaust page" {
    const seg = segment_mod.allocateSegment() orelse return error.AllocFailed;
    defer segment_mod.releaseSegment(seg);

    const page_idx = seg.allocPage() orelse return error.AllocFailed;
    const page_ptr: *Page = @ptrCast(@alignCast(seg.pageAddress(page_idx)));

    // Use large size class so we can fill quickly
    page_ptr.initSlab(seg, page_idx, 16); // 2048 bytes
    const expected_blocks = (config.PAGE_SIZE - Page.HEADER_SIZE) / 2048;

    var i: usize = 0;
    while (page_ptr.allocBlock()) |_| {
        i += 1;
    }

    try std.testing.expectEqual(expected_blocks, i);
    try std.testing.expect(page_ptr.isFull());
    try std.testing.expect(!page_ptr.hasFreeBlocks());
}
