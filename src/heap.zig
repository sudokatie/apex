// Heap Coordinator
//
// Global allocator state that coordinates all subsystems.
// Provides the public allocation interface with thread caching.

const std = @import("std");
const config = @import("config.zig");
const segment_mod = @import("segment.zig");
const page_mod = @import("page.zig");
const slab_mod = @import("slab.zig");
const large_mod = @import("large.zig");
const thread_cache_mod = @import("thread_cache.zig");
const platform = @import("platform.zig");
const stats_mod = @import("stats.zig");

// Global stats instance for recording all allocations
const global_stats = stats_mod.getGlobalStats();

const Atomic = std.atomic.Value;

// Build configuration
pub const BuildMode = enum {
    debug, // Full checks, stats, logging
    release, // Optimized, minimal checks
    safe, // Release + bounds checking
};

// Compile-time configuration
pub const build_mode: BuildMode = if (@import("builtin").mode == .Debug)
    .debug
else if (@import("builtin").mode == .ReleaseSafe)
    .safe
else
    .release;

pub const enable_stats = build_mode == .debug;
pub const enable_bounds_check = build_mode == .debug or build_mode == .safe;
pub const enable_logging = build_mode == .debug;
pub const enable_profiling = build_mode == .debug;

// Global heap state
pub const Heap = struct {
    // Segment cache (shared by slab and large allocators)
    segment_cache: segment_mod.SegmentCache,

    // Slab allocator for small allocations
    slab: slab_mod.SlabAllocator,

    // Large allocator for big allocations
    large: large_mod.LargeAllocator,

    // Thread cache registry
    thread_registry: *thread_cache_mod.ThreadCacheRegistry,

    // Allocation statistics
    total_allocated: Atomic(usize),
    total_freed: Atomic(usize),
    allocation_count: Atomic(usize),
    free_count: Atomic(usize),

    // Per-class statistics
    small_allocs: Atomic(usize),
    medium_allocs: Atomic(usize),
    large_allocs: Atomic(usize),
    huge_allocs: Atomic(usize),

    // Initialization flag
    initialized: bool,

    // NUMA node for this heap (0 = any)
    numa_node: u8,

    // Use huge pages when available
    use_huge_pages: bool,

    const Self = @This();

    pub fn init() Self {
        return .{
            .segment_cache = segment_mod.SegmentCache.init(),
            .slab = undefined, // Will be set in initAllocators
            .large = undefined, // Will be set in initAllocators
            .thread_registry = thread_cache_mod.getGlobalRegistry(),
            .total_allocated = Atomic(usize).init(0),
            .total_freed = Atomic(usize).init(0),
            .allocation_count = Atomic(usize).init(0),
            .free_count = Atomic(usize).init(0),
            .small_allocs = Atomic(usize).init(0),
            .medium_allocs = Atomic(usize).init(0),
            .large_allocs = Atomic(usize).init(0),
            .huge_allocs = Atomic(usize).init(0),
            .initialized = false,
            .numa_node = 0,
            .use_huge_pages = platform.hugePageAvailable(config.HUGE_PAGE_2MB),
        };
    }

    // Must be called after init to set up allocators with correct pointers
    pub fn initAllocators(self: *Self) void {
        self.slab = slab_mod.SlabAllocator.init(&self.segment_cache);
        self.large = large_mod.LargeAllocator.init(&self.segment_cache);
        self.initialized = true;

        // Register automatic thread exit handler for thread cache cleanup
        _ = thread_cache_mod.registerThreadExitHandler(&self.slab, &self.segment_cache);
    }

    // Main allocation entry point (uses thread cache for small allocations)
    pub fn alloc(self: *Self, size: usize) ?[*]u8 {
        if (size == 0) return null;

        const alloc_class = config.allocClass(size);
        const ptr = switch (alloc_class) {
            .small => self.allocSmall(size),
            .medium => self.allocMedium(size),
            .large => self.large.alloc(size),
            .huge => self.large.alloc(size),
        };

        if (ptr != null) {
            // Fast path: only update counters in debug/safe builds
            if (enable_stats) {
                _ = self.total_allocated.fetchAdd(size, .monotonic);
                _ = self.allocation_count.fetchAdd(1, .monotonic);
            }

            // Detailed stats only in debug/safe builds (adds overhead)
            if (enable_stats) {
                switch (alloc_class) {
                    .small => {
                        _ = self.small_allocs.fetchAdd(1, .monotonic);
                        const class_idx = config.sizeClassIndex(size) orelse 0;
                        global_stats.recordSlabAlloc(class_idx, size);
                    },
                    .medium => {
                        _ = self.medium_allocs.fetchAdd(1, .monotonic);
                        const actual = config.pagesForMedium(size) * config.PAGE_SIZE;
                        global_stats.recordLargeAlloc(size, actual);
                    },
                    .large => {
                        _ = self.large_allocs.fetchAdd(1, .monotonic);
                        const pages = (size + page_mod.Page.HEADER_SIZE + config.PAGE_SIZE - 1) / config.PAGE_SIZE;
                        const actual = pages * config.PAGE_SIZE;
                        global_stats.recordLargeAlloc(size, actual);
                    },
                    .huge => {
                        _ = self.huge_allocs.fetchAdd(1, .monotonic);
                        const actual = (size + large_mod.HugeHeader.HEADER_SIZE + std.heap.page_size_min - 1) & ~(std.heap.page_size_min - 1);
                        global_stats.recordHugeAlloc(size, actual);
                    },
                }
            }

            // Profiling hook (only in debug builds)
            if (enable_profiling and platform.isProfilingEnabled()) {
                platform.recordEvent(.{
                    .event_type = .alloc,
                    .ptr = ptr,
                    .size = size,
                    .timestamp_ns = platform.getTimestampNs(),
                    .thread_id = platform.getThreadId(),
                    .numa_node = self.numa_node,
                    .allocation_class = alloc_class,
                    .backtrace = if (enable_profiling) platform.captureBacktrace() else null,
                });
            }
        }

        return ptr;
    }

    // Small allocation path (uses thread cache)
    fn allocSmall(self: *Self, size: usize) ?[*]u8 {
        // Try thread cache first (lock-free fast path)
        if (thread_cache_mod.getThreadCache()) |tc| {
            return tc.alloc(size, &self.slab);
        }

        // Fallback to direct slab allocation
        return self.slab.alloc(size);
    }

    // Medium allocation path (2KB-32KB, uses pages)
    fn allocMedium(self: *Self, size: usize) ?[*]u8 {
        // Medium allocations use contiguous pages from segment
        return self.large.alloc(size);
    }

    // Allocation with alignment
    // Note: Always use freeAligned() to free memory allocated with this function
    pub fn allocAligned(self: *Self, size: usize, alignment: usize) ?[*]u8 {
        if (size == 0) return null;
        if (alignment == 0 or alignment > config.PAGE_SIZE) return null;

        // Check if alignment is power of 2
        if ((alignment & (alignment - 1)) != 0) return null;

        // Use at least 16-byte alignment for header storage
        const effective_alignment = @max(alignment, 16);

        // Over-allocate and align within the block
        // We need extra space: alignment - 1 for adjustment + sizeof(usize) for storing original ptr
        const header_size = @sizeOf(usize);
        const extra = effective_alignment - 1 + header_size;
        const total_size = size + extra;

        const raw_ptr = self.alloc(total_size) orelse return null;

        // Calculate aligned address (leave room for header)
        const raw_addr = @intFromPtr(raw_ptr);
        const aligned_addr = (raw_addr + header_size + effective_alignment - 1) & ~(effective_alignment - 1);
        const aligned_ptr: [*]u8 = @ptrFromInt(aligned_addr);

        // Store original pointer just before aligned address
        const header_ptr: *[*]u8 = @ptrFromInt(aligned_addr - header_size);
        header_ptr.* = raw_ptr;

        return aligned_ptr;
    }

    // Free aligned allocation
    pub fn freeAligned(self: *Self, ptr: ?[*]u8) void {
        const p = ptr orelse return;

        // Retrieve original pointer from header
        const header_ptr: *[*]u8 = @ptrFromInt(@intFromPtr(p) - @sizeOf(usize));
        const original_ptr = header_ptr.*;

        self.free(original_ptr);
    }

    // Free memory
    pub fn free(self: *Self, ptr: ?[*]u8) void {
        const p = ptr orelse return;

        // Determine allocation type from pointer
        const page = page_mod.pageFromPtr(@ptrCast(p));
        var size: usize = 0;
        var alloc_class: config.AllocClass = .small;

        switch (page.state) {
            .slab => {
                size = config.SIZE_CLASSES[page.size_class];
                alloc_class = .small;
                self.freeSmall(p, page);
                // Record slab free to global stats (only in debug/safe builds)
                if (enable_stats) {
                    global_stats.recordSlabFree(page.size_class);
                }
            },
            .large => {
                size = @as(usize, page.page_count) * config.PAGE_SIZE;
                alloc_class = if (size <= config.MEDIUM_THRESHOLD) .medium else .large;
                self.large.free(p);
                // Record large free to global stats (only in debug/safe builds)
                if (enable_stats) {
                    global_stats.recordLargeFree(size);
                }
            },
            else => {
                // Might be a huge allocation - check for valid header
                const potential_header = large_mod.HugeHeader.fromDataPtr(p);
                if (potential_header.isValid()) {
                    size = potential_header.usableSize();
                    alloc_class = .huge;
                    if (enable_stats) {
                        global_stats.recordHugeFree(potential_header.size);
                    }
                }
                self.large.free(p);
            },
        }

        if (enable_stats) {
            _ = self.total_freed.fetchAdd(size, .monotonic);
            _ = self.free_count.fetchAdd(1, .monotonic);
        }

        // Profiling hook (only when enabled)
        if (enable_profiling and platform.isProfilingEnabled()) {
            platform.recordEvent(.{
                .event_type = .free,
                .ptr = p,
                .size = size,
                .timestamp_ns = platform.getTimestampNs(),
                .thread_id = platform.getThreadId(),
                .numa_node = self.numa_node,
                .allocation_class = alloc_class,
                .backtrace = null,
            });
        }
    }

    // Small free path (uses thread cache)
    fn freeSmall(self: *Self, ptr: [*]u8, page: *page_mod.Page) void {
        // Try thread cache first
        if (thread_cache_mod.getThreadCache()) |tc| {
            tc.free(ptr, page, &self.slab);
            return;
        }

        // Fallback to direct slab free
        self.slab.free(ptr);
    }

    // Realloc
    pub fn realloc(self: *Self, ptr: ?[*]u8, old_size: usize, new_size: usize) ?[*]u8 {
        const p = ptr orelse return self.alloc(new_size);

        if (new_size == 0) {
            self.free(p);
            return null;
        }

        // Check if we can keep the same allocation
        const page = page_mod.pageFromPtr(@ptrCast(p));
        if (page.state == .slab) {
            const class_size = config.SIZE_CLASSES[page.size_class];
            if (new_size <= class_size) {
                // Fits in current size class
                return p;
            }
        }

        // Need to allocate new and copy
        const new_ptr = self.alloc(new_size) orelse return null;
        const copy_size = @min(old_size, new_size);
        @memcpy(new_ptr[0..copy_size], p[0..copy_size]);
        self.free(p);

        return new_ptr;
    }

    // Calloc (allocate zeroed memory)
    pub fn calloc(self: *Self, count: usize, size: usize) ?[*]u8 {
        const total = count *| size;
        if (total == 0) return null;

        const ptr = self.alloc(total) orelse return null;
        @memset(ptr[0..total], 0);
        return ptr;
    }

    // Get usable size for allocation
    pub fn usableSize(self: *Self, ptr: [*]u8) usize {
        _ = self;
        const page = page_mod.pageFromPtr(@ptrCast(ptr));

        return switch (page.state) {
            .slab => config.SIZE_CLASSES[page.size_class],
            .large => @as(usize, page.page_count) * config.PAGE_SIZE - page_mod.Page.HEADER_SIZE,
            else => large_mod.LargeAllocator.getAllocSize(ptr),
        };
    }

    // Thread exit cleanup - MUST be called when a thread exits
    pub fn onThreadExit(self: *Self) void {
        thread_cache_mod.onThreadExit(&self.slab, &self.segment_cache);
    }

    // Cleanup inactive thread caches (call periodically)
    pub fn cleanupInactiveThreads(self: *Self) void {
        self.thread_registry.cleanupInactive(&self.slab, &self.segment_cache);
    }

    // Statistics
    pub fn getTotalAllocated(self: *Self) usize {
        return self.total_allocated.load(.acquire);
    }

    pub fn getTotalFreed(self: *Self) usize {
        return self.total_freed.load(.acquire);
    }

    pub fn getAllocationCount(self: *Self) usize {
        return self.allocation_count.load(.acquire);
    }

    pub fn getFreeCount(self: *Self) usize {
        return self.free_count.load(.acquire);
    }

    pub fn getInUseBytes(self: *Self) usize {
        const allocated = self.total_allocated.load(.acquire);
        const freed = self.total_freed.load(.acquire);
        return if (allocated > freed) allocated - freed else 0;
    }

    pub fn getSmallAllocs(self: *Self) usize {
        return self.small_allocs.load(.acquire);
    }

    pub fn getMediumAllocs(self: *Self) usize {
        return self.medium_allocs.load(.acquire);
    }

    pub fn getLargeAllocs(self: *Self) usize {
        return self.large_allocs.load(.acquire);
    }

    pub fn getHugeAllocs(self: *Self) usize {
        return self.huge_allocs.load(.acquire);
    }

    // Get thread cache statistics
    pub fn getThreadCacheStats(self: *Self) thread_cache_mod.CacheStats {
        return self.thread_registry.getAggregateStats();
    }

    // Check if huge pages are being used
    pub fn isUsingHugePages(self: *Self) bool {
        return self.use_huge_pages;
    }
};

