// Stress Tests
//
// Comprehensive testing for allocator correctness and performance.
// Includes multi-threaded torture tests.

const std = @import("std");
const config = @import("config.zig");
const segment_mod = @import("segment.zig");
const slab_mod = @import("slab.zig");
const large_mod = @import("large.zig");
const heap_mod = @import("heap.zig");
const arena_mod = @import("arena.zig");
const thread_cache_mod = @import("thread_cache.zig");

// Test utilities
fn randomSize(rng: *std.Random.DefaultPrng, max: usize) usize {
    return rng.random().intRangeAtMost(usize, 1, max);
}

// Stress test: many small allocations
test "stress: many small allocations" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    var ptrs: [1000][*]u8 = undefined;
    var valid: [1000]bool = [_]bool{false} ** 1000;

    // Allocate all
    for (&ptrs, 0..) |*p, i| {
        const ptr = heap.alloc(64) orelse continue;
        ptr[0] = @intCast(i & 0xFF);
        p.* = ptr;
        valid[i] = true;
    }

    // Verify and free
    for (ptrs, 0..) |p, i| {
        if (!valid[i]) continue;
        try std.testing.expectEqual(@as(u8, @intCast(i & 0xFF)), p[0]);
        heap.free(p);
    }
}

// Stress test: mixed sizes
test "stress: mixed allocation sizes" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    var rng = std.Random.DefaultPrng.init(12345);
    var ptrs: [500]?[*]u8 = [_]?[*]u8{null} ** 500;
    var sizes: [500]usize = [_]usize{0} ** 500;

    // Random allocations
    for (&ptrs, &sizes) |*p, *s| {
        const size = randomSize(&rng, 4096);
        const ptr = heap.alloc(size) orelse continue;
        ptr[0] = 0xAB;
        if (size > 1) ptr[size - 1] = 0xCD;
        p.* = ptr;
        s.* = size;
    }

    // Verify and free
    for (ptrs, sizes) |p_opt, size| {
        const p = p_opt orelse continue;
        try std.testing.expectEqual(@as(u8, 0xAB), p[0]);
        if (size > 1) {
            try std.testing.expectEqual(@as(u8, 0xCD), p[size - 1]);
        }
        heap.free(p);
    }
}

// Stress test: alloc/free churn
test "stress: alloc free churn" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    var rng = std.Random.DefaultPrng.init(54321);
    var ptrs: [100]?[*]u8 = [_]?[*]u8{null} ** 100;

    // Churn: randomly alloc or free
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const idx = rng.random().intRangeAtMost(usize, 0, 99);

        if (ptrs[idx]) |ptr| {
            heap.free(ptr);
            ptrs[idx] = null;
        } else {
            const size = randomSize(&rng, 256);
            ptrs[idx] = heap.alloc(size);
        }
    }

    // Cleanup
    for (&ptrs) |*p| {
        if (p.*) |ptr| {
            heap.free(ptr);
            p.* = null;
        }
    }
}

// Stress test: large allocations
test "stress: large allocations" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    var ptrs: [20]?[*]u8 = [_]?[*]u8{null} ** 20;

    // Allocate large blocks
    for (&ptrs, 0..) |*p, i| {
        const size = (i + 1) * 32 * 1024; // 32KB to 640KB
        const ptr = heap.alloc(size) orelse continue;
        ptr[0] = 0x11;
        ptr[size - 1] = 0x22;
        p.* = ptr;
    }

    // Free all
    for (&ptrs) |*p| {
        if (p.*) |ptr| {
            heap.free(ptr);
            p.* = null;
        }
    }
}

// Stress test: huge allocations
test "stress: huge allocations" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    // Allocate a single huge block (simpler test)
    const size = 4 * 1024 * 1024; // 4MB
    const ptr = heap.alloc(size) orelse return error.AllocFailed;

    // Write to start and end
    ptr[0] = 0xAA;
    ptr[size - 1] = 0xBB;

    try std.testing.expectEqual(@as(u8, 0xAA), ptr[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), ptr[size - 1]);

    heap.free(ptr);
}

// Stress test: realloc patterns
test "stress: realloc patterns" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    // Start small, grow large
    var p = heap.alloc(16) orelse return error.AllocFailed;
    p[0] = 0x11;

    var size: usize = 16;
    while (size < 1024 * 1024) {
        const new_size = size * 2;
        const new_p = heap.realloc(p, size, new_size) orelse return error.AllocFailed;
        try std.testing.expectEqual(@as(u8, 0x11), new_p[0]); // Data preserved
        p = new_p;
        size = new_size;
    }

    heap.free(p);
}

