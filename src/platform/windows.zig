// Windows Platform Implementation
//
// Memory operations using VirtualAlloc/VirtualFree, NUMA via Windows API.

const std = @import("std");
const config = @import("../config.zig");
const windows = std.os.windows;

// Windows API constants
const MEM_COMMIT: windows.DWORD = 0x1000;
const MEM_RESERVE: windows.DWORD = 0x2000;
const MEM_RELEASE: windows.DWORD = 0x8000;
const MEM_DECOMMIT: windows.DWORD = 0x4000;
const MEM_LARGE_PAGES: windows.DWORD = 0x20000000;

const PAGE_READWRITE: windows.DWORD = 0x04;

// ============= Core Memory Operations =============

pub fn mapMemory(size: usize, alignment: usize) ?[*]u8 {
    // VirtualAlloc2 supports alignment on Windows 10 1803+
    // Fall back to over-allocation for earlier versions
    if (alignment > std.heap.page_size_min) {
        return mapAligned(size, alignment);
    }

    const ptr = windows.VirtualAlloc(
        null,
        size,
        MEM_RESERVE | MEM_COMMIT,
        PAGE_READWRITE,
    );

    if (ptr == null) {
        return null;
    }

    return @ptrCast(ptr);
}

fn mapAligned(size: usize, alignment: usize) ?[*]u8 {
    // Over-allocate to guarantee alignment
    const total_size = size + alignment;

    const raw_ptr = windows.VirtualAlloc(
        null,
        total_size,
        MEM_RESERVE | MEM_COMMIT,
        PAGE_READWRITE,
    ) orelse return null;

    const addr = @intFromPtr(raw_ptr);
    const aligned_addr = (addr + alignment - 1) & ~(alignment - 1);

    // We can't partially free VirtualAlloc memory, so we need to:
    // 1. Free the entire allocation
    // 2. Try to allocate at the aligned address
    _ = windows.VirtualFree(raw_ptr, 0, MEM_RELEASE);

    // Try to allocate at the exact aligned address
    const aligned_ptr = windows.VirtualAlloc(
        @ptrFromInt(aligned_addr),
        size,
        MEM_RESERVE | MEM_COMMIT,
        PAGE_READWRITE,
    );

    if (aligned_ptr == null) {
        // Allocation at exact address failed, fall back to retry
        return mapMemory(size, std.heap.page_size_min);
    }

    return @ptrCast(aligned_ptr);
}

pub fn unmapMemory(ptr: [*]u8, size: usize) void {
    _ = size;
    _ = windows.VirtualFree(ptr, 0, MEM_RELEASE);
}

pub fn decommitMemory(ptr: [*]u8, size: usize) void {
    _ = windows.VirtualFree(ptr, size, MEM_DECOMMIT);
}

pub fn commitMemory(ptr: [*]u8, size: usize) bool {
    const result = windows.VirtualAlloc(
        ptr,
        size,
        MEM_COMMIT,
        PAGE_READWRITE,
    );
    return result != null;
}

// ============= Huge Page Support =============

pub fn mapHugePages(size: usize, huge_page_size: usize) ?[*]u8 {
    _ = huge_page_size;

    // Requires SeLockMemoryPrivilege
    const ptr = windows.VirtualAlloc(
        null,
        size,
        MEM_RESERVE | MEM_COMMIT | MEM_LARGE_PAGES,
        PAGE_READWRITE,
    );

    if (ptr == null) {
        // Fall back to regular allocation
        return mapMemory(size, config.HUGE_PAGE_2MB);
    }

    return @ptrCast(ptr);
}

pub fn hugePageAvailable(huge_page_size: usize) bool {
    _ = huge_page_size;

    // Check if SeLockMemoryPrivilege is available
    // This requires querying the process token
    // For simplicity, try an allocation and see if it works

    const test_size = config.HUGE_PAGE_2MB;
    const ptr = windows.VirtualAlloc(
        null,
        test_size,
        MEM_RESERVE | MEM_COMMIT | MEM_LARGE_PAGES,
        PAGE_READWRITE,
    );

    if (ptr != null) {
        _ = windows.VirtualFree(ptr, 0, MEM_RELEASE);
        return true;
    }

    return false;
}

// ============= NUMA Support =============

// Windows NUMA API
extern "kernel32" fn GetNumaHighestNodeNumber(HighestNodeNumber: *windows.ULONG) callconv(windows.WINAPI) windows.BOOL;
extern "kernel32" fn GetCurrentProcessorNumber() callconv(windows.WINAPI) windows.DWORD;
extern "kernel32" fn GetNumaProcessorNode(Processor: windows.UCHAR, NodeNumber: *windows.UCHAR) callconv(windows.WINAPI) windows.BOOL;
extern "kernel32" fn VirtualAllocExNuma(
    hProcess: windows.HANDLE,
    lpAddress: ?*anyopaque,
    dwSize: windows.SIZE_T,
    flAllocationType: windows.DWORD,
    flProtect: windows.DWORD,
    nndPreferred: windows.DWORD,
) callconv(windows.WINAPI) ?*anyopaque;
extern "kernel32" fn GetNumaAvailableMemoryNode(Node: windows.UCHAR, AvailableBytes: *windows.ULONGLONG) callconv(windows.WINAPI) windows.BOOL;

