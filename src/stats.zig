// Statistics
//
// Allocation tracking and debugging support.
// Provides detailed metrics for profiling and debugging.

const std = @import("std");
const config = @import("config.zig");

const Atomic = std.atomic.Value;

// Per-size-class statistics
pub const SizeClassStats = struct {
    // Number of allocations
    alloc_count: Atomic(u64),

    // Number of frees
    free_count: Atomic(u64),

    // Current active allocations
    active_count: Atomic(u64),

    // Peak active allocations
    peak_count: Atomic(u64),

    // Total bytes allocated (cumulative)
    total_bytes: Atomic(u64),

    const Self = @This();

    pub fn init() Self {
        return .{
            .alloc_count = Atomic(u64).init(0),
            .free_count = Atomic(u64).init(0),
            .active_count = Atomic(u64).init(0),
            .peak_count = Atomic(u64).init(0),
            .total_bytes = Atomic(u64).init(0),
        };
    }

    pub fn recordAlloc(self: *Self, size: usize) void {
        _ = self.alloc_count.fetchAdd(1, .monotonic);
        _ = self.total_bytes.fetchAdd(size, .monotonic);

        const active = self.active_count.fetchAdd(1, .monotonic) + 1;

        // Update peak if needed
        var peak = self.peak_count.load(.monotonic);
        while (active > peak) {
            const result = self.peak_count.cmpxchgWeak(peak, active, .monotonic, .monotonic);
            if (result) |current| {
                peak = current;
            } else {
                break;
            }
        }
    }

    pub fn recordFree(self: *Self) void {
        _ = self.free_count.fetchAdd(1, .monotonic);
        _ = self.active_count.fetchSub(1, .monotonic);
    }
};

// Global allocator statistics
pub const GlobalStats = struct {
    // Per-size-class stats
    size_class_stats: [config.NUM_SIZE_CLASSES]SizeClassStats,

    // Large allocation stats
    large_alloc_count: Atomic(u64),
    large_free_count: Atomic(u64),
    large_bytes: Atomic(u64),

    // Huge allocation stats
    huge_alloc_count: Atomic(u64),
    huge_free_count: Atomic(u64),
    huge_bytes: Atomic(u64),

    // Segment stats
    segments_allocated: Atomic(u64),
    segments_freed: Atomic(u64),

    // Page stats
    pages_allocated: Atomic(u64),
    pages_freed: Atomic(u64),

    const Self = @This();

    pub fn init() Self {
        var stats: [config.NUM_SIZE_CLASSES]SizeClassStats = undefined;
        for (&stats) |*s| {
            s.* = SizeClassStats.init();
        }

        return .{
            .size_class_stats = stats,
            .large_alloc_count = Atomic(u64).init(0),
            .large_free_count = Atomic(u64).init(0),
            .large_bytes = Atomic(u64).init(0),
            .huge_alloc_count = Atomic(u64).init(0),
            .huge_free_count = Atomic(u64).init(0),
            .huge_bytes = Atomic(u64).init(0),
            .segments_allocated = Atomic(u64).init(0),
            .segments_freed = Atomic(u64).init(0),
            .pages_allocated = Atomic(u64).init(0),
            .pages_freed = Atomic(u64).init(0),
        };
    }

    // Record slab allocation
    pub fn recordSlabAlloc(self: *Self, size_class: usize) void {
        if (size_class < config.NUM_SIZE_CLASSES) {
            self.size_class_stats[size_class].recordAlloc(config.SIZE_CLASSES[size_class]);
        }
    }

    // Record slab free
    pub fn recordSlabFree(self: *Self, size_class: usize) void {
        if (size_class < config.NUM_SIZE_CLASSES) {
            self.size_class_stats[size_class].recordFree();
        }
    }

    // Record large allocation
    pub fn recordLargeAlloc(self: *Self, size: usize) void {
        _ = self.large_alloc_count.fetchAdd(1, .monotonic);
        _ = self.large_bytes.fetchAdd(size, .monotonic);
    }

    // Record large free
    pub fn recordLargeFree(self: *Self) void {
        _ = self.large_free_count.fetchAdd(1, .monotonic);
    }

    // Record huge allocation
    pub fn recordHugeAlloc(self: *Self, size: usize) void {
        _ = self.huge_alloc_count.fetchAdd(1, .monotonic);
        _ = self.huge_bytes.fetchAdd(size, .monotonic);
    }

    // Record huge free
    pub fn recordHugeFree(self: *Self) void {
        _ = self.huge_free_count.fetchAdd(1, .monotonic);
    }

    // Record segment allocation
    pub fn recordSegmentAlloc(self: *Self) void {
        _ = self.segments_allocated.fetchAdd(1, .monotonic);
    }

    // Record segment free
    pub fn recordSegmentFree(self: *Self) void {
        _ = self.segments_freed.fetchAdd(1, .monotonic);
    }

    // Get total slab allocations
    pub fn getTotalSlabAllocs(self: *Self) u64 {
        var total: u64 = 0;
        for (&self.size_class_stats) |*s| {
            total += s.alloc_count.load(.acquire);
        }
        return total;
    }

    // Get total active slab allocations
    pub fn getActiveSlabAllocs(self: *Self) u64 {
        var total: u64 = 0;
        for (&self.size_class_stats) |*s| {
            total += s.active_count.load(.acquire);
        }
        return total;
    }

    // Get total slab bytes
    pub fn getTotalSlabBytes(self: *Self) u64 {
        var total: u64 = 0;
        for (&self.size_class_stats) |*s| {
            total += s.total_bytes.load(.acquire);
        }
        return total;
    }

    // Print stats summary
    pub fn printSummary(self: *Self, writer: anytype) !void {
        try writer.print("=== Apex Allocator Statistics ===\n\n", .{});

        // Slab stats
        try writer.print("Slab Allocations:\n", .{});
        for (self.size_class_stats, 0..) |*s, i| {
            const allocs = s.alloc_count.load(.acquire);
            if (allocs > 0) {
                try writer.print("  {d:>5} bytes: {d} allocs, {d} active, {d} peak\n", .{
                    config.SIZE_CLASSES[i],
                    allocs,
                    s.active_count.load(.acquire),
                    s.peak_count.load(.acquire),
                });
            }
        }

        try writer.print("\nLarge Allocations: {d} ({d} bytes)\n", .{
            self.large_alloc_count.load(.acquire),
            self.large_bytes.load(.acquire),
        });

        try writer.print("Huge Allocations: {d} ({d} bytes)\n", .{
            self.huge_alloc_count.load(.acquire),
            self.huge_bytes.load(.acquire),
        });

        try writer.print("\nSegments: {d} allocated, {d} freed\n", .{
            self.segments_allocated.load(.acquire),
            self.segments_freed.load(.acquire),
        });
    }

    // Export as JSON
    pub fn toJson(self: *Self, writer: anytype) !void {
        try writer.print("{{", .{});
        try writer.print("\"slab_allocs\":{d},", .{self.getTotalSlabAllocs()});
        try writer.print("\"slab_active\":{d},", .{self.getActiveSlabAllocs()});
        try writer.print("\"slab_bytes\":{d},", .{self.getTotalSlabBytes()});
        try writer.print("\"large_allocs\":{d},", .{self.large_alloc_count.load(.acquire)});
        try writer.print("\"large_bytes\":{d},", .{self.large_bytes.load(.acquire)});
        try writer.print("\"huge_allocs\":{d},", .{self.huge_alloc_count.load(.acquire)});
        try writer.print("\"huge_bytes\":{d},", .{self.huge_bytes.load(.acquire)});
        try writer.print("\"segments_allocated\":{d},", .{self.segments_allocated.load(.acquire)});
        try writer.print("\"segments_freed\":{d}", .{self.segments_freed.load(.acquire)});
        try writer.print("}}", .{});
    }
};