// Stress test: arena performance
test "stress: arena allocations" {
    var arena = arena_mod.Arena.init();
    defer arena.deinit();

    // Rapid-fire allocations
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const ptr = arena.alloc(32) orelse return error.AllocFailed;
        ptr[0] = @intCast(i & 0xFF);
    }

    try std.testing.expect(arena.getTotalAllocated() >= 320000);

    // Reset and reuse
    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.getTotalAllocated());

    // Allocate again
    i = 0;
    while (i < 5000) : (i += 1) {
        _ = arena.alloc(64) orelse return error.AllocFailed;
    }
}

// Stress test: size class boundaries
test "stress: size class boundaries" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    // Test allocations at size class boundaries
    for (config.SIZE_CLASSES) |size| {
        // Exact size
        const p1 = heap.alloc(size) orelse continue;
        p1[0] = 0x55;

        // One byte less
        if (size > 1) {
            const p2 = heap.alloc(size - 1) orelse continue;
            p2[0] = 0x66;
            heap.free(p2);
        }

        // One byte more
        const p3 = heap.alloc(size + 1);
        if (p3) |ptr| {
            ptr[0] = 0x77;
            heap.free(ptr);
        }

        heap.free(p1);
    }
}

// Stress test: zero-size and edge cases
test "stress: edge cases" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    // Zero size should return null
    const p0 = heap.alloc(0);
    try std.testing.expect(p0 == null);

    // Free null should be safe
    heap.free(null);

    // Very small allocation
    const p1 = heap.alloc(1) orelse return error.AllocFailed;
    p1[0] = 1;
    heap.free(p1);

    // Calloc
    const p2 = heap.calloc(100, 4) orelse return error.AllocFailed;
    for (p2[0..400]) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
    heap.free(p2);
}

// Stress test: alignment correctness
test "stress: alignment correctness" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    const alignments = [_]usize{ 1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };
    const sizes = [_]usize{ 1, 7, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095 };

    for (alignments) |alignment| {
        for (sizes) |size| {
            const ptr = heap.allocAligned(size, alignment) orelse continue;
            const addr = @intFromPtr(ptr);

            // Verify alignment
            try std.testing.expectEqual(@as(usize, 0), addr % alignment);

            // Write to allocation
            ptr[0] = 0xAA;
            if (size > 1) ptr[size - 1] = 0xBB;

            heap.freeAligned(ptr);
        }
    }
}

// ========== Multi-threaded Tests ==========

const ThreadTestContext = struct {
    heap: *heap_mod.Heap,
    thread_id: usize,
    iterations: usize,
    errors: std.atomic.Value(usize),
    allocations: std.atomic.Value(usize),
};

fn threadAllocWorker(ctx: *ThreadTestContext) void {
    var rng = std.Random.DefaultPrng.init(@as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())) ^ ctx.thread_id)));
    var ptrs: [50]?[*]u8 = [_]?[*]u8{null} ** 50;

    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        const idx = rng.random().intRangeAtMost(usize, 0, 49);
        const size = rng.random().intRangeAtMost(usize, 8, 2048);

        if (ptrs[idx]) |ptr| {
            // Free existing
            ctx.heap.free(ptr);
            ptrs[idx] = null;
        } else {
            // Allocate new
            if (ctx.heap.alloc(size)) |ptr| {
                // Write pattern to verify later
                ptr[0] = @truncate(ctx.thread_id);
                if (size > 1) ptr[size - 1] = @truncate(ctx.thread_id ^ 0xFF);
                ptrs[idx] = ptr;
                _ = ctx.allocations.fetchAdd(1, .monotonic);
            } else {
                _ = ctx.errors.fetchAdd(1, .monotonic);
            }
        }
    }

    // Cleanup
    for (&ptrs) |*p| {
        if (p.*) |ptr| {
            ctx.heap.free(ptr);
            p.* = null;
        }
    }

    // Cleanup thread cache
    ctx.heap.onThreadExit();
}

