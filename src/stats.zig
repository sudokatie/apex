// Statistics
//
// Allocation tracking and debugging support.
// Provides detailed metrics for profiling, debugging, and fragmentation analysis.

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

    // Current bytes in use
    active_bytes: Atomic(u64),

    const Self = @This();

    pub fn init() Self {
        return .{
            .alloc_count = Atomic(u64).init(0),
            .free_count = Atomic(u64).init(0),
            .active_count = Atomic(u64).init(0),
            .peak_count = Atomic(u64).init(0),
            .total_bytes = Atomic(u64).init(0),
            .active_bytes = Atomic(u64).init(0),
        };
    }

    pub fn recordAlloc(self: *Self, size: usize) void {
        _ = self.alloc_count.fetchAdd(1, .monotonic);
        _ = self.total_bytes.fetchAdd(size, .monotonic);
        _ = self.active_bytes.fetchAdd(size, .monotonic);

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

    pub fn recordFree(self: *Self, size: usize) void {
        _ = self.free_count.fetchAdd(1, .monotonic);
        _ = self.active_count.fetchSub(1, .monotonic);
        _ = self.active_bytes.fetchSub(size, .monotonic);
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
    large_active_bytes: Atomic(u64),

    // Huge allocation stats
    huge_alloc_count: Atomic(u64),
    huge_free_count: Atomic(u64),
    huge_bytes: Atomic(u64),
    huge_active_bytes: Atomic(u64),

    // Segment stats
    segments_allocated: Atomic(u64),
    segments_freed: Atomic(u64),
    segments_active: Atomic(u64),

    // Page stats
    pages_allocated: Atomic(u64),
    pages_freed: Atomic(u64),
    pages_active: Atomic(u64),

    // Fragmentation tracking
    total_requested: Atomic(u64),
    total_allocated_actual: Atomic(u64),

    // Thread cache stats
    cache_hits: Atomic(u64),
    cache_misses: Atomic(u64),

    // NUMA stats
    numa_local_allocs: Atomic(u64),
    numa_remote_allocs: Atomic(u64),

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
            .large_active_bytes = Atomic(u64).init(0),
            .huge_alloc_count = Atomic(u64).init(0),
            .huge_free_count = Atomic(u64).init(0),
            .huge_bytes = Atomic(u64).init(0),
            .huge_active_bytes = Atomic(u64).init(0),
            .segments_allocated = Atomic(u64).init(0),
            .segments_freed = Atomic(u64).init(0),
            .segments_active = Atomic(u64).init(0),
            .pages_allocated = Atomic(u64).init(0),
            .pages_freed = Atomic(u64).init(0),
            .pages_active = Atomic(u64).init(0),
            .total_requested = Atomic(u64).init(0),
            .total_allocated_actual = Atomic(u64).init(0),
            .cache_hits = Atomic(u64).init(0),
            .cache_misses = Atomic(u64).init(0),
            .numa_local_allocs = Atomic(u64).init(0),
            .numa_remote_allocs = Atomic(u64).init(0),
        };
    }

    // Record slab allocation
    pub fn recordSlabAlloc(self: *Self, size_class: usize, requested: usize) void {
        if (size_class < config.NUM_SIZE_CLASSES) {
            const actual = config.SIZE_CLASSES[size_class];
            self.size_class_stats[size_class].recordAlloc(actual);
            _ = self.total_requested.fetchAdd(requested, .monotonic);
            _ = self.total_allocated_actual.fetchAdd(actual, .monotonic);
        }
    }

    // Record slab free
    pub fn recordSlabFree(self: *Self, size_class: usize) void {
        if (size_class < config.NUM_SIZE_CLASSES) {
            const size = config.SIZE_CLASSES[size_class];
            self.size_class_stats[size_class].recordFree(size);
            _ = self.total_allocated_actual.fetchSub(size, .monotonic);
        }
    }

    // Record large allocation
    pub fn recordLargeAlloc(self: *Self, requested: usize, actual: usize) void {
        _ = self.large_alloc_count.fetchAdd(1, .monotonic);
        _ = self.large_bytes.fetchAdd(actual, .monotonic);
        _ = self.large_active_bytes.fetchAdd(actual, .monotonic);
        _ = self.total_requested.fetchAdd(requested, .monotonic);
        _ = self.total_allocated_actual.fetchAdd(actual, .monotonic);
    }

    // Record large free
    pub fn recordLargeFree(self: *Self, size: usize) void {
        _ = self.large_free_count.fetchAdd(1, .monotonic);
        _ = self.large_active_bytes.fetchSub(size, .monotonic);
        _ = self.total_allocated_actual.fetchSub(size, .monotonic);
    }

    // Record huge allocation
    pub fn recordHugeAlloc(self: *Self, requested: usize, actual: usize) void {
        _ = self.huge_alloc_count.fetchAdd(1, .monotonic);
        _ = self.huge_bytes.fetchAdd(actual, .monotonic);
        _ = self.huge_active_bytes.fetchAdd(actual, .monotonic);
        _ = self.total_requested.fetchAdd(requested, .monotonic);
        _ = self.total_allocated_actual.fetchAdd(actual, .monotonic);
    }

    // Record huge free
    pub fn recordHugeFree(self: *Self, size: usize) void {
        _ = self.huge_free_count.fetchAdd(1, .monotonic);
        _ = self.huge_active_bytes.fetchSub(size, .monotonic);
        _ = self.total_allocated_actual.fetchSub(size, .monotonic);
    }

    // Record segment allocation
    pub fn recordSegmentAlloc(self: *Self) void {
        _ = self.segments_allocated.fetchAdd(1, .monotonic);
        _ = self.segments_active.fetchAdd(1, .monotonic);
    }

    // Record segment free
    pub fn recordSegmentFree(self: *Self) void {
        _ = self.segments_freed.fetchAdd(1, .monotonic);
        _ = self.segments_active.fetchSub(1, .monotonic);
    }

    // Record cache hit
    pub fn recordCacheHit(self: *Self) void {
        _ = self.cache_hits.fetchAdd(1, .monotonic);
    }

    // Record cache miss
    pub fn recordCacheMiss(self: *Self) void {
        _ = self.cache_misses.fetchAdd(1, .monotonic);
    }

    // Record NUMA local allocation
    pub fn recordNumaLocal(self: *Self) void {
        _ = self.numa_local_allocs.fetchAdd(1, .monotonic);
    }

    // Record NUMA remote allocation
    pub fn recordNumaRemote(self: *Self) void {
        _ = self.numa_remote_allocs.fetchAdd(1, .monotonic);
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

    // Get active slab bytes
    pub fn getActiveSlabBytes(self: *Self) u64 {
        var total: u64 = 0;
        for (&self.size_class_stats) |*s| {
            total += s.active_bytes.load(.acquire);
        }
        return total;
    }

    // Get fragmentation ratio (0.0 = no fragmentation, higher = more fragmentation)
    pub fn getFragmentationRatio(self: *Self) f64 {
        const requested = self.total_requested.load(.acquire);
        const actual = self.total_allocated_actual.load(.acquire);

        if (requested == 0) return 0.0;
        if (actual <= requested) return 0.0;

        return (@as(f64, @floatFromInt(actual)) / @as(f64, @floatFromInt(requested))) - 1.0;
    }

    // Get fragmentation percentage
    pub fn getFragmentationPercent(self: *Self) f64 {
        return self.getFragmentationRatio() * 100.0;
    }

    // Get cache hit rate
    pub fn getCacheHitRate(self: *Self) f64 {
        const hits = self.cache_hits.load(.acquire);
        const misses = self.cache_misses.load(.acquire);
        const total = hits + misses;

        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total));
    }

    // Get NUMA locality rate
    pub fn getNumaLocalityRate(self: *Self) f64 {
        const local = self.numa_local_allocs.load(.acquire);
        const remote = self.numa_remote_allocs.load(.acquire);
        const total = local + remote;

        if (total == 0) return 1.0;
        return @as(f64, @floatFromInt(local)) / @as(f64, @floatFromInt(total));
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

        try writer.print("\nLarge Allocations: {d} ({d} active bytes)\n", .{
            self.large_alloc_count.load(.acquire),
            self.large_active_bytes.load(.acquire),
        });

        try writer.print("Huge Allocations: {d} ({d} active bytes)\n", .{
            self.huge_alloc_count.load(.acquire),
            self.huge_active_bytes.load(.acquire),
        });

        try writer.print("\nSegments: {d} allocated, {d} active\n", .{
            self.segments_allocated.load(.acquire),
            self.segments_active.load(.acquire),
        });

        try writer.print("\nFragmentation: {d:.1}%%\n", .{self.getFragmentationPercent()});
        try writer.print("Cache Hit Rate: {d:.1}%%\n", .{self.getCacheHitRate() * 100.0});
        try writer.print("NUMA Locality: {d:.1}%%\n", .{self.getNumaLocalityRate() * 100.0});
    }

    // Export as JSON
    pub fn toJson(self: *Self, writer: anytype) !void {
        try writer.print("{{", .{});
        try writer.print("\"slab_allocs\":{d},", .{self.getTotalSlabAllocs()});
        try writer.print("\"slab_active\":{d},", .{self.getActiveSlabAllocs()});
        try writer.print("\"slab_bytes\":{d},", .{self.getTotalSlabBytes()});
        try writer.print("\"large_allocs\":{d},", .{self.large_alloc_count.load(.acquire)});
        try writer.print("\"large_bytes\":{d},", .{self.large_active_bytes.load(.acquire)});
        try writer.print("\"huge_allocs\":{d},", .{self.huge_alloc_count.load(.acquire)});
        try writer.print("\"huge_bytes\":{d},", .{self.huge_active_bytes.load(.acquire)});
        try writer.print("\"segments_allocated\":{d},", .{self.segments_allocated.load(.acquire)});
        try writer.print("\"segments_active\":{d},", .{self.segments_active.load(.acquire)});
        try writer.print("\"fragmentation_pct\":{d:.2},", .{self.getFragmentationPercent()});
        try writer.print("\"cache_hit_rate\":{d:.4},", .{self.getCacheHitRate()});
        try writer.print("\"numa_locality\":{d:.4}", .{self.getNumaLocalityRate()});
        try writer.print("}}", .{});
    }
};

