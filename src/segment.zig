// Segment Manager
//
// Manages 2MB memory chunks from the OS.
// Each segment contains 32 pages (64KB each).

const std = @import("std");
const config = @import("config.zig");
const platform = @import("platform.zig");

const Atomic = std.atomic.Value;

// Segment header - located at the start of each 2MB segment
pub const Segment = struct {
    // Bitmap of allocated pages (1 = allocated, 0 = free)
    // 32 bits for 32 pages per segment
    page_bitmap: Atomic(u32),

    // Number of allocated pages
    allocated_pages: Atomic(u32),

    // Lock for thread safety during allocation
    lock: std.Thread.Mutex,

    // Pointer to next segment in freelist/active list
    next: ?*Segment,

    // Reserved for future use (cache line padding)
    _reserved: [40]u8,

    const Self = @This();

    // Header size (64 bytes, fits in one cache line)
    pub const HEADER_SIZE: usize = 64;

    // Initialize a new segment at the given memory location
    pub fn init(ptr: [*]u8) *Self {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.page_bitmap = Atomic(u32).init(1); // Page 0 is always allocated (header)
        self.allocated_pages = Atomic(u32).init(1);
        self.lock = .{};
        self.next = null;
        self._reserved = [_]u8{0} ** 40;
        return self;
    }

    // Get the base address of this segment
    pub fn baseAddress(self: *Self) [*]u8 {
        return @ptrCast(self);
    }

    // Get the address of a page by index (0-31)
    pub fn pageAddress(self: *Self, page_index: u5) [*]u8 {
        const base = @intFromPtr(self);
        const offset = @as(usize, page_index) * config.PAGE_SIZE;
        return @ptrFromInt(base + offset);
    }

    // Allocate a page from this segment
    // Returns page index or null if segment is full
    pub fn allocPage(self: *Self) ?u5 {
        self.lock.lock();
        defer self.lock.unlock();

        const bitmap = self.page_bitmap.load(.acquire);

        // Find first free page (first 0 bit)
        if (bitmap == 0xFFFFFFFF) return null; // All pages allocated

        // Find first zero bit
        const free_bit: u5 = @intCast(@ctz(~bitmap));

        // Set the bit
        const new_bitmap = bitmap | (@as(u32, 1) << free_bit);
        self.page_bitmap.store(new_bitmap, .release);

        _ = self.allocated_pages.fetchAdd(1, .monotonic);

        return free_bit;
    }

    // Allocate multiple contiguous pages from this segment
    // Returns starting page index or null if not enough contiguous pages
    pub fn allocPages(self: *Self, count: u5) ?u5 {
        if (count == 0) return null;
        if (count == 1) return self.allocPage();
        if (count > 31) return null; // Max 31 pages (page 0 is header)

        self.lock.lock();
        defer self.lock.unlock();

        const bitmap = self.page_bitmap.load(.acquire);

        // Find 'count' contiguous free bits
        const start_idx = findContiguousFree(bitmap, count) orelse return null;

        // Create mask for all pages to allocate
        var mask: u32 = 0;
        var i: u5 = 0;
        while (i < count) : (i += 1) {
            mask |= @as(u32, 1) << (start_idx + i);
        }

        // Set all bits
        const new_bitmap = bitmap | mask;
        self.page_bitmap.store(new_bitmap, .release);

        _ = self.allocated_pages.fetchAdd(count, .monotonic);

        return start_idx;
    }

    // Free multiple contiguous pages starting at index
    pub fn freePages(self: *Self, start_index: u5, count: u5) void {
        if (start_index == 0) return; // Never free the header page
        if (count == 0) return;

        self.lock.lock();
        defer self.lock.unlock();

        const bitmap = self.page_bitmap.load(.acquire);

        // Create mask for pages to free
        var mask: u32 = 0;
        var freed: u32 = 0;
        var i: u5 = 0;
        while (i < count) : (i += 1) {
            const idx = start_index + i;
            if (idx >= 32) break;
            if (idx == 0) continue; // Skip header page
            const bit = @as(u32, 1) << idx;
            if (bitmap & bit != 0) { // Only count if was allocated
                mask |= bit;
                freed += 1;
            }
        }

        // Clear the bits
        const new_bitmap = bitmap & ~mask;
        self.page_bitmap.store(new_bitmap, .release);

        _ = self.allocated_pages.fetchSub(freed, .monotonic);
    }

    // Check if segment has N contiguous free pages
    pub fn hasContiguousFreePages(self: *Self, count: u5) bool {
        const bitmap = self.page_bitmap.load(.acquire);
        return findContiguousFree(bitmap, count) != null;
    }

    // Free a page by index
    pub fn freePage(self: *Self, page_index: u5) void {
        if (page_index == 0) return; // Never free the header page

        self.lock.lock();
        defer self.lock.unlock();

        const bitmap = self.page_bitmap.load(.acquire);
        const mask = @as(u32, 1) << page_index;

        if (bitmap & mask == 0) return; // Already free

        const new_bitmap = bitmap & ~mask;
        self.page_bitmap.store(new_bitmap, .release);

        _ = self.allocated_pages.fetchSub(1, .monotonic);
    }

    // Check if segment has any free pages
    pub fn hasFreePages(self: *Self) bool {
        const bitmap = self.page_bitmap.load(.acquire);
        return bitmap != 0xFFFFFFFF;
    }

    // Check if segment is empty (only header allocated)
    pub fn isEmpty(self: *Self) bool {
        return self.allocated_pages.load(.acquire) == 1;
    }

    // Get number of free pages
    pub fn freePageCount(self: *Self) u32 {
        const allocated = self.allocated_pages.load(.acquire);
        return @as(u32, config.PAGES_PER_SEGMENT) - allocated;
    }
};

