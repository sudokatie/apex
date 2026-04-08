// Work Stealing for Thread Caches
//
// Implements work-stealing between thread caches to balance load and reduce
// contention on the global heap. When a thread's cache is empty, it can steal
// blocks from other threads' caches before falling back to the heap.

const std = @import("std");
const config = @import("config.zig");
const thread_cache = @import("thread_cache.zig");

// Steal configuration
pub const StealConfig = struct {
    // Enable/disable work stealing
    enabled: bool = true,

    // Minimum blocks a victim must have before we steal
    min_victim_blocks: usize = 32,

    // How much to steal (fraction of victim's cache)
    steal_fraction: u8 = 2, // 1/2 = 50%

    // Maximum blocks to steal in one operation
    max_steal_count: usize = 64,

    // Number of victims to try before giving up
    max_steal_attempts: usize = 4,
};

// Global steal config (can be modified at runtime)
var global_steal_config: StealConfig = .{};

pub fn getStealConfig() *StealConfig {
    return &global_steal_config;
}

// Steal result
pub const StealResult = struct {
    blocks_stolen: usize,
    source_thread: ?usize,
};

// Attempt to steal blocks from other thread caches
// Returns number of blocks stolen and pushed onto `target_cache`
pub fn stealBlocks(
    target_cache: *thread_cache.SizeClassCache,
    class_idx: usize,
    target_thread_id: usize,
    registry: *thread_cache.ThreadCacheRegistry,
) StealResult {
    const cfg = &global_steal_config;

    if (!cfg.enabled) {
        return .{ .blocks_stolen = 0, .source_thread = null };
    }

    // Lock registry to iterate thread caches
    registry.lock.lock();
    defer registry.lock.unlock();

    var attempts: usize = 0;
    var victim = registry.head;

    while (victim != null and attempts < cfg.max_steal_attempts) : (attempts += 1) {
        const tc = victim.?;
        victim = tc.next;

        // Don't steal from self or inactive threads
        if (tc.thread_id == target_thread_id or !tc.active) {
            continue;
        }

        // Check if victim has enough blocks
        const victim_cache = &tc.caches[class_idx];
        if (victim_cache.count < cfg.min_victim_blocks) {
            continue;
        }

        // Calculate how many to steal
        const steal_count = @min(
            victim_cache.count / cfg.steal_fraction,
            cfg.max_steal_count,
        );

        if (steal_count == 0) {
            continue;
        }

        // Steal blocks (transfer from victim to target)
        var stolen: usize = 0;
        while (stolen < steal_count) : (stolen += 1) {
            const ptr = victim_cache.pop() orelse break;
            target_cache.push(ptr);
        }

        if (stolen > 0) {
            return .{
                .blocks_stolen = stolen,
                .source_thread = tc.thread_id,
            };
        }
    }

    return .{ .blocks_stolen = 0, .source_thread = null };
}

// Stats for work stealing
pub const StealStats = struct {
    total_steals: usize,
    blocks_stolen: usize,
    steal_attempts: usize,
    steal_failures: usize,

    pub fn init() StealStats {
        return .{
            .total_steals = 0,
            .blocks_stolen = 0,
            .steal_attempts = 0,
            .steal_failures = 0,
        };
    }
};

// Global steal stats
var global_steal_stats: StealStats = StealStats.init();

pub fn getStealStats() *StealStats {
    return &global_steal_stats;
}

pub fn recordSteal(blocks: usize) void {
    _ = @atomicRmw(usize, &global_steal_stats.total_steals, .Add, 1, .monotonic);
    _ = @atomicRmw(usize, &global_steal_stats.blocks_stolen, .Add, blocks, .monotonic);
}

pub fn recordStealAttempt(success: bool) void {
    _ = @atomicRmw(usize, &global_steal_stats.steal_attempts, .Add, 1, .monotonic);
    if (!success) {
        _ = @atomicRmw(usize, &global_steal_stats.steal_failures, .Add, 1, .monotonic);
    }
}

// Balance caches across threads (called periodically by background thread)
pub fn rebalanceCaches(registry: *thread_cache.ThreadCacheRegistry) void {
    const cfg = &global_steal_config;
    if (!cfg.enabled) return;

    registry.lock.lock();
    defer registry.lock.unlock();

    // Find threads with excess and deficit
    var high_count: usize = 0;
    var low_count: usize = 0;
    var high_thread: ?*thread_cache.ThreadCache = null;
    var low_thread: ?*thread_cache.ThreadCache = null;

    var tc = registry.head;
    while (tc) |cache| : (tc = cache.next) {
        if (!cache.active) continue;

        const total = cache.getTotalCached();
        if (total > high_count) {
            high_count = total;
            high_thread = cache;
        }
        if (low_thread == null or total < low_count) {
            low_count = total;
            low_thread = cache;
        }
    }

    // Only rebalance if significant imbalance exists
    if (high_thread != null and low_thread != null and high_thread != low_thread) {
        const diff = high_count - low_count;
        if (diff > config.THREAD_CACHE_MAX_BLOCKS / 2) {
            // Transfer from high to low for each size class
            for (0..config.NUM_SIZE_CLASSES) |i| {
                const from = &high_thread.?.caches[i];
                const to = &low_thread.?.caches[i];

                const transfer = from.count / 4; // Transfer 25%
                var transferred: usize = 0;
                while (transferred < transfer) : (transferred += 1) {
                    const ptr = from.pop() orelse break;
                    to.push(ptr);
                }
            }
        }
    }
}

// ============= Tests =============

test "steal config defaults" {
    const cfg = getStealConfig();
    try std.testing.expect(cfg.enabled);
    try std.testing.expectEqual(@as(usize, 32), cfg.min_victim_blocks);
}

test "steal stats initialization" {
    const stats = StealStats.init();
    try std.testing.expectEqual(@as(usize, 0), stats.total_steals);
    try std.testing.expectEqual(@as(usize, 0), stats.blocks_stolen);
}

test "record steal" {
    // Reset stats
    global_steal_stats = StealStats.init();

    recordSteal(10);
    try std.testing.expectEqual(@as(usize, 1), global_steal_stats.total_steals);
    try std.testing.expectEqual(@as(usize, 10), global_steal_stats.blocks_stolen);

    recordSteal(5);
    try std.testing.expectEqual(@as(usize, 2), global_steal_stats.total_steals);
    try std.testing.expectEqual(@as(usize, 15), global_steal_stats.blocks_stolen);
}

test "record steal attempt" {
    // Reset stats
    global_steal_stats = StealStats.init();

    recordStealAttempt(true);
    try std.testing.expectEqual(@as(usize, 1), global_steal_stats.steal_attempts);
    try std.testing.expectEqual(@as(usize, 0), global_steal_stats.steal_failures);

    recordStealAttempt(false);
    try std.testing.expectEqual(@as(usize, 2), global_steal_stats.steal_attempts);
    try std.testing.expectEqual(@as(usize, 1), global_steal_stats.steal_failures);
}

test "disable stealing" {
    var cfg = StealConfig{};
    cfg.enabled = false;
    try std.testing.expect(!cfg.enabled);
}
