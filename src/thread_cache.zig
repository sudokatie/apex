// Thread Cache
//
// Per-thread free lists and page pool for fast allocation without contention.
// Each thread has its own cache of blocks for each size class, plus a local page pool.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const segment_mod = @import("segment.zig");
const page_mod = @import("page.zig");
const slab_mod = @import("slab.zig");
const platform = @import("platform.zig");
const stats_mod = @import("stats.zig");

// Global stats for cache hit/miss tracking
const global_stats = stats_mod.getGlobalStats();

// Free list node (stored in the free block itself)
const FreeNode = struct {
    next: ?*FreeNode,
};

// Per-size-class cache
pub const SizeClassCache = struct {
    // Free list head
    head: ?*FreeNode,

    // Number of cached blocks
    count: usize,

    const Self = @This();

    pub fn init() Self {
        return .{
            .head = null,
            .count = 0,
        };
    }

    // Push a block onto the cache
    pub fn push(self: *Self, ptr: [*]u8) void {
        const node: *FreeNode = @ptrCast(@alignCast(ptr));
        node.next = self.head;
        self.head = node;
        self.count += 1;
    }

    // Pop a block from the cache
    pub fn pop(self: *Self) ?[*]u8 {
        const node = self.head orelse return null;
        self.head = node.next;
        self.count -= 1;
        return @ptrCast(node);
    }

    // Pop multiple blocks (for flushing)
    pub fn popN(self: *Self, n: usize) usize {
        var popped: usize = 0;
        while (popped < n and self.head != null) {
            _ = self.pop();
            popped += 1;
        }
        return popped;
    }

    // Check if cache is empty
    pub fn isEmpty(self: *Self) bool {
        return self.head == null;
    }

    // Check if cache is full
    pub fn isFull(self: *Self) bool {
        return self.count >= config.THREAD_CACHE_MAX_BLOCKS;
    }
};

// Per-thread page pool (per spec 2.3)
pub const PagePool = struct {
    // Cached pages (up to THREAD_CACHE_MAX_PAGES)
    pages: [config.THREAD_CACHE_MAX_PAGES]?*page_mod.Page,
    count: usize,

    const Self = @This();

    pub fn init() Self {
        return .{
            .pages = [_]?*page_mod.Page{null} ** config.THREAD_CACHE_MAX_PAGES,
            .count = 0,
        };
    }

    // Get a page from the pool
    pub fn get(self: *Self) ?*page_mod.Page {
        if (self.count == 0) return null;
        self.count -= 1;
        const page = self.pages[self.count];
        self.pages[self.count] = null;
        return page;
    }

    // Return a page to the pool
    pub fn put(self: *Self, page: *page_mod.Page) bool {
        if (self.count >= config.THREAD_CACHE_MAX_PAGES) return false;
        self.pages[self.count] = page;
        self.count += 1;
        return true;
    }

    // Flush all pages back to segment cache
    pub fn flushAll(self: *Self, segment_cache: *segment_mod.SegmentCache) void {
        for (&self.pages) |*p| {
            if (p.*) |page| {
                // Return page to its segment
                const seg = page.segment;
                seg.freePage(page.index);
                // If segment is empty, return to cache
                if (seg.isEmpty()) {
                    segment_cache.release(seg);
                }
                p.* = null;
            }
        }
        self.count = 0;
    }
};