test "stress: multi-threaded alloc/free" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    const NUM_THREADS = 4;
    const ITERATIONS = 1000;

    var contexts: [NUM_THREADS]ThreadTestContext = undefined;
    var threads: [NUM_THREADS]std.Thread = undefined;

    // Start threads
    for (&contexts, &threads, 0..) |*ctx, *thread, i| {
        ctx.* = .{
            .heap = &heap,
            .thread_id = i,
            .iterations = ITERATIONS,
            .errors = std.atomic.Value(usize).init(0),
            .allocations = std.atomic.Value(usize).init(0),
        };
        thread.* = std.Thread.spawn(.{}, threadAllocWorker, .{ctx}) catch return error.ThreadSpawnFailed;
    }

    // Wait for completion
    for (&threads) |*thread| {
        thread.join();
    }

    // Check results
    var total_errors: usize = 0;
    var total_allocs: usize = 0;
    for (contexts) |ctx| {
        total_errors += ctx.errors.load(.acquire);
        total_allocs += ctx.allocations.load(.acquire);
    }

    try std.testing.expectEqual(@as(usize, 0), total_errors);
    try std.testing.expect(total_allocs > 0);
}

fn threadCrossThreadFreeWorker(ctx: *ThreadTestContext, shared_ptrs: *[100]std.atomic.Value(?*anyopaque)) void {
    var rng = std.Random.DefaultPrng.init(@as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())) ^ ctx.thread_id)));

    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        const idx = rng.random().intRangeAtMost(usize, 0, 99);

        // Try to take a pointer from shared array
        const ptr_opt = shared_ptrs[idx].swap(null, .acquire);
        if (ptr_opt) |ptr| {
            // Free pointer allocated by another thread (cross-thread free)
            ctx.heap.free(@ptrCast(@alignCast(ptr)));
            _ = ctx.allocations.fetchAdd(1, .monotonic);
        } else {
            // Allocate new and put in shared array
            if (ctx.heap.alloc(64)) |new_ptr| {
                new_ptr[0] = @truncate(ctx.thread_id);
                const old = shared_ptrs[idx].swap(@ptrCast(new_ptr), .release);
                if (old) |old_ptr| {
                    // Someone else put one there first, free it
                    ctx.heap.free(@ptrCast(@alignCast(old_ptr)));
                }
            }
        }
    }

    ctx.heap.onThreadExit();
}

test "stress: cross-thread free" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    const NUM_THREADS = 4;
    const ITERATIONS = 500;

    var shared_ptrs: [100]std.atomic.Value(?*anyopaque) = undefined;
    for (&shared_ptrs) |*p| {
        p.* = std.atomic.Value(?*anyopaque).init(null);
    }

    var contexts: [NUM_THREADS]ThreadTestContext = undefined;
    var threads: [NUM_THREADS]std.Thread = undefined;

    // Start threads
    for (&contexts, &threads, 0..) |*ctx, *thread, i| {
        ctx.* = .{
            .heap = &heap,
            .thread_id = i,
            .iterations = ITERATIONS,
            .errors = std.atomic.Value(usize).init(0),
            .allocations = std.atomic.Value(usize).init(0),
        };
        thread.* = std.Thread.spawn(.{}, threadCrossThreadFreeWorker, .{ ctx, &shared_ptrs }) catch return error.ThreadSpawnFailed;
    }

    // Wait for completion
    for (&threads) |*thread| {
        thread.join();
    }

    // Cleanup any remaining pointers
    for (&shared_ptrs) |*p| {
        if (p.load(.acquire)) |ptr| {
            heap.free(@ptrCast(@alignCast(ptr)));
        }
    }

    // Verify no errors
    for (contexts) |ctx| {
        try std.testing.expectEqual(@as(usize, 0), ctx.errors.load(.acquire));
    }
}

const PtrSizeEntry = struct { ptr: [*]u8, size: usize };

fn threadMixedSizeWorker(ctx: *ThreadTestContext) void {
    var rng = std.Random.DefaultPrng.init(@as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())) ^ ctx.thread_id)));
    var ptrs: [20]?PtrSizeEntry = [_]?PtrSizeEntry{null} ** 20;

    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        const idx = rng.random().intRangeAtMost(usize, 0, 19);

        if (ptrs[idx]) |entry| {
            // Verify data
            if (entry.ptr[0] != @as(u8, @truncate(ctx.thread_id))) {
                _ = ctx.errors.fetchAdd(1, .monotonic);
            }
            ctx.heap.free(entry.ptr);
            ptrs[idx] = null;
        } else {
            // Allocate - mix of small, medium, large
            const size_type = rng.random().intRangeAtMost(usize, 0, 2);
            const size: usize = switch (size_type) {
                0 => rng.random().intRangeAtMost(usize, 8, 256), // Small
                1 => rng.random().intRangeAtMost(usize, 2048, 32768), // Medium
                else => rng.random().intRangeAtMost(usize, 65536, 262144), // Large
            };

            if (ctx.heap.alloc(size)) |ptr| {
                ptr[0] = @truncate(ctx.thread_id);
                ptrs[idx] = .{ .ptr = ptr, .size = size };
                _ = ctx.allocations.fetchAdd(1, .monotonic);
            }
        }
    }

    // Cleanup
    for (&ptrs) |*p| {
        if (p.*) |entry| {
            ctx.heap.free(entry.ptr);
            p.* = null;
        }
    }

    ctx.heap.onThreadExit();
}