// Global heap instance
var global_heap: Heap = undefined;
var heap_initialized: bool = false;
var heap_init_lock: std.Thread.Mutex = .{};

// Initialize global heap (call once at startup)
pub fn init() void {
    heap_init_lock.lock();
    defer heap_init_lock.unlock();

    if (!heap_initialized) {
        global_heap = Heap.init();
        global_heap.initAllocators();
        heap_initialized = true;
    }
}

// Get global heap
pub fn getHeap() *Heap {
    if (!heap_initialized) {
        init();
    }
    return &global_heap;
}

// Convenience functions using global heap
pub fn alloc(size: usize) ?[*]u8 {
    return getHeap().alloc(size);
}

pub fn free(ptr: ?[*]u8) void {
    getHeap().free(ptr);
}

pub fn realloc(ptr: ?[*]u8, old_size: usize, new_size: usize) ?[*]u8 {
    return getHeap().realloc(ptr, old_size, new_size);
}

pub fn calloc(count: usize, size: usize) ?[*]u8 {
    return getHeap().calloc(count, size);
}

// Thread exit hook
pub fn onThreadExit() void {
    if (heap_initialized) {
        getHeap().onThreadExit();
    }
}

// ============= Tests =============

test "heap basic alloc/free" {
    var heap = Heap.init();
    heap.initAllocators();

    const p1 = heap.alloc(32) orelse return error.AllocFailed;
    p1[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), p1[0]);

    heap.free(p1);
}

