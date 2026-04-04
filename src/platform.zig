// Platform Abstraction Layer
//
// OS-specific memory operations for Linux, macOS, and Windows.
// Provides unified interface for memory mapping, NUMA, and huge pages.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

// Platform-specific implementations
const linux = @import("platform/linux.zig");
const macos = @import("platform/macos.zig");
const windows = @import("platform/windows.zig");

// ============= Core Memory Operations =============

/// Map memory from the OS
/// Returns aligned memory or null on failure
pub fn mapMemory(size: usize, alignment: usize) ?[*]u8 {
    return switch (config.current_platform) {
        .linux => linux.mapMemory(size, alignment),
        .macos => macos.mapMemory(size, alignment),
        .windows => windows.mapMemory(size, alignment),
        .other => fallbackMap(size, alignment),
    };
}

/// Unmap memory back to the OS
pub fn unmapMemory(ptr: [*]u8, size: usize) void {
    switch (config.current_platform) {
        .linux => linux.unmapMemory(ptr, size),
        .macos => macos.unmapMemory(ptr, size),
        .windows => windows.unmapMemory(ptr, size),
        .other => fallbackUnmap(ptr, size),
    }
}

/// Decommit memory (release physical pages, keep virtual mapping)
pub fn decommitMemory(ptr: [*]u8, size: usize) void {
    switch (config.current_platform) {
        .linux => linux.decommitMemory(ptr, size),
        .macos => macos.decommitMemory(ptr, size),
        .windows => windows.decommitMemory(ptr, size),
        .other => {},
    }
}

/// Recommit memory (make physical pages available again)
pub fn commitMemory(ptr: [*]u8, size: usize) bool {
    return switch (config.current_platform) {
        .linux => linux.commitMemory(ptr, size),
        .macos => macos.commitMemory(ptr, size),
        .windows => windows.commitMemory(ptr, size),
        .other => true,
    };
}

// ============= Huge Page Support =============

/// Map memory using huge pages (2MB or 1GB)
/// Falls back to regular mapping if huge pages unavailable
pub fn mapHugePages(size: usize, huge_page_size: usize) ?[*]u8 {
    return switch (config.current_platform) {
        .linux => linux.mapHugePages(size, huge_page_size),
        .macos => macos.mapHugePages(size, huge_page_size),
        .windows => windows.mapHugePages(size, huge_page_size),
        .other => mapMemory(size, huge_page_size),
    };
}

/// Check if huge pages are available
pub fn hugePageAvailable(huge_page_size: usize) bool {
    return switch (config.current_platform) {
        .linux => linux.hugePageAvailable(huge_page_size),
        .macos => macos.hugePageAvailable(huge_page_size),
        .windows => windows.hugePageAvailable(huge_page_size),
        .other => false,
    };
}

// ============= NUMA Support =============

/// NUMA node information
pub const NumaNode = struct {
    id: u8,
    cpu_count: u16,
    memory_bytes: u64,
    free_bytes: u64,
};

/// Get number of NUMA nodes
pub fn numaNodeCount() usize {
    return switch (config.current_platform) {
        .linux => linux.numaNodeCount(),
        .macos => 1, // macOS doesn't expose NUMA topology
        .windows => windows.numaNodeCount(),
        .other => 1,
    };
}

/// Get current thread's preferred NUMA node
pub fn numaCurrentNode() u8 {
    return switch (config.current_platform) {
        .linux => linux.numaCurrentNode(),
        .macos => 0,
        .windows => windows.numaCurrentNode(),
        .other => 0,
    };
}

/// Map memory on a specific NUMA node
pub fn mapOnNode(size: usize, alignment: usize, node: u8) ?[*]u8 {
    return switch (config.current_platform) {
        .linux => linux.mapOnNode(size, alignment, node),
        .macos => macos.mapMemory(size, alignment), // No NUMA on macOS
        .windows => windows.mapOnNode(size, alignment, node),
        .other => mapMemory(size, alignment),
    };
}

/// Get NUMA node information
pub fn numaNodeInfo(node: u8) ?NumaNode {
    return switch (config.current_platform) {
        .linux => linux.numaNodeInfo(node),
        .macos => null,
        .windows => windows.numaNodeInfo(node),
        .other => null,
    };
}

/// Bind memory to a NUMA node (migrate existing pages)
pub fn numaBindMemory(ptr: [*]u8, size: usize, node: u8) bool {
    return switch (config.current_platform) {
        .linux => linux.numaBindMemory(ptr, size, node),
        .macos => true, // No-op on macOS
        .windows => windows.numaBindMemory(ptr, size, node),
        .other => true,
    };
}

// ============= Thread Support =============

/// Get current thread ID
pub fn getThreadId() usize {
    return switch (config.current_platform) {
        .linux => linux.getThreadId(),
        .macos => macos.getThreadId(),
        .windows => windows.getThreadId(),
        .other => 0,
    };
}

/// Thread exit callback type
pub const ThreadExitCallback = *const fn () void;

/// Stored callback for thread exit
var thread_exit_callback: ?ThreadExitCallback = null;
var thread_exit_registered: bool = false;

