// Linux Platform Implementation
//
// Memory operations using mmap/munmap, NUMA via libnuma, huge pages via madvise.

const std = @import("std");
const config = @import("../config.zig");

const os = std.os;
const linux = std.os.linux;

// ============= Core Memory Operations =============

pub fn mapMemory(size: usize, alignment: usize) ?[*]u8 {
    // For large alignments, we over-allocate and align manually
    if (alignment > std.heap.page_size_min) {
        return mapAligned(size, alignment);
    }

    const prot = linux.PROT.READ | linux.PROT.WRITE;
    const flags = linux.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true };

    const result = linux.mmap(null, size, prot, flags, -1, 0);
    if (result == linux.MAP_FAILED) {
        return null;
    }

    return @ptrFromInt(result);
}

fn mapAligned(size: usize, alignment: usize) ?[*]u8 {
    // Allocate extra space for alignment
    const total_size = size + alignment;

    const prot = linux.PROT.READ | linux.PROT.WRITE;
    const flags = linux.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true };

    const result = linux.mmap(null, total_size, prot, flags, -1, 0);
    if (result == linux.MAP_FAILED) {
        return null;
    }

    const addr = result;
    const aligned_addr = (addr + alignment - 1) & ~(alignment - 1);

    // Unmap the excess at the beginning
    if (aligned_addr > addr) {
        _ = linux.munmap(@ptrFromInt(addr), aligned_addr - addr);
    }

    // Unmap the excess at the end
    const end_addr = aligned_addr + size;
    const total_end = addr + total_size;
    if (total_end > end_addr) {
        _ = linux.munmap(@ptrFromInt(end_addr), total_end - end_addr);
    }

    return @ptrFromInt(aligned_addr);
}

pub fn unmapMemory(ptr: [*]u8, size: usize) void {
    _ = linux.munmap(ptr, size);
}

pub fn decommitMemory(ptr: [*]u8, size: usize) void {
    // MADV_DONTNEED releases physical pages but keeps virtual mapping
    _ = linux.madvise(ptr, size, linux.MADV.DONTNEED);
}

pub fn commitMemory(ptr: [*]u8, size: usize) bool {
    // Touch the pages to fault them in
    // Or use MADV_WILLNEED
    _ = linux.madvise(ptr, size, linux.MADV.WILLNEED);
    return true;
}

// ============= Huge Page Support =============

pub fn mapHugePages(size: usize, huge_page_size: usize) ?[*]u8 {
    const prot = linux.PROT.READ | linux.PROT.WRITE;
    var flags = linux.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true };

    // Set huge page flag based on size
    if (huge_page_size == config.HUGE_PAGE_2MB) {
        flags.HUGETLB = true;
        // flags.HUGE_2MB = true; // If available
    } else if (huge_page_size == config.HUGE_PAGE_1GB) {
        flags.HUGETLB = true;
        // flags.HUGE_1GB = true; // If available
    }

    const result = linux.mmap(null, size, prot, flags, -1, 0);
    if (result == linux.MAP_FAILED) {
        // Fall back to regular mapping with madvise hint
        return mapWithHugePageHint(size, huge_page_size);
    }

    return @ptrFromInt(result);
}

fn mapWithHugePageHint(size: usize, huge_page_size: usize) ?[*]u8 {
    const ptr = mapMemory(size, huge_page_size) orelse return null;

    // Use madvise to request transparent huge pages
    _ = linux.madvise(ptr, size, linux.MADV.HUGEPAGE);

    return ptr;
}

pub fn hugePageAvailable(huge_page_size: usize) bool {
    // Check /sys/kernel/mm/hugepages/hugepages-*/nr_hugepages
    // For simplicity, try to allocate and see if it works
    if (huge_page_size == config.HUGE_PAGE_2MB) {
        // Check if transparent huge pages are enabled
        const file = std.fs.openFileAbsolute(
            "/sys/kernel/mm/transparent_hugepage/enabled",
            .{},
        ) catch return false;
        defer file.close();

        var buf: [64]u8 = undefined;
        const bytes_read = file.read(&buf) catch return false;
        const content = buf[0..bytes_read];

        // Check if [always] or [madvise] is set
        return std.mem.indexOf(u8, content, "[always]") != null or
            std.mem.indexOf(u8, content, "[madvise]") != null;
    }

    return false;
}

// ============= NUMA Support =============

pub fn numaNodeCount() usize {
    // Read from /sys/devices/system/node/
    var count: usize = 0;

    var dir = std.fs.openDirAbsolute("/sys/devices/system/node", .{ .iterate = true }) catch {
        return 1;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, "node")) {
            count += 1;
        }
    }

    return if (count > 0) count else 1;
}

pub fn numaCurrentNode() u8 {
    // Use getcpu syscall
    var cpu: u32 = 0;
    var node: u32 = 0;

    const result = linux.syscall(.getcpu, .{ @intFromPtr(&cpu), @intFromPtr(&node), @as(usize, 0) });
    if (result == 0) {
        return @truncate(node);
    }

    return 0;
}