test "heap various sizes" {
    var heap = Heap.init();
    heap.initAllocators();

    // Small (slab)
    const small = heap.alloc(64) orelse return error.AllocFailed;
    small[0] = 1;

    // Medium (pages)
    const medium = heap.alloc(4096) orelse return error.AllocFailed;
    medium[0] = 2;

    // Large (segment pages)
    const large_alloc = heap.alloc(128 * 1024) orelse return error.AllocFailed;
    large_alloc[0] = 3;

    // Huge (direct mmap)
    const huge = heap.alloc(4 * 1024 * 1024) orelse return error.AllocFailed;
    huge[0] = 4;

    heap.free(small);
    heap.free(medium);
    heap.free(large_alloc);
    heap.free(huge);
}

test "heap allocation class tracking" {
    var heap = Heap.init();
    heap.initAllocators();

    _ = heap.alloc(64); // small
    _ = heap.alloc(4096); // medium
    _ = heap.alloc(64 * 1024); // large

    try std.testing.expect(heap.getSmallAllocs() >= 1);
    try std.testing.expect(heap.getMediumAllocs() >= 1 or heap.getLargeAllocs() >= 1);
}

test "heap realloc grow" {
    var heap = Heap.init();
    heap.initAllocators();

    var p = heap.alloc(32) orelse return error.AllocFailed;
    p[0] = 99;

    p = heap.realloc(p, 32, 128) orelse return error.AllocFailed;
    try std.testing.expectEqual(@as(u8, 99), p[0]);

    p = heap.realloc(p, 128, 4096) orelse return error.AllocFailed;
    try std.testing.expectEqual(@as(u8, 99), p[0]);

    heap.free(p);
}