// Per-thread cache
pub const ThreadCache = struct {
    // Caches for each size class
    caches: [config.NUM_SIZE_CLASSES]SizeClassCache,

    // Local page pool (per spec 2.3)
    page_pool: PagePool,

    // Thread ID that owns this cache
    thread_id: usize,

    // NUMA node for this thread
    numa_node: u8,

    // Next cache in global registry list
    next: ?*ThreadCache,

    // Previous cache in global registry list
    prev: ?*ThreadCache,

    // Flag indicating this cache is active
    active: bool,

    // Statistics
    alloc_count: usize,
    free_count: usize,
    cache_hits: usize,
    cache_misses: usize,

    const Self = @This();

    pub fn init(tid: usize) Self {
        var caches: [config.NUM_SIZE_CLASSES]SizeClassCache = undefined;
        for (&caches) |*c| {
            c.* = SizeClassCache.init();
        }
        return .{
            .caches = caches,
            .page_pool = PagePool.init(),
            .thread_id = tid,
            .numa_node = platform.numaCurrentNode(),
            .next = null,
            .prev = null,
            .active = true,
            .alloc_count = 0,
            .free_count = 0,
            .cache_hits = 0,
            .cache_misses = 0,
        };
    }

    // Allocate from thread cache
    pub fn alloc(self: *Self, size: usize, slab_allocator: *slab_mod.SlabAllocator) ?[*]u8 {
        const class_idx = config.sizeClassIndex(size) orelse return null;

        // Try thread-local cache first (lock-free fast path!)
        if (self.caches[class_idx].pop()) |ptr| {
            // Stats only in debug mode (adds overhead in release)
            if (@import("builtin").mode == .Debug) {
                self.alloc_count += 1;
                self.cache_hits += 1;
                global_stats.recordCacheHit();
            }
            return ptr;
        }

        // Stats for cache miss
        if (@import("builtin").mode == .Debug) {
            self.alloc_count += 1;
            self.cache_misses += 1;
            global_stats.recordCacheMiss();
        }

        // Cache miss - fill from slab allocator
        self.fillCache(class_idx, slab_allocator);

        return self.caches[class_idx].pop();
    }

    // Allocate a page from thread cache
    pub fn allocPage(self: *Self, segment_cache: *segment_mod.SegmentCache) ?*page_mod.Page {
        // Try local page pool first
        if (self.page_pool.get()) |page| {
            return page;
        }

        // Get from segment cache
        const seg = segment_cache.acquireForNode(self.numa_node) orelse
            segment_cache.acquire() orelse return null;

        const page_idx = seg.allocPage() orelse {
            segment_cache.release(seg);
            return null;
        };

        const page: *page_mod.Page = @ptrCast(@alignCast(seg.pageAddress(page_idx)));
        return page;
    }

    // Free a page back to thread cache
    pub fn freePage(self: *Self, page: *page_mod.Page, segment_cache: *segment_mod.SegmentCache) void {
        // Try to cache locally
        if (self.page_pool.put(page)) {
            return;
        }

        // Pool full, return to segment
        if (page.segment) |seg| {
            seg.freePage(page.index);
            if (seg.isEmpty()) {
                segment_cache.release(seg);
            }
        }
    }

    // Free to thread cache
    pub fn free(self: *Self, ptr: [*]u8, page: *page_mod.Page, slab_allocator: *slab_mod.SlabAllocator) void {
        if (page.state != .slab) return;

        self.free_count += 1;
        const class_idx = page.size_class;

        // Check if this is a cross-thread free
        if (page.owner_thread != self.thread_id) {
            // Return to shared page directly (cross-thread free)
            slab_allocator.freeRemote(page, ptr);
            return;
        }

        if (self.caches[class_idx].isFull()) {
            // Cache full - flush half to slab allocator
            self.flushCache(class_idx, slab_allocator);
        }

        self.caches[class_idx].push(ptr);
    }

    // Fill cache from slab allocator
    fn fillCache(self: *Self, class_idx: usize, slab_allocator: *slab_mod.SlabAllocator) void {
        var i: usize = 0;
        while (i < config.THREAD_CACHE_FILL_COUNT) : (i += 1) {
            const ptr = slab_allocator.allocForThread(config.SIZE_CLASSES[class_idx], self.thread_id) orelse break;
            self.caches[class_idx].push(ptr);
        }
    }

    // Flush half the cache to slab allocator
    fn flushCache(self: *Self, class_idx: usize, slab_allocator: *slab_mod.SlabAllocator) void {
        const flush_count = self.caches[class_idx].count / 2;
        var i: usize = 0;
        while (i < flush_count) : (i += 1) {
            const ptr = self.caches[class_idx].pop() orelse break;
            slab_allocator.free(ptr);
        }
    }

    // Flush all caches (call on thread exit)
    pub fn flushAll(self: *Self, slab_allocator: *slab_mod.SlabAllocator, segment_cache: *segment_mod.SegmentCache) void {
        // Flush block caches
        for (&self.caches) |*cache| {
            while (cache.pop()) |ptr| {
                slab_allocator.free(ptr);
            }
        }

        // Flush page pool
        self.page_pool.flushAll(segment_cache);

        self.active = false;
    }

    // Get total cached blocks
    pub fn getTotalCached(self: *Self) usize {
        var total: usize = 0;
        for (self.caches) |cache| {
            total += cache.count;
        }
        return total;
    }

    // Get cache statistics
    pub fn getStats(self: *Self) CacheStats {
        return .{
            .alloc_count = self.alloc_count,
            .free_count = self.free_count,
            .cache_hits = self.cache_hits,
            .cache_misses = self.cache_misses,
            .cached_blocks = self.getTotalCached(),
            .cached_pages = self.page_pool.count,
            .hit_rate = if (self.alloc_count > 0)
                @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(self.alloc_count))
            else
                0.0,
        };
    }
};