pub fn mapOnNode(size: usize, alignment: usize, node: u8) ?[*]u8 {
    // First, map the memory
    const ptr = mapMemory(size, alignment) orelse return null;

    // Then bind it to the specified node using mbind
    if (!numaBindMemory(ptr, size, node)) {
        // Binding failed, but allocation succeeded - still usable
    }

    return ptr;
}

pub fn numaNodeInfo(node: u8) ?@import("../platform.zig").NumaNode {
    // Read from /sys/devices/system/node/nodeN/meminfo
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/sys/devices/system/node/node{d}/meminfo", .{node}) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const bytes_read = file.read(&buf) catch return null;
    const content = buf[0..bytes_read];

    var total_bytes: u64 = 0;
    var free_bytes: u64 = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "MemTotal:")) |_| {
            total_bytes = parseMemValue(line);
        } else if (std.mem.indexOf(u8, line, "MemFree:")) |_| {
            free_bytes = parseMemValue(line);
        }
    }

    // Count CPUs on this node
    var cpu_count: u16 = 0;
    var cpu_path_buf: [64]u8 = undefined;
    const cpu_path = std.fmt.bufPrint(&cpu_path_buf, "/sys/devices/system/node/node{d}/cpulist", .{node}) catch "";

    if (cpu_path.len > 0) {
        const cpu_file = std.fs.openFileAbsolute(cpu_path, .{}) catch null;
        if (cpu_file) |f| {
            defer f.close();
            var cpu_buf: [256]u8 = undefined;
            const cpu_bytes = f.read(&cpu_buf) catch 0;
            if (cpu_bytes > 0) {
                cpu_count = countCpusInList(cpu_buf[0..cpu_bytes]);
            }
        }
    }

    return .{
        .id = node,
        .cpu_count = cpu_count,
        .memory_bytes = total_bytes,
        .free_bytes = free_bytes,
    };
}

fn parseMemValue(line: []const u8) u64 {
    // Parse "Node X MemTotal: 12345 kB"
    var iter = std.mem.splitScalar(u8, line, ':');
    _ = iter.next(); // Skip label
    const value_part = iter.next() orelse return 0;

    var value_iter = std.mem.tokenizeScalar(u8, value_part, ' ');
    const value_str = value_iter.next() orelse return 0;

    const value = std.fmt.parseInt(u64, value_str, 10) catch return 0;
    return value * 1024; // Convert from kB to bytes
}

fn countCpusInList(list: []const u8) u16 {
    // Parse CPU list format: "0-3,5,7-9"
    var count: u16 = 0;
    var iter = std.mem.tokenizeScalar(u8, std.mem.trim(u8, list, &[_]u8{ '\n', ' ' }), ',');

    while (iter.next()) |part| {
        if (std.mem.indexOf(u8, part, "-")) |dash_pos| {
            const start = std.fmt.parseInt(u16, part[0..dash_pos], 10) catch continue;
            const end = std.fmt.parseInt(u16, part[dash_pos + 1 ..], 10) catch continue;
            count += (end - start + 1);
        } else {
            count += 1;
        }
    }

    return count;
}

pub fn numaBindMemory(ptr: [*]u8, size: usize, node: u8) bool {
    // Use mbind syscall
    // MPOL_BIND = 2
    const MPOL_BIND: c_int = 2;

    // Create node mask
    var nodemask: [8]usize = [_]usize{0} ** 8;
    nodemask[node / 64] = @as(usize, 1) << @intCast(node % 64);

    const result = linux.syscall(.mbind, .{
        @intFromPtr(ptr),
        size,
        @as(usize, @intCast(MPOL_BIND)),
        @intFromPtr(&nodemask),
        @as(usize, 64), // maxnode
        @as(usize, 0), // flags
    });

    return result == 0;
}

// ============= Thread Support =============

pub fn getThreadId() usize {
    return @intCast(linux.gettid());
}

// ============= Thread Exit Handler =============

const c = @cImport({
    @cInclude("pthread.h");
});

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

test "linux map/unmap" {
    if (config.current_platform != .linux) return error.SkipZigTest;

    const ptr = mapMemory(4096, 4096) orelse return error.MapFailed;
    ptr[0] = 42;
    unmapMemory(ptr, 4096);
}

test "linux aligned map" {
    if (config.current_platform != .linux) return error.SkipZigTest;

    const ptr = mapMemory(config.SEGMENT_SIZE, config.SEGMENT_ALIGNMENT) orelse return error.MapFailed;
    defer unmapMemory(ptr, config.SEGMENT_SIZE);

    const addr = @intFromPtr(ptr);
    try std.testing.expectEqual(@as(usize, 0), addr % config.SEGMENT_ALIGNMENT);
}

test "linux numa node count" {
    if (config.current_platform != .linux) return error.SkipZigTest;

    const count = numaNodeCount();
    try std.testing.expect(count >= 1);
}

test "linux thread id" {
    if (config.current_platform != .linux) return error.SkipZigTest;

    const tid = getThreadId();
    try std.testing.expect(tid > 0);
}