test "heap calloc" {
    var heap = Heap.init();
    heap.initAllocators();

    const p = heap.calloc(10, 100) orelse return error.AllocFailed;

    // Should be zeroed
    for (p[0..1000]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }

    heap.free(p);
}

test "heap statistics" {
    var heap = Heap.init();
    heap.initAllocators();

    const p1 = heap.alloc(64) orelse return error.AllocFailed;
    const p2 = heap.alloc(128) orelse return error.AllocFailed;

    try std.testing.expect(heap.getAllocationCount() >= 2);
    try std.testing.expect(heap.getTotalAllocated() >= 192);

    heap.free(p1);
    heap.free(p2);

    try std.testing.expect(heap.getFreeCount() >= 2);
}

test "heap null free is safe" {
    var heap = Heap.init();
    heap.initAllocators();
    heap.free(null); // Should not crash
}

test "heap aligned allocation" {
    var heap = Heap.init();
    heap.initAllocators();

    // Test various alignments
    const alignments = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 4096 };

    for (alignments) |alignment| {
        const ptr = heap.allocAligned(100, alignment) orelse continue;
        const addr = @intFromPtr(ptr);

        // Verify alignment
        try std.testing.expectEqual(@as(usize, 0), addr % alignment);

        heap.freeAligned(ptr);
    }
}

test "heap build mode" {
    // Should compile without error
    _ = build_mode;
    _ = enable_stats;
    _ = enable_bounds_check;
    _ = enable_logging;
}
