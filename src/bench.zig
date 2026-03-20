// Apex benchmarks
//
// Performance measurement for the allocator.

const std = @import("std");
const apex = @import("apex");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Apex Allocator Benchmarks\n", .{});
    try stdout.print("=========================\n\n", .{});

    // Stub - actual benchmarks will be added when allocator is implemented
    try stdout.print("Page size: {} KB\n", .{apex.PAGE_SIZE / 1024});
    try stdout.print("Segment size: {} MB\n", .{apex.SEGMENT_SIZE / (1024 * 1024)});
    try stdout.print("Size classes: {}\n", .{apex.SIZE_CLASSES.len});

    try stdout.print("\nBenchmarks not yet implemented.\n", .{});
}