/// Register a callback to be called when threads exit
/// This uses pthread_key_create on POSIX systems for automatic cleanup
pub fn registerThreadExitCallback(callback: ThreadExitCallback) bool {
    if (thread_exit_registered) return true;

    thread_exit_callback = callback;

    const success = switch (config.current_platform) {
        .linux => linux.registerThreadExitHandler(threadExitTrampoline),
        .macos => macos.registerThreadExitHandler(threadExitTrampoline),
        .windows => windows.registerThreadExitHandler(threadExitTrampoline),
        .other => false,
    };

    if (success) {
        thread_exit_registered = true;
    }
    return success;
}

/// Mark current thread for exit callback
pub fn markThreadForCleanup() void {
    switch (config.current_platform) {
        .linux => linux.markThreadForCleanup(),
        .macos => macos.markThreadForCleanup(),
        .windows => windows.markThreadForCleanup(),
        .other => {},
    }
}

/// Internal trampoline that calls the registered callback
fn threadExitTrampoline() void {
    if (thread_exit_callback) |cb| {
        cb();
    }
}

// ============= Memory Profiling Hooks =============

/// Profiling callback type
pub const ProfileCallback = *const fn (event: ProfileEvent) void;

/// Profiling events
pub const ProfileEvent = struct {
    event_type: EventType,
    ptr: ?[*]u8,
    size: usize,
    timestamp_ns: u64,
    thread_id: usize,
    numa_node: u8,
    allocation_class: config.AllocClass,
    backtrace: ?[16]usize,

    pub const EventType = enum {
        alloc,
        free,
        realloc,
        mmap,
        munmap,
        huge_page_alloc,
        numa_alloc,
    };
};

var profile_callback: ?ProfileCallback = null;
var profiling_enabled: bool = false;

/// Enable memory profiling with callback
pub fn enableProfiling(callback: ProfileCallback) void {
    profile_callback = callback;
    profiling_enabled = true;
}

/// Disable memory profiling
pub fn disableProfiling() void {
    profiling_enabled = false;
    profile_callback = null;
}

/// Check if profiling is enabled
pub fn isProfilingEnabled() bool {
    return profiling_enabled;
}

/// Record a profiling event
pub fn recordEvent(event: ProfileEvent) void {
    if (profile_callback) |cb| {
        cb(event);
    }
}

/// Get current timestamp in nanoseconds
pub fn getTimestampNs() u64 {
    return @intCast(@max(0, std.time.nanoTimestamp()));
}

/// Capture backtrace (limited depth)
pub fn captureBacktrace() ?[16]usize {
    // Backtrace capture is complex and platform-specific
    // For now, return null - can be enhanced later with platform-specific code
    return null;
}

// ============= Fallback Implementation =============

fn fallbackMap(size: usize, alignment: usize) ?[*]u8 {
    // Use Zig's page allocator as fallback
    const aligned_size = (size + alignment - 1) & ~(alignment - 1);
    const slice = std.heap.page_allocator.alloc(u8, aligned_size + alignment) catch return null;
    const addr = @intFromPtr(slice.ptr);
    const aligned_addr = (addr + alignment - 1) & ~(alignment - 1);
    return @ptrFromInt(aligned_addr);
}

fn fallbackUnmap(ptr: [*]u8, size: usize) void {
    // Note: This doesn't perfectly match fallbackMap due to alignment
    // In practice, the other platform should be used
    _ = ptr;
    _ = size;
}

// ============= Tests =============

test "map and unmap memory" {
    const ptr = mapMemory(4096, 4096) orelse return error.MapFailed;
    ptr[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), ptr[0]);
    unmapMemory(ptr, 4096);
}

test "segment-sized allocation" {
    const ptr = mapMemory(config.SEGMENT_SIZE, config.SEGMENT_ALIGNMENT) orelse return error.MapFailed;
    defer unmapMemory(ptr, config.SEGMENT_SIZE);

    // Write to start and end
    ptr[0] = 0xAA;
    ptr[config.SEGMENT_SIZE - 1] = 0xBB;

    try std.testing.expectEqual(@as(u8, 0xAA), ptr[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), ptr[config.SEGMENT_SIZE - 1]);
}

test "decommit and recommit" {
    const ptr = mapMemory(config.PAGE_SIZE, config.PAGE_SIZE) orelse return error.MapFailed;
    defer unmapMemory(ptr, config.PAGE_SIZE);

    ptr[0] = 42;
    decommitMemory(ptr, config.PAGE_SIZE);
    _ = commitMemory(ptr, config.PAGE_SIZE);
    // Note: content may or may not be preserved after decommit/recommit
}

test "thread id" {
    const tid = getThreadId();
    // Should get some thread ID
    try std.testing.expect(tid != 0 or config.current_platform == .other);
}

test "numa node count" {
    const count = numaNodeCount();
    try std.testing.expect(count >= 1);
}

test "profiling hooks" {
    const callback = struct {
        fn cb(_: ProfileEvent) void {
            // Count events
        }
    }.cb;

    enableProfiling(callback);
    try std.testing.expect(isProfilingEnabled());

    recordEvent(.{
        .event_type = .alloc,
        .ptr = null,
        .size = 64,
        .timestamp_ns = getTimestampNs(),
        .thread_id = getThreadId(),
        .numa_node = 0,
        .allocation_class = .small,
        .backtrace = null,
    });

    disableProfiling();
    try std.testing.expect(!isProfilingEnabled());
}