pub const CacheStats = struct {
    alloc_count: usize,
    free_count: usize,
    cache_hits: usize,
    cache_misses: usize,
    cached_blocks: usize,
    cached_pages: usize,
    hit_rate: f64,
};

// Global thread cache registry
pub const ThreadCacheRegistry = struct {
    // Head of linked list of all thread caches
    head: ?*ThreadCache,

    // Lock for registry modifications
    lock: std.Thread.Mutex,

    // Pool of pre-allocated cache structs
    pool: [MAX_CACHED_THREADS]ThreadCache,
    pool_used: [MAX_CACHED_THREADS]bool,

    const MAX_CACHED_THREADS = 64;

    const Self = @This();

    pub fn init() Self {
        return .{
            .head = null,
            .lock = .{},
            .pool = undefined, // Initialized lazily
            .pool_used = [_]bool{false} ** MAX_CACHED_THREADS,
        };
    }

    // Get or create a thread cache for the current thread
    pub fn getOrCreate(self: *Self, tid: usize) ?*ThreadCache {
        self.lock.lock();
        defer self.lock.unlock();

        // Search existing caches
        var current = self.head;
        while (current) |tc| {
            if (tc.thread_id == tid and tc.active) {
                return tc;
            }
            current = tc.next;
        }

        // Allocate new from pool
        for (&self.pool, &self.pool_used) |*tc, *used| {
            if (!used.*) {
                used.* = true;
                tc.* = ThreadCache.init(tid);

                // Add to registry list
                tc.next = self.head;
                tc.prev = null;
                if (self.head) |h| {
                    h.prev = tc;
                }
                self.head = tc;

                return tc;
            }
        }

        return null; // Pool exhausted
    }

    // Remove and cleanup a thread cache
    pub fn remove(self: *Self, tc: *ThreadCache, slab_allocator: *slab_mod.SlabAllocator, segment_cache: *segment_mod.SegmentCache) void {
        self.lock.lock();
        defer self.lock.unlock();

        // Flush all cached blocks and pages
        tc.flushAll(slab_allocator, segment_cache);

        // Remove from linked list
        if (tc.prev) |prev| {
            prev.next = tc.next;
        } else {
            self.head = tc.next;
        }

        if (tc.next) |next| {
            next.prev = tc.prev;
        }

        // Return to pool
        const pool_base = @intFromPtr(&self.pool[0]);
        const tc_addr = @intFromPtr(tc);
        const index = (tc_addr - pool_base) / @sizeOf(ThreadCache);

        if (index < MAX_CACHED_THREADS) {
            self.pool_used[index] = false;
        }
    }

    // Cleanup all inactive caches (call periodically)
    pub fn cleanupInactive(self: *Self, slab_allocator: *slab_mod.SlabAllocator, segment_cache: *segment_mod.SegmentCache) void {
        self.lock.lock();
        defer self.lock.unlock();

        var current = self.head;
        while (current) |tc| {
            const next = tc.next;
            if (!tc.active) {
                // Already flushed, just remove from list
                if (tc.prev) |prev| {
                    prev.next = tc.next;
                } else {
                    self.head = tc.next;
                }
                if (tc.next) |n| {
                    n.prev = tc.prev;
                }

                // Return to pool
                const pool_base = @intFromPtr(&self.pool[0]);
                const tc_addr = @intFromPtr(tc);
                const index = (tc_addr - pool_base) / @sizeOf(ThreadCache);
                if (index < MAX_CACHED_THREADS) {
                    self.pool_used[index] = false;
                }
            }
            current = next;
            _ = slab_allocator;
            _ = segment_cache;
        }
    }

    // Get aggregate statistics
    pub fn getAggregateStats(self: *Self) CacheStats {
        self.lock.lock();
        defer self.lock.unlock();

        var total = CacheStats{
            .alloc_count = 0,
            .free_count = 0,
            .cache_hits = 0,
            .cache_misses = 0,
            .cached_blocks = 0,
            .cached_pages = 0,
            .hit_rate = 0.0,
        };

        var current = self.head;
        while (current) |tc| {
            const stats = tc.getStats();
            total.alloc_count += stats.alloc_count;
            total.free_count += stats.free_count;
            total.cache_hits += stats.cache_hits;
            total.cache_misses += stats.cache_misses;
            total.cached_blocks += stats.cached_blocks;
            total.cached_pages += stats.cached_pages;
            current = tc.next;
        }

        if (total.alloc_count > 0) {
            total.hit_rate = @as(f64, @floatFromInt(total.cache_hits)) / @as(f64, @floatFromInt(total.alloc_count));
        }

        return total;
    }
};