// Global stats instance
var global_stats: GlobalStats = GlobalStats.init();

pub fn getGlobalStats() *GlobalStats {
    return &global_stats;
}

// Reset all statistics
pub fn resetStats() void {
    global_stats = GlobalStats.init();
}

// ============= Tests =============

test "size class stats" {
    var stats = SizeClassStats.init();

    stats.recordAlloc(64);
    stats.recordAlloc(64);
    stats.recordAlloc(64);

    try std.testing.expectEqual(@as(u64, 3), stats.alloc_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), stats.active_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 192), stats.total_bytes.load(.acquire));

    stats.recordFree(64);
    try std.testing.expectEqual(@as(u64, 2), stats.active_count.load(.acquire));
}

test "size class peak tracking" {
    var stats = SizeClassStats.init();

    stats.recordAlloc(32);
    stats.recordAlloc(32);
    stats.recordAlloc(32);
    try std.testing.expectEqual(@as(u64, 3), stats.peak_count.load(.acquire));

    stats.recordFree(32);
    stats.recordFree(32);
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

    stats.recordSlabAlloc(0, 8); // 8 bytes requested, 8 actual
    stats.recordSlabAlloc(4, 50); // 50 bytes requested, 64 actual
    stats.recordLargeAlloc(4000, 4096);
    stats.recordHugeAlloc(3 * 1024 * 1024, 4 * 1024 * 1024);

    try std.testing.expectEqual(@as(u64, 2), stats.getTotalSlabAllocs());
    try std.testing.expectEqual(@as(u64, 1), stats.large_alloc_count.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), stats.huge_alloc_count.load(.acquire));
}

test "fragmentation calculation" {
    var stats = GlobalStats.init();

    // Request 100 bytes, get 128 (28% overhead)
    stats.recordSlabAlloc(7, 100); // Size class 7 = 128 bytes

    const frag = stats.getFragmentationPercent();
    try std.testing.expect(frag > 0.0);
    try std.testing.expect(frag < 50.0); // Should be ~28%
}

test "cache hit rate" {
    var stats = GlobalStats.init();

    stats.recordCacheHit();
    stats.recordCacheHit();
    stats.recordCacheHit();
    stats.recordCacheMiss();

    const hit_rate = stats.getCacheHitRate();
    try std.testing.expectEqual(@as(f64, 0.75), hit_rate);
}

test "stats json output" {
    var stats = GlobalStats.init();

    stats.recordSlabAlloc(0, 8);
    stats.recordLargeAlloc(1000, 1024);

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try stats.toJson(stream.writer());

    const json = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"slab_allocs\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fragmentation_pct\":") != null);
}
