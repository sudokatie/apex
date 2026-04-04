// Arena Allocator
//
// Fast bump-pointer allocation with bulk deallocation.
// No individual frees - memory is released all at once via reset() or deinit().
// Supports optional backing allocator (per spec 8.2).

const std = @import("std");
const config = @import("config.zig");
const platform = @import("platform.zig");
const heap_mod = @import("heap.zig");

// Backing allocator type
pub const BackingAllocator = union(enum) {
    platform: void, // Use platform.mapMemory
    heap: *heap_mod.Heap, // Use Apex heap
    std_allocator: std.mem.Allocator, // Use any std.mem.Allocator

    pub fn alloc(self: BackingAllocator, size: usize) ?[*]u8 {
        return switch (self) {
            .platform => platform.mapMemory(size, std.heap.page_size_min),
            .heap => |h| h.alloc(size),
            .std_allocator => |a| {
                const slice = a.alloc(u8, size) catch return null;
                return slice.ptr;
            },
        };
    }

    pub fn free(self: BackingAllocator, ptr: [*]u8, size: usize) void {
        switch (self) {
            .platform => platform.unmapMemory(ptr, size),
            .heap => |h| h.free(ptr),
            .std_allocator => |a| {
                a.free(ptr[0..size]);
            },
        }
    }
};

// Arena chunk - a contiguous block of memory
const Chunk = struct {
    // Pointer to usable memory
    data: [*]u8,

    // Total size of this chunk
    size: usize,

    // Current offset (next allocation position)
    offset: usize,

    // Next chunk in list
    next: ?*Chunk,

    // Backing allocator used for this chunk
    backing: BackingAllocator,

    const HEADER_SIZE: usize = 64;

    fn create(size: usize, backing: BackingAllocator) ?*Chunk {
        const total = size + HEADER_SIZE;
        const ptr = backing.alloc(total) orelse return null;

        const chunk: *Chunk = @ptrCast(@alignCast(ptr));
        chunk.data = ptr + HEADER_SIZE;
        chunk.size = size;
        chunk.offset = 0;
        chunk.next = null;
        chunk.backing = backing;

        return chunk;
    }

    fn destroy(self: *Chunk) void {
        const ptr: [*]u8 = @ptrCast(self);
        const total = self.size + HEADER_SIZE;
        self.backing.free(ptr, total);
    }

    fn remaining(self: *Chunk) usize {
        return self.size - self.offset;
    }

    fn alloc(self: *Chunk, size: usize, alignment: usize) ?[*]u8 {
        // Align the current offset
        const aligned_offset = alignUp(self.offset, alignment);

        if (aligned_offset + size > self.size) {
            return null;
        }

        const ptr = self.data + aligned_offset;
        self.offset = aligned_offset + size;

        return ptr;
    }

    fn reset(self: *Chunk) void {
        self.offset = 0;
    }
};

