# Apex

A high-performance memory allocator written in Zig. Because sometimes you want to understand what's actually happening when you ask for 32 bytes.

## What Is This?

Apex is a slab-based allocator inspired by jemalloc and mimalloc. It's designed for low fragmentation and high throughput, with a clean implementation you can actually read.

The architecture:
- 2MB segments from the OS
- 64KB pages within segments
- Size-class slab allocation for small objects
- Direct mmap for huge allocations
- Thread caching for fast-path allocation
- Arena allocator for bulk allocation patterns

## Features

- 17 size classes from 8 bytes to 2KB
- Thread-local caching (no locks on fast path)
- Arena allocator for scratch memory
- Statistics tracking for debugging
- Zero external dependencies (Zig stdlib only)

## Quick Start

```bash
# Build
zig build

# Run tests (61 of them)
zig build test

# Run benchmarks
zig build bench
```

## Usage

```zig
const apex = @import("apex");

// Use the global heap
const ptr = apex.heap.alloc(64) orelse return error.OutOfMemory;
defer apex.heap.free(ptr);

// Or create your own heap
var heap = apex.heap.Heap.init();
heap.initAllocators();
const p = heap.alloc(128);
heap.free(p);

// Arena for bulk allocations
var arena = apex.arena.Arena.init();
defer arena.deinit();

const a = arena.alloc(100);
const b = arena.allocSlice(u32, 50);
arena.reset(); // Free everything at once
```

## Benchmarks

```
small alloc (32B)           762K ops/sec    1311 ns/op
medium alloc (256B)        1764K ops/sec     566 ns/op
large alloc (4KB)          6563K ops/sec     152 ns/op
arena alloc (64B)        141884K ops/sec       7 ns/op
```

Arena is fast because it's just bumping a pointer. The heap has more overhead but handles real-world allocation patterns better.

## Architecture

```
Heap
 +-- Slab Allocator (< 2KB)
 |    +-- Size Class Pools
 |         +-- Pages (64KB)
 |              +-- Free lists
 +-- Large Allocator (2KB - 2MB)
 |    +-- Segment Pages
 +-- Huge Allocator (> 2MB)
      +-- Direct mmap
```

Segments are 2MB chunks from the OS, aligned for efficient pointer-to-metadata lookup. Each segment contains 32 pages of 64KB each.

## Philosophy

1. Predictable performance beats theoretical optimums
2. Readable code beats clever tricks
3. Good defaults beat configuration options
4. Testing proves correctness

## Limitations

- No memory profiler integration (yet)
- Windows support is basic (works, not optimized)
- No NUMA awareness
- Thread cache cleanup relies on explicit flush

## License

MIT

---

Katie
