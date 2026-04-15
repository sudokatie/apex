// Profiling module for Apex memory allocator
//
// Provides allocation tracking and statistics for memory profiling.

const std = @import("std");

/// Categories of memory allocations
pub const AllocationCategory = enum(u3) {
    Heap = 0,
    Large = 1,
    Arena = 2,
    Slab = 3,
    ThreadCache = 4,

    pub const count: usize = 5;
};

/// Record of a single allocation event
pub const AllocationRecord = struct {
    size: usize,
    timestamp: u64,
    category: AllocationCategory,
};

/// Statistics for a single allocation category
pub const CategoryStats = struct {
    category: AllocationCategory,
    allocation_count: usize,
    total_bytes: usize,

    /// Compute average allocation size for this category
    pub fn avgSize(self: CategoryStats) usize {
        if (self.allocation_count == 0) return 0;
        return self.total_bytes / self.allocation_count;
    }
};

/// Summary snapshot of profiling data
pub const ProfilingSummary = struct {
    total_allocations: usize,
    total_frees: usize,
    current_bytes: usize,
    peak_bytes: usize,
    per_category: [AllocationCategory.count]CategoryStats,
    timestamp: u64,
};

/// Maximum number of records in the circular buffer
pub const MAX_RECORDS: usize = 10000;

/// Memory allocation profiler with circular buffer for allocation records
pub const Profiler = struct {
    enabled: bool,
    records: std.ArrayList(AllocationRecord),
    allocator: std.mem.Allocator,
    total_allocations: usize,
    total_frees: usize,
    current_bytes: usize,
    peak_bytes: usize,
    per_category_counts: [AllocationCategory.count]usize,
    per_category_bytes: [AllocationCategory.count]usize,
    write_index: usize,

    /// Initialize a new profiler
    pub fn init(allocator: std.mem.Allocator) Profiler {
        return Profiler{
            .enabled = false,
            .records = .{},
            .allocator = allocator,
            .total_allocations = 0,
            .total_frees = 0,
            .current_bytes = 0,
            .peak_bytes = 0,
            .per_category_counts = [_]usize{0} ** AllocationCategory.count,
            .per_category_bytes = [_]usize{0} ** AllocationCategory.count,
            .write_index = 0,
        };
    }

    /// Clean up profiler resources
    pub fn deinit(self: *Profiler) void {
        self.records.deinit(self.allocator);
    }

    /// Enable profiling
    pub fn enable(self: *Profiler) void {
        self.enabled = true;
    }

    /// Disable profiling
    pub fn disable(self: *Profiler) void {
        self.enabled = false;
    }

    /// Check if profiling is enabled
    pub fn isEnabled(self: *const Profiler) bool {
        return self.enabled;
    }

    /// Record an allocation event
    pub fn recordAlloc(self: *Profiler, size: usize, category: AllocationCategory) void {
        if (!self.enabled) return;

        const timestamp = getTimestamp();
        const record = AllocationRecord{
            .size = size,
            .timestamp = timestamp,
            .category = category,
        };

        // Add to circular buffer
        if (self.records.items.len < MAX_RECORDS) {
            self.records.append(self.allocator, record) catch {};
        } else {
            self.records.items[self.write_index] = record;
        }
        self.write_index = (self.write_index + 1) % MAX_RECORDS;

        // Update totals
        self.total_allocations += 1;
        self.current_bytes += size;
        if (self.current_bytes > self.peak_bytes) {
            self.peak_bytes = self.current_bytes;
        }

        // Update per-category stats
        const cat_idx = @intFromEnum(category);
        self.per_category_counts[cat_idx] += 1;
        self.per_category_bytes[cat_idx] += size;
    }

    /// Record a free event
    pub fn recordFree(self: *Profiler, size: usize, category: AllocationCategory) void {
        if (!self.enabled) return;

        self.total_frees += 1;
        if (self.current_bytes >= size) {
            self.current_bytes -= size;
        } else {
            self.current_bytes = 0;
        }

        // Update per-category stats (decrement bytes but keep counts for history)
        const cat_idx = @intFromEnum(category);
        if (self.per_category_bytes[cat_idx] >= size) {
            self.per_category_bytes[cat_idx] -= size;
        } else {
            self.per_category_bytes[cat_idx] = 0;
        }
    }

    /// Get a snapshot of current profiling data
    pub fn getSummary(self: *const Profiler) ProfilingSummary {
        var per_category: [AllocationCategory.count]CategoryStats = undefined;

        inline for (0..AllocationCategory.count) |i| {
            per_category[i] = CategoryStats{
                .category = @enumFromInt(i),
                .allocation_count = self.per_category_counts[i],
                .total_bytes = self.per_category_bytes[i],
            };
        }

        return ProfilingSummary{
            .total_allocations = self.total_allocations,
            .total_frees = self.total_frees,
            .current_bytes = self.current_bytes,
            .peak_bytes = self.peak_bytes,
            .per_category = per_category,
            .timestamp = getTimestamp(),
        };
    }

    /// Reset all profiling data
    pub fn reset(self: *Profiler) void {
        self.records.clearRetainingCapacity();
        self.total_allocations = 0;
        self.total_frees = 0;
        self.current_bytes = 0;
        self.peak_bytes = 0;
        self.per_category_counts = [_]usize{0} ** AllocationCategory.count;
        self.per_category_bytes = [_]usize{0} ** AllocationCategory.count;
        self.write_index = 0;
    }
};

