// Stress Tests
//
// Comprehensive testing for allocator correctness and performance.

const std = @import("std");
const config = @import("config.zig");
const segment_mod = @import("segment.zig");
const slab_mod = @import("slab.zig");
const large_mod = @import("large.zig");
const heap_mod = @import("heap.zig");
const arena_mod = @import("arena.zig");

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