// Find 'count' contiguous free bits in bitmap, starting from bit 1 (skip header)
// Returns starting bit index or null if not found
fn findContiguousFree(bitmap: u32, count: u5) ?u5 {
    if (count == 0) return null;
    if (count > 31) return null;

    var start: u5 = 1; // Start from page 1 (page 0 is header)
    while (start + count <= 32) {
        var found = true;
        var i: u5 = 0;
        while (i < count) : (i += 1) {
            const bit = @as(u32, 1) << (start + i);
            if (bitmap & bit != 0) {
                // Bit is set (page allocated), skip past it
                start = start + i + 1;
                found = false;
                break;
            }
        }
        if (found) return start;
    }
    return null;
}

// Global segment cache
pub const SegmentCache = struct {
    // List of cached free segments
    free_list: ?*Segment,
    free_count: usize,
    lock: std.Thread.Mutex,

    const Self = @This();

    pub fn init() Self {
        return .{
            .free_list = null,
            .free_count = 0,
            .lock = .{},
        };
    }

    // Get a segment from cache or allocate new
    pub fn acquire(self: *Self) ?*Segment {
        self.lock.lock();

        // Try to get from cache first
        if (self.free_list) |seg| {
            self.free_list = seg.next;
            self.free_count -= 1;
            self.lock.unlock();

            // Reinitialize the segment
            return Segment.init(@ptrCast(seg));
        }

        self.lock.unlock();

        // Allocate new segment from OS
        return allocateSegment();
    }

    // Return a segment to cache or release to OS
    pub fn release(self: *Self, segment: *Segment) void {
        self.lock.lock();

        if (self.free_count < config.SEGMENT_CACHE_MAX) {
            // Add to cache
            segment.next = self.free_list;
            self.free_list = segment;
            self.free_count += 1;
            self.lock.unlock();
        } else {
            self.lock.unlock();
            // Release to OS
            releaseSegment(segment);
        }
    }
};

// Allocate a new 2MB segment from the OS
pub fn allocateSegment() ?*Segment {
    const ptr = platform.mapMemory(config.SEGMENT_SIZE, config.SEGMENT_ALIGNMENT) orelse return null;
    return Segment.init(ptr);
}