// Global registry instance
var global_registry: ThreadCacheRegistry = ThreadCacheRegistry.init();

pub fn getGlobalRegistry() *ThreadCacheRegistry {
    return &global_registry;
}

// Thread-local storage for current thread's cache
threadlocal var tls_cache: ?*ThreadCache = null;
threadlocal var tls_initialized: bool = false;

// Deferred cleanup context - stored when thread exit handler fires
// but we don't have the allocator references yet
var deferred_slab: ?*slab_mod.SlabAllocator = null;
var deferred_segment_cache: ?*segment_mod.SegmentCache = null;
var exit_handler_registered: bool = false;

// Get thread cache for current thread (fast path uses TLS)
pub fn getThreadCache() ?*ThreadCache {
    if (tls_initialized) {
        return tls_cache;
    }

    // First access - get or create from registry
    const tid = platform.getThreadId();
    tls_cache = global_registry.getOrCreate(tid);
    tls_initialized = true;

    // Mark this thread for automatic cleanup on exit
    if (exit_handler_registered) {
        platform.markThreadForCleanup();
    }

    return tls_cache;
}

// Called when a thread exits - flushes cache back to heap
pub fn onThreadExit(slab_allocator: *slab_mod.SlabAllocator, segment_cache: *segment_mod.SegmentCache) void {
    if (tls_cache) |tc| {
        global_registry.remove(tc, slab_allocator, segment_cache);
        tls_cache = null;
        tls_initialized = false;
    }
}

// Internal callback invoked by platform thread exit handler
fn autoThreadCleanup() void {
    if (tls_cache) |tc| {
        if (deferred_slab) |slab| {
            if (deferred_segment_cache) |cache| {
                global_registry.remove(tc, slab, cache);
            }
        }
        tls_cache = null;
        tls_initialized = false;
    }
}

// Register thread exit handler (platform-specific) with allocator context
// Must be called after heap initialization
pub fn registerThreadExitHandler(slab_allocator: *slab_mod.SlabAllocator, segment_cache: *segment_mod.SegmentCache) bool {
    if (exit_handler_registered) return true;

    // Store allocator references for deferred cleanup
    deferred_slab = slab_allocator;
    deferred_segment_cache = segment_cache;

    // Register with platform
    if (platform.registerThreadExitCallback(autoThreadCleanup)) {
        exit_handler_registered = true;
        return true;
    }
    return false;
}

