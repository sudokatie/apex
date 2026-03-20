// macOS platform implementation
//
// Uses mmap/munmap similar to Linux, with Darwin-specific thread ID.

const std = @import("std");
const c = @cImport({
    @cInclude("pthread.h");
});

const page_size = std.heap.page_size_min;

pub fn mapMemory(size: usize, alignment: usize) ?[*]u8 {
    // For alignment > page_size, allocate extra and adjust
    const alloc_size = if (alignment > page_size)
        size + alignment
    else
        size;

    const result = std.posix.mmap(
        null,
        alloc_size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );

    const ptr = result catch return null;

    if (alignment > page_size) {
        // Align the pointer and unmap excess
        const addr = @intFromPtr(ptr.ptr);
        const aligned_addr = (addr + alignment - 1) & ~(alignment - 1);
        const offset = aligned_addr - addr;

        // Unmap prefix if any
        if (offset > 0) {
            const prefix: []align(page_size) u8 = @alignCast(@as([*]u8, @ptrFromInt(addr))[0..offset]);
            std.posix.munmap(prefix);
        }

        // Unmap suffix if any
        const suffix = alloc_size - offset - size;
        if (suffix > 0) {
            const suffix_ptr: []align(page_size) u8 = @alignCast(@as([*]u8, @ptrFromInt(aligned_addr + size))[0..suffix]);
            std.posix.munmap(suffix_ptr);
        }

        return @ptrFromInt(aligned_addr);
    }

    return @ptrCast(ptr.ptr);
}

pub fn unmapMemory(ptr: [*]u8, size: usize) void {
    const slice: []align(page_size) u8 = @alignCast(ptr[0..size]);
    std.posix.munmap(slice);
}

pub fn commitMemory(ptr: [*]u8, size: usize) bool {
    // On macOS, mmap'd anonymous memory is committed on first access
    _ = ptr;
    _ = size;
    return true;
}

pub fn decommitMemory(ptr: [*]u8, size: usize) void {
    // MADV_FREE on macOS (similar to DONTNEED on Linux)
    // Zig 0.15: madvise takes (ptr, len, advice_u32)
    const slice: [*]align(page_size) u8 = @alignCast(ptr);
    std.posix.madvise(slice, size, std.posix.MADV.FREE) catch {};
}

pub fn getThreadId() usize {
    // Use pthread_mach_thread_np to get Mach thread port (unique per thread)
    const self = c.pthread_self();
    const tid = c.pthread_mach_thread_np(self);
    return @intCast(tid);
}