// Arena allocator
pub const Arena = struct {
    // First chunk
    head: ?*Chunk,

    // Current chunk for allocations
    current: ?*Chunk,

    // Default chunk size
    chunk_size: usize,

    // Backing allocator
    backing: BackingAllocator,

    // Statistics
    total_allocated: usize,
    chunk_count: usize,
    peak_allocated: usize,

    const Self = @This();

    // Default chunk size: 64KB
    const DEFAULT_CHUNK_SIZE: usize = 64 * 1024;

    /// Create arena with default settings (uses platform mmap)
    pub fn init() Self {
        return initWithBacking(.{ .platform = {} });
    }

    /// Create arena with custom chunk size
    pub fn initWithSize(chunk_size: usize) Self {
        return .{
            .head = null,
            .current = null,
            .chunk_size = chunk_size,
            .backing = .{ .platform = {} },
            .total_allocated = 0,
            .chunk_count = 0,
            .peak_allocated = 0,
        };
    }

    /// Create arena with backing allocator (per spec 8.2)
    pub fn initWithBacking(backing: BackingAllocator) Self {
        return .{
            .head = null,
            .current = null,
            .chunk_size = DEFAULT_CHUNK_SIZE,
            .backing = backing,
            .total_allocated = 0,
            .chunk_count = 0,
            .peak_allocated = 0,
        };
    }

    /// Create arena with backing allocator and custom chunk size
    pub fn initFull(backing: BackingAllocator, chunk_size: usize) Self {
        return .{
            .head = null,
            .current = null,
            .chunk_size = chunk_size,
            .backing = backing,
            .total_allocated = 0,
            .chunk_count = 0,
            .peak_allocated = 0,
        };
    }

    // Allocate memory from arena
    pub fn alloc(self: *Self, size: usize) ?[*]u8 {
        return self.allocAligned(size, 8);
    }

    // Allocate with specific alignment
    pub fn allocAligned(self: *Self, size: usize, alignment: usize) ?[*]u8 {
        if (size == 0) return null;

        // Try current chunk
        if (self.current) |chunk| {
            if (chunk.alloc(size, alignment)) |ptr| {
                self.total_allocated += size;
                self.peak_allocated = @max(self.peak_allocated, self.total_allocated);
                return ptr;
            }
        }

        // Need a new chunk
        const chunk_size = @max(self.chunk_size, size + alignment);
        const chunk = Chunk.create(chunk_size, self.backing) orelse return null;

        // Link to list
        chunk.next = self.head;
        self.head = chunk;
        self.current = chunk;
        self.chunk_count += 1;

        if (chunk.alloc(size, alignment)) |ptr| {
            self.total_allocated += size;
            self.peak_allocated = @max(self.peak_allocated, self.total_allocated);
            return ptr;
        }

        return null;
    }

    // Allocate a typed value
    pub fn create(self: *Self, comptime T: type) ?*T {
        const ptr = self.allocAligned(@sizeOf(T), @alignOf(T)) orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    // Allocate an array
    pub fn allocSlice(self: *Self, comptime T: type, count: usize) ?[]T {
        const size = @sizeOf(T) * count;
        const ptr = self.allocAligned(size, @alignOf(T)) orelse return null;
        const typed: [*]T = @ptrCast(@alignCast(ptr));
        return typed[0..count];
    }

    // Duplicate a string
    pub fn dupe(self: *Self, str: []const u8) ?[]u8 {
        const ptr = self.alloc(str.len) orelse return null;
        @memcpy(ptr[0..str.len], str);
        return ptr[0..str.len];
    }

    // Reset arena (keep chunks but reset offsets)
    pub fn reset(self: *Self) void {
        var chunk = self.head;
        while (chunk) |c| {
            c.reset();
            chunk = c.next;
        }
        self.current = self.head;
        self.total_allocated = 0;
    }

    // Free all memory
    pub fn deinit(self: *Self) void {
        var chunk = self.head;
        while (chunk) |c| {
            const next = c.next;
            c.destroy();
            chunk = next;
        }
        self.head = null;
        self.current = null;
        self.total_allocated = 0;
        self.chunk_count = 0;
    }

    // Get total allocated bytes
    pub fn getTotalAllocated(self: *Self) usize {
        return self.total_allocated;
    }

    // Get chunk count
    pub fn getChunkCount(self: *Self) usize {
        return self.chunk_count;
    }

    // Get total capacity
    pub fn getTotalCapacity(self: *Self) usize {
        var total: usize = 0;
        var chunk = self.head;
        while (chunk) |c| {
            total += c.size;
            chunk = c.next;
        }
        return total;
    }

    // Get peak allocated bytes
    pub fn getPeakAllocated(self: *Self) usize {
        return self.peak_allocated;
    }

    // Get fragmentation ratio (1.0 = no fragmentation)
    pub fn getEfficiency(self: *Self) f64 {
        const capacity = self.getTotalCapacity();
        if (capacity == 0) return 1.0;
        return @as(f64, @floatFromInt(self.total_allocated)) / @as(f64, @floatFromInt(capacity));
    }
};

// Align value up to alignment
fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

// Zig allocator interface wrapper
pub const ArenaAllocator = struct {
    arena: *Arena,

    const Self = @This();

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .free = freeFn,
            },
        };
    }

    fn allocFn(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.arena.allocAligned(len, @as(usize, 1) << @intCast(ptr_align));
    }

    fn resizeFn(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;
        return false; // Arena doesn't support resize
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = ret_addr;
        // Arena doesn't free individual allocations
    }
};