/// Get current timestamp in nanoseconds
fn getTimestamp() u64 {
    return @intCast(std.time.nanoTimestamp());
}

// ============= Unit Tests =============

test "AllocationCategory enum values" {
    try std.testing.expectEqual(@as(u3, 0), @intFromEnum(AllocationCategory.Heap));
    try std.testing.expectEqual(@as(u3, 1), @intFromEnum(AllocationCategory.Large));
    try std.testing.expectEqual(@as(u3, 2), @intFromEnum(AllocationCategory.Arena));
    try std.testing.expectEqual(@as(u3, 3), @intFromEnum(AllocationCategory.Slab));
    try std.testing.expectEqual(@as(u3, 4), @intFromEnum(AllocationCategory.ThreadCache));
    try std.testing.expectEqual(@as(usize, 5), AllocationCategory.count);
}

test "AllocationRecord creation" {
    const record = AllocationRecord{
        .size = 1024,
        .timestamp = 12345,
        .category = .Heap,
    };
    try std.testing.expectEqual(@as(usize, 1024), record.size);
    try std.testing.expectEqual(@as(u64, 12345), record.timestamp);
    try std.testing.expectEqual(AllocationCategory.Heap, record.category);
}

test "CategoryStats avg_size computation" {
    const stats_zero = CategoryStats{
        .category = .Heap,
        .allocation_count = 0,
        .total_bytes = 0,
    };
    try std.testing.expectEqual(@as(usize, 0), stats_zero.avgSize());

    const stats_with_data = CategoryStats{
        .category = .Slab,
        .allocation_count = 10,
        .total_bytes = 1000,
    };
    try std.testing.expectEqual(@as(usize, 100), stats_with_data.avgSize());
}

test "Profiler init and deinit" {
    var profiler = Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    try std.testing.expectEqual(false, profiler.enabled);
    try std.testing.expectEqual(@as(usize, 0), profiler.total_allocations);
    try std.testing.expectEqual(@as(usize, 0), profiler.total_frees);
    try std.testing.expectEqual(@as(usize, 0), profiler.current_bytes);
    try std.testing.expectEqual(@as(usize, 0), profiler.peak_bytes);
}