// ============= Tests =============

test "size class cache push/pop" {
    var cache = SizeClassCache.init();

    try std.testing.expect(cache.isEmpty());

    // Create some fake pointers (need to be properly aligned)
    var blocks: [64]u8 align(16) = undefined;
    const ptr: [*]u8 = &blocks;

    cache.push(ptr);
    try std.testing.expect(!cache.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), cache.count);

    const popped = cache.pop();
    try std.testing.expect(popped != null);
    try std.testing.expect(cache.isEmpty());
}

test "page pool" {
    var pool = PagePool.init();

    try std.testing.expectEqual(@as(usize, 0), pool.count);
    try std.testing.expect(pool.get() == null);
}

test "thread cache initialization" {
    var tc = ThreadCache.init(123);

    try std.testing.expectEqual(@as(usize, 123), tc.thread_id);
    try std.testing.expectEqual(@as(usize, 0), tc.getTotalCached());
    try std.testing.expect(tc.active);
}

test "thread cache stats" {
    var tc = ThreadCache.init(123);
    const stats = tc.getStats();

    try std.testing.expectEqual(@as(usize, 0), stats.alloc_count);
    try std.testing.expectEqual(@as(usize, 0), stats.cache_hits);
}

test "thread cache registry" {
    var registry = ThreadCacheRegistry.init();

    const tc1 = registry.getOrCreate(100);
    try std.testing.expect(tc1 != null);
    try std.testing.expectEqual(@as(usize, 100), tc1.?.thread_id);

    const tc2 = registry.getOrCreate(200);
    try std.testing.expect(tc2 != null);
    try std.testing.expectEqual(@as(usize, 200), tc2.?.thread_id);

    // Same thread should get same cache
    const tc1_again = registry.getOrCreate(100);
    try std.testing.expectEqual(tc1, tc1_again);
}

test "thread cache alloc from slab" {
    var segment_cache = segment_mod.SegmentCache.init();
    var slab = slab_mod.SlabAllocator.init(&segment_cache);
    var tc = ThreadCache.init(1);

    // First alloc triggers fill from slab
    const p1 = tc.alloc(32, &slab) orelse return error.AllocFailed;
    p1[0] = 42;

    // Cache should have been filled
    try std.testing.expect(tc.getTotalCached() > 0);

    // Get the page to test free
    const page = page_mod.pageFromPtr(@ptrCast(p1));

    // Free back to cache
    tc.free(p1, page, &slab);

    // Should be able to alloc again from cache
    const p2 = tc.alloc(32, &slab) orelse return error.AllocFailed;
    p2[0] = 99;

    tc.flushAll(&slab, &segment_cache);
}

test "thread cache flush when full" {
    var segment_cache = segment_mod.SegmentCache.init();
    var slab = slab_mod.SlabAllocator.init(&segment_cache);
    var tc = ThreadCache.init(1);

    // Allocate many blocks
    var ptrs: [300]struct { ptr: *u8, page: *page_mod.Page } = undefined;
    var count: usize = 0;

    for (&ptrs) |*p| {
        const ptr = tc.alloc(64, &slab) orelse break;
        const page = page_mod.pageFromPtr(@ptrCast(ptr));
        p.* = .{ .ptr = @ptrCast(ptr), .page = page };
        count += 1;
    }

    // Free them all (will trigger flush when cache gets full)
    for (ptrs[0..count]) |p| {
        tc.free(@ptrCast(p.ptr), p.page, &slab);
    }

    // Cache should not exceed max
    const class_idx = config.sizeClassIndex(64).?;
    try std.testing.expect(tc.caches[class_idx].count <= config.THREAD_CACHE_MAX_BLOCKS);

    tc.flushAll(&slab, &segment_cache);
}