test "stress: multi-threaded mixed sizes" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    const NUM_THREADS = 4;
    const ITERATIONS = 200;

    var contexts: [NUM_THREADS]ThreadTestContext = undefined;
    var threads: [NUM_THREADS]std.Thread = undefined;

    for (&contexts, &threads, 0..) |*ctx, *thread, i| {
        ctx.* = .{
            .heap = &heap,
            .thread_id = i,
            .iterations = ITERATIONS,
            .errors = std.atomic.Value(usize).init(0),
            .allocations = std.atomic.Value(usize).init(0),
        };
        thread.* = std.Thread.spawn(.{}, threadMixedSizeWorker, .{ctx}) catch return error.ThreadSpawnFailed;
    }

    for (&threads) |*thread| {
        thread.join();
    }

    // Verify no errors
    var total_errors: usize = 0;
    for (contexts) |ctx| {
        total_errors += ctx.errors.load(.acquire);
    }
    try std.testing.expectEqual(@as(usize, 0), total_errors);
}

fn threadTortureWorker(ctx: *ThreadTestContext) void {
    var rng = std.Random.DefaultPrng.init(@as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())) ^ ctx.thread_id)));

    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        const size = rng.random().intRangeAtMost(usize, 1, 4096);

        // Rapid alloc/free cycle
        if (ctx.heap.alloc(size)) |ptr| {
            // Write to verify allocation is valid
            ptr[0] = 0xDE;
            if (size > 1) ptr[size - 1] = 0xAD;

            // Immediate free
            ctx.heap.free(ptr);
            _ = ctx.allocations.fetchAdd(1, .monotonic);
        }
    }

    ctx.heap.onThreadExit();
}

test "stress: multi-threaded torture" {
    var heap = heap_mod.Heap.init();
    heap.initAllocators();

    const NUM_THREADS = 8;
    const ITERATIONS = 2000;

    var contexts: [NUM_THREADS]ThreadTestContext = undefined;
    var threads: [NUM_THREADS]std.Thread = undefined;

    for (&contexts, &threads, 0..) |*ctx, *thread, i| {
        ctx.* = .{
            .heap = &heap,
            .thread_id = i,
            .iterations = ITERATIONS,
            .errors = std.atomic.Value(usize).init(0),
            .allocations = std.atomic.Value(usize).init(0),
        };
        thread.* = std.Thread.spawn(.{}, threadTortureWorker, .{ctx}) catch return error.ThreadSpawnFailed;
    }

    for (&threads) |*thread| {
        thread.join();
    }

    // Count total allocations
    var total_allocs: usize = 0;
    for (contexts) |ctx| {
        total_allocs += ctx.allocations.load(.acquire);
    }

    // Should have completed many allocations
    try std.testing.expect(total_allocs > NUM_THREADS * ITERATIONS / 2);
}

// Thread cache specific tests
test "stress: thread cache fill and flush" {
    var segment_cache = segment_mod.SegmentCache.init();
    var slab = slab_mod.SlabAllocator.init(&segment_cache);

    // Use a local ThreadCache instead of registry to avoid comptime init issues
    var tc = thread_cache_mod.ThreadCache.init(1);

    // Fill the cache
    var ptrs: [config.THREAD_CACHE_MAX_BLOCKS + 100][*]u8 = undefined;
    var count: usize = 0;

    for (&ptrs) |*p| {
        if (tc.alloc(64, &slab)) |ptr| {
            p.* = ptr;
            count += 1;
        } else break;
    }

    try std.testing.expect(count > 0);

    // Free all back through cache
    const page = @import("page.zig").pageFromPtr(@ptrCast(ptrs[0]));
    for (ptrs[0..count]) |ptr| {
        tc.free(ptr, page, &slab);
    }

    // Flush
    tc.flushAll(&slab, &segment_cache);
    try std.testing.expectEqual(@as(usize, 0), tc.getTotalCached());
}