pub fn numaNodeCount() usize {
    var highest_node: windows.ULONG = 0;
    if (GetNumaHighestNodeNumber(&highest_node) != 0) {
        return @intCast(highest_node + 1);
    }
    return 1;
}

pub fn numaCurrentNode() u8 {
    const processor = GetCurrentProcessorNumber();
    var node: windows.UCHAR = 0;
    if (GetNumaProcessorNode(@intCast(processor), &node) != 0) {
        return node;
    }
    return 0;
}

pub fn mapOnNode(size: usize, alignment: usize, node: u8) ?[*]u8 {
    if (alignment > std.heap.page_size_min) {
        // Need aligned allocation on specific node
        // This is complex on Windows, fall back to regular aligned allocation
        return mapAligned(size, alignment);
    }

    const ptr = VirtualAllocExNuma(
        windows.GetCurrentProcess(),
        null,
        size,
        MEM_RESERVE | MEM_COMMIT,
        PAGE_READWRITE,
        node,
    );

    if (ptr == null) {
        return null;
    }

    return @ptrCast(ptr);
}

pub fn numaNodeInfo(node: u8) ?@import("../platform.zig").NumaNode {
    var available_bytes: windows.ULONGLONG = 0;

    if (GetNumaAvailableMemoryNode(node, &available_bytes) == 0) {
        return null;
    }

    // Getting total memory per node requires more complex queries
    // For now, just return available bytes

    return .{
        .id = node,
        .cpu_count = 0, // Would need to enumerate processors
        .memory_bytes = 0, // Would need GetNumaNodeProcessorMaskEx
        .free_bytes = available_bytes,
    };
}

pub fn numaBindMemory(ptr: [*]u8, size: usize, node: u8) bool {
    _ = ptr;
    _ = size;
    _ = node;
    // Windows doesn't have mbind equivalent
    // Memory is bound at allocation time via VirtualAllocExNuma
    return true;
}

// ============= Thread Support =============

extern "kernel32" fn GetCurrentThreadId() callconv(windows.WINAPI) windows.DWORD;

pub fn getThreadId() usize {
    return GetCurrentThreadId();
}

// ============= Thread Exit Handler =============

// Windows Fiber Local Storage for thread exit callbacks
extern "kernel32" fn FlsAlloc(lpCallback: ?*const fn (windows.PVOID) callconv(windows.WINAPI) void) callconv(windows.WINAPI) windows.DWORD;
extern "kernel32" fn FlsSetValue(dwFlsIndex: windows.DWORD, lpFlsData: ?windows.PVOID) callconv(windows.WINAPI) windows.BOOL;
extern "kernel32" fn FlsFree(dwFlsIndex: windows.DWORD) callconv(windows.WINAPI) windows.BOOL;

const FLS_OUT_OF_INDEXES: windows.DWORD = 0xFFFFFFFF;

var fls_index: windows.DWORD = FLS_OUT_OF_INDEXES;
var thread_exit_fn: ?*const fn () void = null;

// Callback invoked by Windows when thread/fiber exits
fn flsCallback(value: windows.PVOID) callconv(windows.WINAPI) void {
    _ = value;
    if (thread_exit_fn) |func| {
        func();
    }
}

/// Register thread exit handler using FlsAlloc
pub fn registerThreadExitHandler(callback: *const fn () void) bool {
    if (fls_index != FLS_OUT_OF_INDEXES) return true;

    thread_exit_fn = callback;

    fls_index = FlsAlloc(flsCallback);
    return fls_index != FLS_OUT_OF_INDEXES;
}

/// Mark current thread for cleanup by setting a non-null value
pub fn markThreadForCleanup() void {
    if (fls_index != FLS_OUT_OF_INDEXES) {
        // Set a non-null value so callback gets called on thread exit
        _ = FlsSetValue(fls_index, @ptrFromInt(1));
    }
}

// ============= Tests =============

test "windows map/unmap" {
    if (config.current_platform != .windows) return error.SkipZigTest;

    const ptr = mapMemory(4096, 4096) orelse return error.MapFailed;
    ptr[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), ptr[0]);
    unmapMemory(ptr, 4096);
}

test "windows aligned map" {
    if (config.current_platform != .windows) return error.SkipZigTest;

    const ptr = mapMemory(config.SEGMENT_SIZE, config.SEGMENT_ALIGNMENT) orelse return error.MapFailed;
    defer unmapMemory(ptr, config.SEGMENT_SIZE);

    const addr = @intFromPtr(ptr);
    try std.testing.expectEqual(@as(usize, 0), addr % config.SEGMENT_ALIGNMENT);
}

test "windows decommit/recommit" {
    if (config.current_platform != .windows) return error.SkipZigTest;

    const ptr = mapMemory(config.PAGE_SIZE, config.PAGE_SIZE) orelse return error.MapFailed;
    defer unmapMemory(ptr, config.PAGE_SIZE);

    ptr[0] = 42;
    decommitMemory(ptr, config.PAGE_SIZE);
    const ok = commitMemory(ptr, config.PAGE_SIZE);
    try std.testing.expect(ok);
}

test "windows numa node count" {
    if (config.current_platform != .windows) return error.SkipZigTest;

    const count = numaNodeCount();
    try std.testing.expect(count >= 1);
}

test "windows thread id" {
    if (config.current_platform != .windows) return error.SkipZigTest;

    const tid = getThreadId();
    try std.testing.expect(tid > 0);
}
