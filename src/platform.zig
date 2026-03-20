// Platform abstraction layer
//
// Provides OS-specific memory operations through a unified interface.
// Supports Linux, macOS, and Windows.

const std = @import("std");
const config = @import("config.zig");

// Import platform-specific implementations
const linux = @import("platform/linux.zig");
const macos = @import("platform/macos.zig");
const windows = @import("platform/windows.zig");

// Select implementation based on current platform
const impl = switch (config.current_platform) {
    .linux => linux,
    .macos => macos,
    .windows => windows,
    .other => @compileError("Unsupported platform"),
};

// Map virtual memory region
// Returns aligned pointer to mapped memory, or null on failure.
pub fn mapMemory(size: usize, alignment: usize) ?[*]u8 {
    return impl.mapMemory(size, alignment);
}

// Unmap virtual memory region
pub fn unmapMemory(ptr: [*]u8, size: usize) void {
    impl.unmapMemory(ptr, size);
}

// Commit memory (make it physically backed)
// Returns true on success.
pub fn commitMemory(ptr: [*]u8, size: usize) bool {
    return impl.commitMemory(ptr, size);
}

// Decommit memory (release physical pages, keep virtual mapping)
pub fn decommitMemory(ptr: [*]u8, size: usize) void {
    impl.decommitMemory(ptr, size);
}

// Get current thread ID
pub fn getThreadId() usize {
    return impl.getThreadId();
}

// Tests
test "map and unmap memory" {
    const size = 64 * 1024; // 64KB
    const ptr = mapMemory(size, std.heap.page_size_min) orelse return error.MapFailed;
    defer unmapMemory(ptr, size);

    // Should be able to write to mapped memory
    ptr[0] = 42;
    ptr[size - 1] = 43;

    try std.testing.expectEqual(@as(u8, 42), ptr[0]);
    try std.testing.expectEqual(@as(u8, 43), ptr[size - 1]);
}

test "commit and decommit" {
    const size = 64 * 1024;
    const ptr = mapMemory(size, std.heap.page_size_min) orelse return error.MapFailed;
    defer unmapMemory(ptr, size);

    // Commit should succeed
    try std.testing.expect(commitMemory(ptr, size));

    // Write after commit
    ptr[0] = 99;
    try std.testing.expectEqual(@as(u8, 99), ptr[0]);

    // Decommit (this is just advisory on most platforms)
    decommitMemory(ptr, size);
}

test "thread id is stable" {
    const id1 = getThreadId();
    const id2 = getThreadId();
    try std.testing.expectEqual(id1, id2);
}

test "thread id is non-zero" {
    const id = getThreadId();
    try std.testing.expect(id != 0);
}