test "Profiler enable and disable" {
    var profiler = Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    try std.testing.expectEqual(false, profiler.isEnabled());

    profiler.enable();
    try std.testing.expectEqual(true, profiler.isEnabled());

    profiler.disable();
    try std.testing.expectEqual(false, profiler.isEnabled());
}

test "Profiler record_alloc when disabled" {
    var profiler = Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    // Profiler is disabled by default
    profiler.recordAlloc(1024, .Heap);

    // Should not record anything when disabled
    try std.testing.expectEqual(@as(usize, 0), profiler.total_allocations);
    try std.testing.expectEqual(@as(usize, 0), profiler.current_bytes);
}

test "Profiler record_alloc when enabled" {
    var profiler = Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    profiler.enable();
    profiler.recordAlloc(1024, .Heap);
    profiler.recordAlloc(2048, .Slab);
    profiler.recordAlloc(512, .Heap);

    try std.testing.expectEqual(@as(usize, 3), profiler.total_allocations);
    try std.testing.expectEqual(@as(usize, 3584), profiler.current_bytes);
    try std.testing.expectEqual(@as(usize, 3584), profiler.peak_bytes);

    // Check per-category counts
    try std.testing.expectEqual(@as(usize, 2), profiler.per_category_counts[@intFromEnum(AllocationCategory.Heap)]);
    try std.testing.expectEqual(@as(usize, 1), profiler.per_category_counts[@intFromEnum(AllocationCategory.Slab)]);

    // Check per-category bytes
    try std.testing.expectEqual(@as(usize, 1536), profiler.per_category_bytes[@intFromEnum(AllocationCategory.Heap)]);
    try std.testing.expectEqual(@as(usize, 2048), profiler.per_category_bytes[@intFromEnum(AllocationCategory.Slab)]);
}

test "Profiler record_free updates totals" {
    var profiler = Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    profiler.enable();
    profiler.recordAlloc(1024, .Heap);
    profiler.recordAlloc(2048, .Heap);

    try std.testing.expectEqual(@as(usize, 3072), profiler.current_bytes);
    try std.testing.expectEqual(@as(usize, 3072), profiler.peak_bytes);

    profiler.recordFree(1024, .Heap);

    try std.testing.expectEqual(@as(usize, 1), profiler.total_frees);
    try std.testing.expectEqual(@as(usize, 2048), profiler.current_bytes);
    try std.testing.expectEqual(@as(usize, 3072), profiler.peak_bytes); // Peak unchanged
}

test "Profiler peak_bytes tracks maximum" {
    var profiler = Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    profiler.enable();

    profiler.recordAlloc(1000, .Heap);
    try std.testing.expectEqual(@as(usize, 1000), profiler.peak_bytes);

    profiler.recordAlloc(2000, .Heap);
    try std.testing.expectEqual(@as(usize, 3000), profiler.peak_bytes);

    profiler.recordFree(1000, .Heap);
    try std.testing.expectEqual(@as(usize, 3000), profiler.peak_bytes); // Peak unchanged

    profiler.recordFree(2000, .Heap);
    try std.testing.expectEqual(@as(usize, 0), profiler.current_bytes);
    try std.testing.expectEqual(@as(usize, 3000), profiler.peak_bytes); // Peak still at max
}

test "Profiler get_summary returns correct snapshot" {
    var profiler = Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    profiler.enable();
    profiler.recordAlloc(100, .Heap);
    profiler.recordAlloc(200, .Large);
    profiler.recordAlloc(300, .Arena);
    profiler.recordFree(100, .Heap);

    const summary = profiler.getSummary();

    try std.testing.expectEqual(@as(usize, 3), summary.total_allocations);
    try std.testing.expectEqual(@as(usize, 1), summary.total_frees);
    try std.testing.expectEqual(@as(usize, 500), summary.current_bytes);
    try std.testing.expectEqual(@as(usize, 600), summary.peak_bytes);

    // Check per-category in summary
    try std.testing.expectEqual(AllocationCategory.Heap, summary.per_category[0].category);
    try std.testing.expectEqual(@as(usize, 1), summary.per_category[0].allocation_count);

    try std.testing.expectEqual(AllocationCategory.Large, summary.per_category[1].category);
    try std.testing.expectEqual(@as(usize, 1), summary.per_category[1].allocation_count);
    try std.testing.expectEqual(@as(usize, 200), summary.per_category[1].total_bytes);
}