// Global stats instance
var global_stats: GlobalStats = GlobalStats.init();

pub fn getGlobalStats() *GlobalStats {
    return &global_stats;
}

// Tests
test "size class stats" {
    var stats = SizeClassStats.init();

    stats.recordAlloc(64);
    stats.recordAlloc(64);
    stats.recordAlloc(64);

    try std.testing.expectEqual(@as(u64, 3), stats.alloc_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), stats.active_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 192), stats.total_bytes.load(.acquire));

    stats.recordFree();
    try std.testing.expectEqual(@as(u64, 2), stats.active_count.load(.acquire));
}

test "size class peak tracking" {
    var stats = SizeClassStats.init();

    stats.recordAlloc(32);
    stats.recordAlloc(32);
    stats.recordAlloc(32);
    try std.testing.expectEqual(@as(u64, 3), stats.peak_count.load(.acquire));

    stats.recordFree();
    stats.recordFree();
    try std.testing.expectEqual(@as(u64, 1), stats.active_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), stats.peak_count.load(.acquire)); // Peak unchanged

    stats.recordAlloc(32);
    stats.recordAlloc(32);
    stats.recordAlloc(32);
    stats.recordAlloc(32);
    try std.testing.expectEqual(@as(u64, 5), stats.peak_count.load(.acquire)); // New peak
}

test "global stats" {
    var stats = GlobalStats.init();

    stats.recordSlabAlloc(0); // 8 bytes
    stats.recordSlabAlloc(4); // 64 bytes
    stats.recordLargeAlloc(4096);
    stats.recordHugeAlloc(4 * 1024 * 1024);

    try std.testing.expectEqual(@as(u64, 2), stats.getTotalSlabAllocs());
    try std.testing.expectEqual(@as(u64, 1), stats.large_alloc_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), stats.huge_alloc_count.load(.acquire));
}

test "stats json output" {
    var stats = GlobalStats.init();

    stats.recordSlabAlloc(0);
    stats.recordLargeAlloc(1024);

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try stats.toJson(stream.writer());

    const json = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"slab_allocs\":1") != null);
}