// Release a segment back to the OS
pub fn releaseSegment(segment: *Segment) void {
    platform.unmapMemory(@ptrCast(segment), config.SEGMENT_SIZE);
}

// Get segment from any pointer within it (mask off low bits)
pub fn segmentFromPtr(ptr: *anyopaque) *Segment {
    const addr = @intFromPtr(ptr);
    const segment_addr = addr & ~(config.SEGMENT_ALIGNMENT - 1);
    return @ptrFromInt(segment_addr);
}

// Global segment cache instance
var global_cache: SegmentCache = SegmentCache.init();

pub fn getGlobalCache() *SegmentCache {
    return &global_cache;
}

// Tests
test "segment allocation and initialization" {
    const seg = allocateSegment() orelse return error.AllocFailed;
    defer releaseSegment(seg);

    // Header page should be allocated
    try std.testing.expectEqual(@as(u32, 1), seg.allocated_pages.load(.acquire));
    try std.testing.expect(seg.hasFreePages());
    try std.testing.expectEqual(@as(u32, 31), seg.freePageCount());
}

test "segment page allocation" {
    const seg = allocateSegment() orelse return error.AllocFailed;
    defer releaseSegment(seg);

    // Allocate a few pages
    const p1 = seg.allocPage() orelse return error.AllocFailed;
    const p2 = seg.allocPage() orelse return error.AllocFailed;
    const p3 = seg.allocPage() orelse return error.AllocFailed;

    try std.testing.expectEqual(@as(u5, 1), p1);
    try std.testing.expectEqual(@as(u5, 2), p2);
    try std.testing.expectEqual(@as(u5, 3), p3);

    try std.testing.expectEqual(@as(u32, 4), seg.allocated_pages.load(.acquire));
}

test "segment page free" {
    const seg = allocateSegment() orelse return error.AllocFailed;
    defer releaseSegment(seg);

    const p1 = seg.allocPage() orelse return error.AllocFailed;
    const p2 = seg.allocPage() orelse return error.AllocFailed;

    try std.testing.expectEqual(@as(u32, 3), seg.allocated_pages.load(.acquire));

    seg.freePage(p1);
    try std.testing.expectEqual(@as(u32, 2), seg.allocated_pages.load(.acquire));

    seg.freePage(p2);
    try std.testing.expectEqual(@as(u32, 1), seg.allocated_pages.load(.acquire));
    try std.testing.expect(seg.isEmpty());
}

test "segment cache" {
    var cache = SegmentCache.init();

    // Acquire a segment
    const seg = cache.acquire() orelse return error.AllocFailed;
    try std.testing.expect(seg.hasFreePages());

    // Release it
    cache.release(seg);
    try std.testing.expectEqual(@as(usize, 1), cache.free_count);

    // Acquire again (should get cached segment)
    const seg2 = cache.acquire() orelse return error.AllocFailed;
    try std.testing.expectEqual(@as(usize, 0), cache.free_count);

    // Release for cleanup
    releaseSegment(seg2);
}

test "segment from pointer lookup" {
    const seg = allocateSegment() orelse return error.AllocFailed;
    defer releaseSegment(seg);

    // Get pointer to middle of segment
    const mid_addr = @intFromPtr(seg) + config.SEGMENT_SIZE / 2;
    const mid_ptr: *anyopaque = @ptrFromInt(mid_addr);

    // Should resolve back to segment base
    const found = segmentFromPtr(mid_ptr);
    try std.testing.expectEqual(seg, found);
}

test "allocate all pages" {
    const seg = allocateSegment() orelse return error.AllocFailed;
    defer releaseSegment(seg);

    // Allocate all 31 remaining pages (page 0 is header)
    var i: u32 = 0;
    while (i < 31) : (i += 1) {
        const page = seg.allocPage();
        try std.testing.expect(page != null);
    }

    // Next allocation should fail
    try std.testing.expect(seg.allocPage() == null);
    try std.testing.expect(!seg.hasFreePages());
}
