// macOS Platform Implementation
//
// Memory operations using mmap/munmap, madvise for hints.
// Note: macOS doesn't expose NUMA topology to userspace.

const std = @import("std");
const config = @import("../config.zig");

const c = @cImport({
    @cInclude("mach/mach.h");
    @cInclude("pthread.h");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
});

// ============= Core Memory Operations =============

pub fn mapMemory(size: usize, alignment: usize) ?[*]u8 {
    // For large alignments (like 2MB segments), use over-allocation
    if (alignment > std.heap.page_size_min) {
        return mapAligned(size, alignment);
    }

    const prot = c.PROT_READ | c.PROT_WRITE;
    const flags = c.MAP_PRIVATE | c.MAP_ANON;

    const result = c.mmap(null, size, prot, flags, -1, 0);
    if (result == c.MAP_FAILED) {
        return null;
    }

    return @ptrCast(result);
}

fn mapAligned(size: usize, alignment: usize) ?[*]u8 {
    // Over-allocate to ensure we can align
    const total_size = size + alignment;

    const prot = c.PROT_READ | c.PROT_WRITE;
    const flags = c.MAP_PRIVATE | c.MAP_ANON;

    const result = c.mmap(null, total_size, prot, flags, -1, 0);
    if (result == c.MAP_FAILED) {
        return null;
    }

    const addr = @intFromPtr(result);
    const aligned_addr = (addr + alignment - 1) & ~(alignment - 1);

    // Unmap excess at beginning
    if (aligned_addr > addr) {
        _ = c.munmap(@ptrFromInt(addr), aligned_addr - addr);
    }

    // Unmap excess at end
    const end_addr = aligned_addr + size;
    const total_end = addr + total_size;
    if (total_end > end_addr) {
        _ = c.munmap(@ptrFromInt(end_addr), total_end - end_addr);
    }

    return @ptrFromInt(aligned_addr);
}

pub fn unmapMemory(ptr: [*]u8, size: usize) void {
    _ = c.munmap(ptr, size);
}

pub fn decommitMemory(ptr: [*]u8, size: usize) void {
    // MADV_FREE releases pages when under memory pressure
    // MADV_DONTNEED is not well-defined on macOS
    _ = c.madvise(ptr, size, c.MADV_FREE);
}

pub fn commitMemory(ptr: [*]u8, size: usize) bool {
    // Touch pages to ensure they're committed
    // madvise with MADV_WILLNEED
    _ = c.madvise(ptr, size, c.MADV_WILLNEED);
    return true;
}

// ============= Huge Page Support =============

// macOS supports "superpage" allocations via VM_FLAGS_SUPERPAGE_SIZE_*

pub fn mapHugePages(size: usize, huge_page_size: usize) ?[*]u8 {
    // macOS superpage support is limited and architecture-dependent
    // Try regular mapping with alignment
    return mapAligned(size, huge_page_size);
}

pub fn hugePageAvailable(huge_page_size: usize) bool {
    // macOS has limited huge page support
    // 2MB pages may be available on some systems
    _ = huge_page_size;
    return false;
}

// ============= NUMA Support =============

// macOS doesn't expose NUMA topology to userspace
// All NUMA functions return single-node behavior

pub fn numaNodeCount() usize {
    return 1;
}

pub fn numaCurrentNode() u8 {
    return 0;
}

pub fn mapOnNode(size: usize, alignment: usize, node: u8) ?[*]u8 {
    _ = node;
    return mapMemory(size, alignment);
}

pub fn numaNodeInfo(node: u8) ?@import("../platform.zig").NumaNode {
    if (node != 0) return null;

    // Get total memory via sysctl
    var total_mem: u64 = 0;

    var mib = [_]c_int{ c.CTL_HW, c.HW_MEMSIZE };
    var len: usize = @sizeOf(u64);

    if (c.sysctl(&mib, 2, &total_mem, &len, null, 0) == 0) {
        return .{
            .id = 0,
            .cpu_count = @intCast(c.sysconf(c._SC_NPROCESSORS_ONLN)),
            .memory_bytes = total_mem,
            .free_bytes = 0, // Would need more syscalls to get
        };
    }

    return null;
}

pub fn numaBindMemory(ptr: [*]u8, size: usize, node: u8) bool {
    _ = ptr;
    _ = size;
    _ = node;
    return true; // No-op on macOS
}

// ============= Thread Support =============

pub fn getThreadId() usize {
    var tid: u64 = 0;
    _ = c.pthread_threadid_np(null, &tid);
    return @intCast(tid);
}

// ============= Thread Exit Handler =============

var thread_key: c.pthread_key_t = undefined;
var thread_key_created: bool = false;
var thread_exit_fn: ?*const fn () void = null;

// Destructor called by pthread when thread exits
fn threadDestructor(value: ?*anyopaque) callconv(.c) void {
    _ = value;
    if (thread_exit_fn) |func| {
        func();
    }
}

/// Register thread exit handler using pthread_key_create
pub fn registerThreadExitHandler(callback: *const fn () void) bool {
    if (thread_key_created) return true;

    thread_exit_fn = callback;

    const result = c.pthread_key_create(&thread_key, threadDestructor);
    if (result == 0) {
        thread_key_created = true;
        return true;
    }
    return false;
}

/// Mark current thread for cleanup by setting a non-null value on the key
pub fn markThreadForCleanup() void {
    if (thread_key_created) {
        // Set a non-null value so destructor gets called
        _ = c.pthread_setspecific(thread_key, @ptrFromInt(1));
    }
}

// ============= Tests =============

test "macos map/unmap" {
    if (config.current_platform != .macos) return error.SkipZigTest;

    const ptr = mapMemory(4096, 4096) orelse return error.MapFailed;
    ptr[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), ptr[0]);
    unmapMemory(ptr, 4096);
}

test "macos aligned map" {
    if (config.current_platform != .macos) return error.SkipZigTest;

    const ptr = mapMemory(config.SEGMENT_SIZE, config.SEGMENT_ALIGNMENT) orelse return error.MapFailed;
    defer unmapMemory(ptr, config.SEGMENT_SIZE);

    const addr = @intFromPtr(ptr);
    try std.testing.expectEqual(@as(usize, 0), addr % config.SEGMENT_ALIGNMENT);
}

test "macos decommit/recommit" {
    if (config.current_platform != .macos) return error.SkipZigTest;

    const ptr = mapMemory(config.PAGE_SIZE, config.PAGE_SIZE) orelse return error.MapFailed;
    defer unmapMemory(ptr, config.PAGE_SIZE);

    ptr[0] = 42;
    decommitMemory(ptr, config.PAGE_SIZE);
    _ = commitMemory(ptr, config.PAGE_SIZE);
}

test "macos thread id" {
    if (config.current_platform != .macos) return error.SkipZigTest;

    const tid = getThreadId();
    try std.testing.expect(tid > 0);
}