test "Profiler reset clears all data" {
    var profiler = Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    profiler.enable();
    profiler.recordAlloc(1024, .Heap);
    profiler.recordAlloc(2048, .Slab);
    profiler.recordFree(512, .Heap);

    // Verify data exists
    try std.testing.expect(profiler.total_allocations > 0);

    profiler.reset();

    try std.testing.expectEqual(@as(usize, 0), profiler.total_allocations);
    try std.testing.expectEqual(@as(usize, 0), profiler.total_frees);
    try std.testing.expectEqual(@as(usize, 0), profiler.current_bytes);
    try std.testing.expectEqual(@as(usize, 0), profiler.peak_bytes);
    try std.testing.expectEqual(@as(usize, 0), profiler.write_index);
    try std.testing.expectEqual(@as(usize, 0), profiler.records.items.len);

    for (profiler.per_category_counts) |count| {
        try std.testing.expectEqual(@as(usize, 0), count);
    }
    for (profiler.per_category_bytes) |bytes| {
        try std.testing.expectEqual(@as(usize, 0), bytes);
    }
}

test "Profiler circular buffer wraps at MAX_RECORDS" {
    var profiler = Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    profiler.enable();

    // Fill beyond MAX_RECORDS
    for (0..MAX_RECORDS + 100) |i| {
        profiler.recordAlloc(i + 1, .Heap);
    }

    // Buffer should be at max capacity
    try std.testing.expectEqual(MAX_RECORDS, profiler.records.items.len);

    // Total allocations should still be accurate
    try std.testing.expectEqual(MAX_RECORDS + 100, profiler.total_allocations);

    // write_index should have wrapped
    try std.testing.expectEqual(@as(usize, 100), profiler.write_index);
}

test "Profiler all categories tracked independently" {
    var profiler = Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    profiler.enable();

    profiler.recordAlloc(100, .Heap);
    profiler.recordAlloc(200, .Large);
    profiler.recordAlloc(300, .Arena);
    profiler.recordAlloc(400, .Slab);
    profiler.recordAlloc(500, .ThreadCache);

    try std.testing.expectEqual(@as(usize, 100), profiler.per_category_bytes[@intFromEnum(AllocationCategory.Heap)]);
    try std.testing.expectEqual(@as(usize, 200), profiler.per_category_bytes[@intFromEnum(AllocationCategory.Large)]);
    try std.testing.expectEqual(@as(usize, 300), profiler.per_category_bytes[@intFromEnum(AllocationCategory.Arena)]);
    try std.testing.expectEqual(@as(usize, 400), profiler.per_category_bytes[@intFromEnum(AllocationCategory.Slab)]);
    try std.testing.expectEqual(@as(usize, 500), profiler.per_category_bytes[@intFromEnum(AllocationCategory.ThreadCache)]);

    for (0..AllocationCategory.count) |i| {
        try std.testing.expectEqual(@as(usize, 1), profiler.per_category_counts[i]);
    }
}

test "Profiler record_free handles underflow gracefully" {
    var profiler = Profiler.init(std.testing.allocator);
    defer profiler.deinit();

    profiler.enable();
    profiler.recordAlloc(100, .Heap);

    // Free more than allocated - should not underflow
    profiler.recordFree(200, .Heap);

    try std.testing.expectEqual(@as(usize, 0), profiler.current_bytes);
    try std.testing.expectEqual(@as(usize, 0), profiler.per_category_bytes[@intFromEnum(AllocationCategory.Heap)]);
}
