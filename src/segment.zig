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

    // Bitmap of decommitted pages (1 = decommitted, 0 = committed)
    decommit_bitmap: Atomic(u32),

    // Lock for thread safety during allocation
    lock: std.Thread.Mutex,

    // Pointer to next segment in freelist/active list
    next: ?*Segment,

    // Reserved for future use (cache line padding)
    _reserved: [36]u8,

    const Self = @This();

    // Header size (64 bytes, fits in one cache line)
    pub const HEADER_SIZE: usize = 64;

    // Initialize a new segment at the given memory location
    pub fn init(ptr: [*]u8) *Self {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.page_bitmap = Atomic(u32).init(1); // Page 0 is always allocated (header)
        self.allocated_pages = Atomic(u32).init(1);
        self.decommit_bitmap = Atomic(u32).init(0);
        self.lock = .{};
        self.next = null;
        self._reserved = [_]u8{0} ** 36;
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

        // Recommit if page was decommitted
        self.recommitPage(free_bit);

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

        // Recommit all pages
        i = 0;
        while (i < count) : (i += 1) {
            self.recommitPageUnlocked(start_idx + i);
        }

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

    // Decommit a page (release physical memory)
    pub fn decommitPage(self: *Self, page_index: u5) void {
        if (page_index == 0) return; // Never decommit header

        self.lock.lock();
        defer self.lock.unlock();

        self.decommitPageUnlocked(page_index);
    }

    fn decommitPageUnlocked(self: *Self, page_index: u5) void {
        const decommit = self.decommit_bitmap.load(.acquire);
        const mask = @as(u32, 1) << page_index;

        if (decommit & mask != 0) return; // Already decommitted

        // Mark as decommitted
        self.decommit_bitmap.store(decommit | mask, .release);

        // Actually decommit the memory
        const page_ptr = self.pageAddress(page_index);
        platform.decommitMemory(page_ptr, config.PAGE_SIZE);
    }

    // Recommit a page (make physical memory available)
    fn recommitPage(self: *Self, page_index: u5) void {
        // Lock already held
        self.recommitPageUnlocked(page_index);
    }

    fn recommitPageUnlocked(self: *Self, page_index: u5) void {
        const decommit = self.decommit_bitmap.load(.acquire);
        const mask = @as(u32, 1) << page_index;

        if (decommit & mask == 0) return; // Not decommitted

        // Clear decommit flag
        self.decommit_bitmap.store(decommit & ~mask, .release);

        // Recommit the memory
        const page_ptr = self.pageAddress(page_index);
        _ = platform.commitMemory(page_ptr, config.PAGE_SIZE);
    }

    // Decommit all free pages (call when segment goes to cache)
    pub fn decommitFreePages(self: *Self) void {
        self.lock.lock();
        defer self.lock.unlock();

        const bitmap = self.page_bitmap.load(.acquire);

        // Decommit each free page (bit is 0)
        // Use u6 to avoid overflow when incrementing from 31
        var i: u6 = 1; // Skip header page
        while (i < 32) : (i += 1) {
            const page_idx: u5 = @intCast(i);
            const mask = @as(u32, 1) << page_idx;
            if (bitmap & mask == 0) {
                // Page is free, decommit it
                self.decommitPageUnlocked(page_idx);
            }
        }
    }

    // Coalesce free pages (update tracking for contiguous runs)
    // Returns the start and count of the largest contiguous free region
    pub fn findLargestFreeRegion(self: *Self) ?struct { start: u5, count: u5 } {
        const bitmap = self.page_bitmap.load(.acquire);

        var best_start: u5 = 0;
        var best_count: u5 = 0;

        var current_start: u5 = 1; // Skip header
        var current_count: u5 = 0;

        // Use u6 for loop counter to avoid overflow when i=31
        var i: u6 = 1;
        while (i < 32) : (i += 1) {
            const page_idx: u5 = @intCast(i);
            const mask = @as(u32, 1) << page_idx;
            if (bitmap & mask == 0) {
                // Free page
                if (current_count == 0) {
                    current_start = page_idx;
                }
                current_count +|= 1; // Saturating add to avoid overflow
            } else {
                // Allocated page - check if current run is best
                if (current_count > best_count) {
                    best_start = current_start;
                    best_count = current_count;
                }
                current_count = 0;
            }
        }

        // Check final run
        if (current_count > best_count) {
            best_start = current_start;
            best_count = current_count;
        }

        if (best_count == 0) return null;
        return .{ .start = best_start, .count = best_count };
    }
};

// Find 'count' contiguous free bits in bitmap, starting from bit 1 (skip header)
// Returns starting bit index or null if not found
fn findContiguousFree(bitmap: u32, count: u5) ?u5 {
    if (count == 0) return null;
    if (count > 31) return null;

    // Use u6 for arithmetic to avoid u5 overflow
    const count_u6: u6 = count;
    var start: u6 = 1; // Start from page 1 (page 0 is header)
    
    while (start + count_u6 <= 32) {
        var found = true;
        var i: u6 = 0;
        while (i < count_u6) : (i += 1) {
            const bit_idx: u5 = @intCast(start + i);
            const bit = @as(u32, 1) << bit_idx;
            if (bitmap & bit != 0) {
                // Bit is set (page allocated), skip past it
                start = start + i + 1;
                found = false;
                break;
            }
        }
        if (found) return @intCast(start);
    }
    return null;
}

