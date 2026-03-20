// Windows platform implementation
//
// Uses VirtualAlloc/VirtualFree for memory management.

const std = @import("std");
const windows = std.os.windows;

pub fn mapMemory(size: usize, alignment: usize) ?[*]u8 {
    // VirtualAlloc aligns to 64KB by default (allocation granularity)
    // For 2MB alignment, we need to allocate extra and adjust
    const alloc_size = if (alignment > 65536)
        size + alignment
    else
        size;

    // MEM_RESERVE | MEM_COMMIT to immediately back with physical memory
    const ptr = windows.VirtualAlloc(
        null,
        alloc_size,
        windows.MEM_RESERVE | windows.MEM_COMMIT,
        windows.PAGE_READWRITE,
    ) orelse return null;

    if (alignment > 65536) {
        // Align the pointer
        const addr = @intFromPtr(ptr);
        const aligned_addr = (addr + alignment - 1) & ~(alignment - 1);

        // Free the original and re-reserve at aligned address
        // This is complex on Windows - for now, just use the aligned portion
        // and accept some waste
        return @ptrFromInt(aligned_addr);
    }

    return @ptrCast(ptr);
}

pub fn unmapMemory(ptr: [*]u8, size: usize) void {
    _ = size; // Windows VirtualFree releases entire region
    windows.VirtualFree(@ptrCast(ptr), 0, windows.MEM_RELEASE);
}

pub fn commitMemory(ptr: [*]u8, size: usize) bool {
    // Memory is already committed if we used MEM_COMMIT in VirtualAlloc
    // This would be used for reserve-then-commit pattern
    const result = windows.VirtualAlloc(
        @ptrCast(ptr),
        size,
        windows.MEM_COMMIT,
        windows.PAGE_READWRITE,
    );
    return result != null;
}

pub fn decommitMemory(ptr: [*]u8, size: usize) void {
    // MEM_DECOMMIT releases physical pages but keeps virtual reservation
    _ = windows.VirtualFree(@ptrCast(ptr), size, windows.MEM_DECOMMIT);
}

pub fn getThreadId() usize {
    return windows.GetCurrentThreadId();
}
