// Apex Benchmarks
//
// Performance measurement for the allocator.
// Measures throughput, latency, and fragmentation.

const std = @import("std");
const apex = @import("apex");

const config = apex.config;
const heap_mod = apex.heap;
const arena_mod = apex.arena;

// Benchmark result
const BenchResult = struct {
    name: []const u8,
    ops: u64,
    duration_ns: u64,
    ops_per_sec: u64,
    ns_per_op: u64,
};

// Run a benchmark
fn bench(name: []const u8, iterations: u64, func: *const fn () void) BenchResult {
    // Warmup
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        func();
    }

    // Timed run
    const start = std.time.nanoTimestamp();

    i = 0;
    while (i < iterations) : (i += 1) {
        func();
    }

    const end = std.time.nanoTimestamp();
    const duration_ns: u64 = @intCast(end - start);

    const ops_per_sec = if (duration_ns > 0)
        iterations * 1_000_000_000 / duration_ns
    else
        0;

    const ns_per_op = if (iterations > 0)
        duration_ns / iterations
    else
        0;

    return .{
        .name = name,
        .ops = iterations,
        .duration_ns = duration_ns,
        .ops_per_sec = ops_per_sec,
        .ns_per_op = ns_per_op,
    };
}

// Print benchmark result
fn printResult(result: BenchResult) void {
    std.debug.print("{s:<30} {d:>12} ops/sec  {d:>6} ns/op\n", .{
        result.name,
        result.ops_per_sec,
        result.ns_per_op,
    });
}

// Global heap for benchmarks
var global_heap: heap_mod.Heap = undefined;
var heap_initialized: bool = false;

fn getHeap() *heap_mod.Heap {
    if (!heap_initialized) {
        global_heap = heap_mod.Heap.init();
        global_heap.initAllocators();
        heap_initialized = true;
    }
    return &global_heap;
}

// Benchmark: small allocation (32 bytes)
fn benchSmallAlloc() void {
    const heap = getHeap();
    const ptr = heap.alloc(32) orelse return;
    heap.free(ptr);
}

// Benchmark: medium allocation (256 bytes)
fn benchMediumAlloc() void {
    const heap = getHeap();
    const ptr = heap.alloc(256) orelse return;
    heap.free(ptr);
}

// Benchmark: large allocation (4KB)
fn benchLargeAlloc() void {
    const heap = getHeap();
    const ptr = heap.alloc(4096) orelse return;
    heap.free(ptr);
}

// Benchmark: huge allocation (1MB)
fn benchHugeAlloc() void {
    const heap = getHeap();
    const ptr = heap.alloc(1024 * 1024) orelse return;
    heap.free(ptr);
}

// Benchmark: arena allocation
var bench_arena: ?*arena_mod.Arena = null;

fn getBenchArena() *arena_mod.Arena {
    if (bench_arena) |a| {
        return a;
    }
    const ptr = std.heap.page_allocator.create(arena_mod.Arena) catch unreachable;
    ptr.* = arena_mod.Arena.init();
    bench_arena = ptr;
    return ptr;
}

fn benchArenaAlloc() void {
    const arena = getBenchArena();
    _ = arena.alloc(64) orelse return;
}

fn benchArenaReset() void {
    const arena = getBenchArena();
    arena.reset();
}

// Benchmark: batch allocations
fn benchBatch10() void {
    const heap = getHeap();
    var ptrs: [10][*]u8 = undefined;
    var count: usize = 0;

    for (&ptrs) |*p| {
        if (heap.alloc(64)) |ptr| {
            p.* = ptr;
            count += 1;
        }
    }

    for (ptrs[0..count]) |p| {
        heap.free(p);
    }
}

fn benchBatch100() void {
    const heap = getHeap();
    var ptrs: [100][*]u8 = undefined;
    var count: usize = 0;

    for (&ptrs) |*p| {
        if (heap.alloc(64)) |ptr| {
            p.* = ptr;
            count += 1;
        }
    }

    for (ptrs[0..count]) |p| {
        heap.free(p);
    }
}

// Fragmentation measurement
fn measureFragmentation() void {
    const heap = getHeap();

    std.debug.print("\n=== Fragmentation Test ===\n", .{});

    // Allocate many blocks of different sizes
    var ptrs: [1000]?[*]u8 = [_]?[*]u8{null} ** 1000;
    var rng = std.Random.DefaultPrng.init(12345);

    // Allocate
    for (&ptrs) |*p| {
        const size = rng.random().intRangeAtMost(usize, 16, 512);
        p.* = heap.alloc(size);
    }

    // Free half (every other)
    var freed: usize = 0;
    for (&ptrs, 0..) |*p, i| {
        if (i % 2 == 0) {
            if (p.*) |ptr| {
                heap.free(ptr);
                p.* = null;
                freed += 1;
            }
        }
    }

    // Try to allocate again
    var reused: usize = 0;
    for (&ptrs) |*p| {
        if (p.* == null) {
            const size = rng.random().intRangeAtMost(usize, 16, 512);
            if (heap.alloc(size)) |ptr| {
                p.* = ptr;
                reused += 1;
            }
        }
    }

    std.debug.print("Freed: {d}, Reused slots: {d}\n", .{ freed, reused });

    // Cleanup
    for (&ptrs) |*p| {
        if (p.*) |ptr| {
            heap.free(ptr);
            p.* = null;
        }
    }
}

pub fn main() !void {
    std.debug.print("=== Apex Allocator Benchmarks ===\n\n", .{});
    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Page size: {d} KB\n", .{config.PAGE_SIZE / 1024});
    std.debug.print("  Segment size: {d} MB\n", .{config.SEGMENT_SIZE / (1024 * 1024)});
    std.debug.print("  Size classes: {d}\n\n", .{config.SIZE_CLASSES.len});

    std.debug.print("Benchmarks (higher ops/sec = better):\n", .{});
    std.debug.print("{s:-<60}\n", .{""});

    // Run benchmarks
    printResult(bench("small alloc (32B)", 1_000_000, benchSmallAlloc));
    printResult(bench("medium alloc (256B)", 1_000_000, benchMediumAlloc));
    printResult(bench("large alloc (4KB)", 100_000, benchLargeAlloc));
    printResult(bench("huge alloc (1MB)", 1_000, benchHugeAlloc));

    std.debug.print("\n", .{});
    printResult(bench("arena alloc (64B)", 1_000_000, benchArenaAlloc));
    benchArenaReset();

    std.debug.print("\n", .{});
    printResult(bench("batch 10 allocs", 100_000, benchBatch10));
    printResult(bench("batch 100 allocs", 10_000, benchBatch100));

    // Fragmentation test
    measureFragmentation();

    std.debug.print("\nBenchmarks complete.\n", .{});
}