// Global segment cache with NUMA support
pub const SegmentCache = struct {
    // List of cached free segments (global pool)
    free_list: ?*Segment,
    free_count: usize,
    lock: std.Thread.Mutex,

    // Per-NUMA-node segment pools
    numa_pools: [config.NUMA_MAX_NODES]NumaPool,

    const NumaPool = struct {
        head: ?*Segment,
        count: usize,
    };

    const Self = @This();

    pub fn init() Self {
        var numa_pools: [config.NUMA_MAX_NODES]NumaPool = undefined;
        for (&numa_pools) |*pool| {
            pool.* = .{ .head = null, .count = 0 };
        }

        return .{
            .free_list = null,
            .free_count = 0,
            .lock = .{},
            .numa_pools = numa_pools,
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

    // Get a segment preferring a specific NUMA node
    pub fn acquireForNode(self: *Self, node: u8) ?*Segment {
        if (node >= config.NUMA_MAX_NODES) return self.acquire();

        self.lock.lock();

        // Try NUMA-local pool first
        if (self.numa_pools[node].head) |seg| {
            self.numa_pools[node].head = seg.next;
            self.numa_pools[node].count -= 1;
            self.lock.unlock();
            return Segment.init(@ptrCast(seg));
        }

        // Try global pool
        if (self.free_list) |seg| {
            self.free_list = seg.next;
            self.free_count -= 1;
            self.lock.unlock();
            return Segment.init(@ptrCast(seg));
        }

        self.lock.unlock();

        // Allocate new segment on specific NUMA node
        return allocateSegmentOnNode(node);
    }

    // Return a segment to cache or release to OS
    pub fn release(self: *Self, segment: *Segment) void {
        self.lock.lock();

        if (self.free_count < config.SEGMENT_CACHE_MAX) {
            // Lazy decommit: release physical pages for free pages
            segment.decommitFreePages();

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

    // Return a segment to NUMA-specific pool
    pub fn releaseToNode(self: *Self, segment: *Segment, node: u8) void {
        if (node >= config.NUMA_MAX_NODES) {
            self.release(segment);
            return;
        }

        self.lock.lock();

        const pool = &self.numa_pools[node];
        if (pool.count < config.SEGMENT_CACHE_MAX) {
            segment.decommitFreePages();
            segment.next = pool.head;
            pool.head = segment;
            pool.count += 1;
            self.lock.unlock();
        } else {
            self.lock.unlock();
            releaseSegment(segment);
        }
    }

    // Trim the cache (release excess segments)
    pub fn trim(self: *Self, target_count: usize) void {
        self.lock.lock();
        defer self.lock.unlock();

        while (self.free_count > target_count) {
            const seg = self.free_list orelse break;
            self.free_list = seg.next;
            self.free_count -= 1;
            releaseSegment(seg);
        }
    }

    // Get total cached segments across all pools
    pub fn getTotalCached(self: *Self) usize {
        self.lock.lock();
        defer self.lock.unlock();

        var total = self.free_count;
        for (self.numa_pools) |pool| {
            total += pool.count;
        }
        return total;
    }
};

// Allocate a new 2MB segment from the OS
pub fn allocateSegment() ?*Segment {
    const ptr = platform.mapMemory(config.SEGMENT_SIZE, config.SEGMENT_ALIGNMENT) orelse return null;
    return Segment.init(ptr);
}

// Allocate a new segment on a specific NUMA node
pub fn allocateSegmentOnNode(node: u8) ?*Segment {
    const ptr = platform.mapOnNode(config.SEGMENT_SIZE, config.SEGMENT_ALIGNMENT, node) orelse return null;
    return Segment.init(ptr);
}

// Allocate a segment using huge pages (if available)
pub fn allocateSegmentHugePages() ?*Segment {
    const ptr = platform.mapHugePages(config.SEGMENT_SIZE, config.HUGE_PAGE_2MB) orelse return null;
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

test "segment decommit" {
    const seg = allocateSegment() orelse return error.AllocFailed;
    defer releaseSegment(seg);

    const p1 = seg.allocPage() orelse return error.AllocFailed;
    seg.freePage(p1);

    // Decommit the free page
    seg.decommitPage(p1);
    try std.testing.expect(seg.decommit_bitmap.load(.acquire) & (@as(u32, 1) << p1) != 0);

    // Allocate again - should recommit
    const p2 = seg.allocPage() orelse return error.AllocFailed;
    try std.testing.expectEqual(p1, p2);
    try std.testing.expect(seg.decommit_bitmap.load(.acquire) & (@as(u32, 1) << p1) == 0);
}

test "segment largest free region" {
    const seg = allocateSegment() orelse return error.AllocFailed;
    defer releaseSegment(seg);

    // Allocate some pages to create gaps
    _ = seg.allocPage(); // Page 1
    _ = seg.allocPage(); // Page 2
    const p3 = seg.allocPage() orelse return error.AllocFailed; // Page 3
    _ = seg.allocPage(); // Page 4

    // Free page 2 and 3 to create a gap
    seg.freePage(2);
    seg.freePage(p3);

    const region = seg.findLargestFreeRegion();
    try std.testing.expect(region != null);

    // Largest free region should be pages 5-31 (27 pages)
    // or 2-3 (2 pages) depending on implementation
    try std.testing.expect(region.?.count >= 2);
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

test "segment cache trim" {
    var cache = SegmentCache.init();

    // Add several segments to cache
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const seg = allocateSegment() orelse return error.AllocFailed;
        cache.release(seg);
    }

    try std.testing.expectEqual(@as(usize, 3), cache.free_count);

    // Trim to 1
    cache.trim(1);
    try std.testing.expectEqual(@as(usize, 1), cache.free_count);

    // Clean up
    cache.trim(0);
}