// ============= Tests =============

test "arena basic allocation" {
    var arena = Arena.init();
    defer arena.deinit();

    const p1 = arena.alloc(100) orelse return error.AllocFailed;
    const p2 = arena.alloc(200) orelse return error.AllocFailed;
    const p3 = arena.alloc(300) orelse return error.AllocFailed;

    p1[0] = 1;
    p2[0] = 2;
    p3[0] = 3;

    try std.testing.expectEqual(@as(usize, 1), arena.getChunkCount());
}

test "arena with backing allocator" {
    // Test with std page allocator as backing
    var arena = Arena.initWithBacking(.{ .std_allocator = std.heap.page_allocator });
    defer arena.deinit();

    const p1 = arena.alloc(100) orelse return error.AllocFailed;
    p1[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), p1[0]);
}

test "arena with heap backing" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    var arena = Arena.initWithBacking(.{ .heap = &heap });
    defer arena.deinit();

    const p1 = arena.alloc(100) orelse return error.AllocFailed;
    p1[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), p1[0]);
}

test "arena typed allocation" {
    var arena = Arena.init();
    defer arena.deinit();

    const Point = struct { x: i32, y: i32 };

    const p = arena.create(Point) orelse return error.AllocFailed;
    p.x = 10;
    p.y = 20;

    try std.testing.expectEqual(@as(i32, 10), p.x);
    try std.testing.expectEqual(@as(i32, 20), p.y);
}

test "arena slice allocation" {
    var arena = Arena.init();
    defer arena.deinit();

    const slice = arena.allocSlice(u32, 100) orelse return error.AllocFailed;

    for (slice, 0..) |*val, i| {
        val.* = @intCast(i);
    }

    try std.testing.expectEqual(@as(u32, 50), slice[50]);
}

test "arena string duplication" {
    var arena = Arena.init();
    defer arena.deinit();

    const original = "Hello, Arena!";
    const duped = arena.dupe(original) orelse return error.AllocFailed;

    try std.testing.expectEqualStrings(original, duped);
}

test "arena reset" {
    var arena = Arena.init();
    defer arena.deinit();

    // Allocate some memory
    _ = arena.alloc(1000) orelse return error.AllocFailed;
    _ = arena.alloc(2000) orelse return error.AllocFailed;

    const before = arena.getTotalAllocated();
    try std.testing.expect(before > 0);

    // Reset
    arena.reset();

    try std.testing.expectEqual(@as(usize, 0), arena.getTotalAllocated());
    try std.testing.expect(arena.getChunkCount() > 0); // Chunks still exist

    // Can allocate again
    _ = arena.alloc(500) orelse return error.AllocFailed;
}

test "arena large allocation" {
    var arena = Arena.init();
    defer arena.deinit();

    // Allocate more than default chunk size
    const large = arena.alloc(128 * 1024) orelse return error.AllocFailed;
    large[0] = 42;

    try std.testing.expect(arena.getChunkCount() >= 1);
}

test "arena multiple chunks" {
    var arena = Arena.initWithSize(1024); // Small chunks
    defer arena.deinit();

    // Allocate enough to need multiple chunks
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = arena.alloc(512) orelse return error.AllocFailed;
    }

    try std.testing.expect(arena.getChunkCount() > 1);
}

test "arena efficiency" {
    var arena = Arena.init();
    defer arena.deinit();

    _ = arena.alloc(32000) orelse return error.AllocFailed;

    const efficiency = arena.getEfficiency();
    try std.testing.expect(efficiency > 0.4); // At least 40% efficient
}

test "arena peak tracking" {
    var arena = Arena.init();
    defer arena.deinit();

    _ = arena.alloc(1000) orelse return error.AllocFailed;
    _ = arena.alloc(2000) orelse return error.AllocFailed;

    const peak1 = arena.getPeakAllocated();
    try std.testing.expect(peak1 >= 3000);

    arena.reset();

    _ = arena.alloc(500) orelse return error.AllocFailed;

    // Peak should be unchanged
    try std.testing.expectEqual(peak1, arena.getPeakAllocated());
}
