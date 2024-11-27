const std = @import("std");
const config = @import("config");
const eql = std.mem.eql;

const Timer = std.time.Timer;

pub const alg = enum {
    std,
    basic,
    xor,
    simd,
};

pub fn main() !void {
    std.debug.print("Use 'zig test' in order to run tests. In order to build and benchmark, run 'zig build -Dtimer run-std run-basic run-xor run-simd' to build one executable for each algorithm and run each.\n\n", .{});
    std.debug.print("If you want to test using an external tool like 'hyperfine', then you can just build using 'zig build' and pass each exe as a parameter to hyperfine to benchmark and compare.\n\n", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const tests = 1000;
    const size: u32 = 1e6;
    const arr: [size]u32 = generateArr(size);
    var output: []u32 = undefined;

    // Copy the const array onto the heap to more accurately measure the algorithms
    var original = arena.allocator().dupe(u32, &arr) catch unreachable;

    //const func = switch (std.meta.stringToEnum(alg, config.algorithm)) {
    const func = comptime switch (std.meta.stringToEnum(alg, config.algorithm) orelse .std) {
        .std => stdReversal,
        .basic => basicReversal,
        .xor => xorReversal,
        .simd => simdReversal,
    };

    std.debug.print("Now performing basic benchmarks... Please make sure you build using 'zig build --release=fast'.\n\n", .{});

    std.debug.print("Test {s} reversal with {d} elements {d} times...\n", .{ config.algorithm, size, tests });

    if (config.timer) {
        var end: u64 = 0;
        var totalTime: u64 = 0;
        var minTime: u64 = 0;

        var timer: Timer = try Timer.start();
        for (0..tests) |_| {
            timer.reset();
            output = func(original);
            end = timer.read();

            if (end < minTime or minTime == 0) {
                minTime = end;
            }
            totalTime += end;

            original = arena.allocator().dupe(u32, &arr) catch unreachable;
        }
        std.debug.print("Minimum time: {d} ns\n", .{minTime});
        std.debug.print("Total time: {d} ms\n", .{@divTrunc(totalTime, 1000000)});
    } else {
        for (0..tests) |_| {
            output = func(original);
            original = arena.allocator().dupe(u32, &arr) catch unreachable;
        }
    }
}

pub fn stdReversal(reversed: []u32) []u32 {
    std.mem.reverse(u32, reversed);
    return reversed;
}

pub fn basicReversal(reversed: []u32) []u32 {
    for (0..reversed.len / 2) |i| {
        const j = reversed.len - 1 - i;
        const temp = reversed[i];
        reversed[i] = reversed[j];
        reversed[j] = temp;
    }

    return reversed;
}

pub fn xorReversal(reversed: []u32) []u32 {
    for (0..reversed.len / 2) |i| {
        const j = reversed.len - 1 - i;
        reversed[i] ^= reversed[j]; // i.e. 0010 (2) xor swap with 0001 (1) -> 0011 (3)
        reversed[j] ^= reversed[i]; // 0001 ^ 0011 -> 0010 (2)
        reversed[i] ^= reversed[j]; // 0010 ^ 0011 -> 0001 (1)
    }

    return reversed;
}

pub fn simdReversal(reversed: []u32) []u32 {
    // Process in compile time known chunk sizes
    const chunks: []const u32 = &.{ 4, 2, 1 };
    const totalSize: u32 = @intCast(reversed.len);

    // Keep trying simd with chunk sizes starting at the suggested size and
    // dividing in half until we can't evenly divide anymore (i.e. simdSize == 2)
    var i: u32 = 0;
    inline for (chunks) |simdSize| {
        const loops = (totalSize / 2) / simdSize;

        // Create a "reverse mask" by subtracting from the simdSize an increasing vector from 0..simdSize
        const reverseMask = @as(@Vector(simdSize, u32), @splat(simdSize - 1)) - std.simd.iota(u32, simdSize); // i.e. {7 7 7 ...} - {0 1 2 ...} = {7 6 5 ...}

        // Process total possible full chunks of each size (8 -> 4 -> 2 -> 1)
        while ((i / simdSize) < loops) : (i += simdSize) {
            const j = totalSize - i - simdSize;

            // Get the lower and upper chunks
            var lower: @Vector(simdSize, u32) = reversed[i..][0..simdSize].*;
            var upper: @Vector(simdSize, u32) = reversed[j..][0..simdSize].*;

            // Shuffle the bits by using the reverse mask
            lower = @shuffle(u32, lower, undefined, reverseMask);
            upper = @shuffle(u32, upper, undefined, reverseMask);

            // Swap the chunks - cast to an array and get the pointer
            // then we memcpy to the reversed slice memory region
            //switch (simdSize) {
            //    //8 => {
            //    //    mm256_storeu_si256(&reversed[i..(i + simdSize)], @bitCast(upperReverse));
            //    //    mm256_storeu_si256(&reversed[j..(j + simdSize)], @bitCast(lowerReverse));
            //    //},
            //    4 => {
            //        asm volatile (
            //            \\ vmovdqu %[ptr], %[x]
            //            :
            //            : [ptr] "m" (&reversed[i]),
            //              [x] "x" (upper),
            //        );
            //        asm volatile (
            //            \\ vmovdqu %[ptr], %[x]
            //            :
            //            : [ptr] "m" (&reversed[j]),
            //              [x] "x" (lower),
            //        );
            //        //mm256_storeu_si128(&reversed[i], upper);
            //        //mm256_storeu_si128(&reversed[j], lower);
            //    },
            //    2 => {
            //
            //    },
            //    else => {
            @memcpy(reversed[i..(i + simdSize)], &@as([simdSize]u32, upper));
            @memcpy(reversed[j..(j + simdSize)], &@as([simdSize]u32, lower));
            //    },
            //}
        }
    }

    return reversed;
}

const vu8x16 = @Vector(16, u8);
const vu16x8 = @Vector(8, u16);
const vu32x4 = @Vector(4, u32);
const vu64x2 = @Vector(2, u64);

const mm128i = packed union {
    vu8x16: vu8x16,
    vu16x8: vu16x8,
    vu32x4: vu32x4,
    vu64x2: vu64x2,
};

const vu8x32 = @Vector(32, u8);
const vu16x16 = @Vector(16, u16);
const vu32x8 = @Vector(8, u32);
const vu64x4 = @Vector(4, u64);
const vu128x2 = @Vector(2, u128);

const mm256i = packed union {
    vu8x32: vu8x32,
    vu16x16: vu16x16,
    vu32x8: vu32x8,
    vu64x4: vu64x4,
    vu128x2: vu128x2,
};

fn mm256_storeu_si256(a: *mm256i, b: mm256i) void {
    asm volatile (
        \\ vmovdqu %[ptr], %[x]
        :
        : [ptr] "m" (a),
          [x] "x" (b),
        : "memory"
    );
}

fn mm256_storeu_si128(a: *mm128i, b: mm128i) void {
    asm volatile (
        \\ vmovdqu %[ptr], %[x]
        :
        : [ptr] "m" (a),
          [x] "x" (b),
    );
}

//test "mm256_storeu_si256" {
//    const size = 8;
//    const data: vu32x8 = generateArr(size);
//    var buffer: [size]u32 = @as(@Vector(size, u32), @splat(0));
//
//    mm256_storeu_si256(&buffer[0], data);
//
//    try std.testing.expectEqualSlices(u32, &@as([size]u32, data), buffer[0..size]);
//}

test "mm256_storeu_si128" {
    const size = 4;
    const data = mm128i{ .vu32x4 = generateArr(size) };
    const buffer = mm128i{ .vu32x4 = @splat(0) };

    const ptr = try std.testing.allocator.create(mm128i);
    defer std.testing.allocator.destroy(ptr);
    ptr.* = @bitCast(buffer);
    mm256_storeu_si128(ptr, @bitCast(data));

    try std.testing.expectEqualSlices(u32, &@as([size]u32, data.vu32x4), &@as([size]u32, buffer.vu32x4));
}

test "basic test for all 3" {
    const arr: []const u32 = &.{ 1, 2, 3, 4, 5 };
    const expected: []const u32 = &.{ 5, 4, 3, 2, 1 };

    const one = std.testing.allocator.dupe(u32, arr) catch unreachable;
    const two = std.testing.allocator.dupe(u32, arr) catch unreachable;
    const three = std.testing.allocator.dupe(u32, arr) catch unreachable;
    defer std.testing.allocator.free(one);
    defer std.testing.allocator.free(two);
    defer std.testing.allocator.free(three);

    try std.testing.expectEqualSlices(u32, expected, basicReversal(one));
    try std.testing.expectEqualSlices(u32, expected, xorReversal(two));
    try std.testing.expectEqualSlices(u32, expected, simdReversal(three));
}

test "test 3 elements using simd" {
    const size: u32 = 3;
    const arr: [size]u32 = comptime generateArr(size);
    const expected: [size]u32 = comptime generateExpected(size);

    const original = std.testing.allocator.dupe(u32, &arr) catch unreachable;
    defer std.testing.allocator.free(original);

    try std.testing.expectEqualSlices(u32, &expected, simdReversal(original));
}

test "test 5 elements using simd" {
    const size: u32 = 5;
    const arr: [size]u32 = comptime generateArr(size);
    const expected: [size]u32 = comptime generateExpected(size);

    const original = std.testing.allocator.dupe(u32, &arr) catch unreachable;
    defer std.testing.allocator.free(original);

    try std.testing.expectEqualSlices(u32, &expected, simdReversal(original));
}

test "test 40 elements" {
    const size: u32 = 40;
    const arr: [size]u32 = generateArr(size);
    const expected: [size]u32 = generateExpected(size);

    const original = std.testing.allocator.dupe(u32, &arr) catch unreachable;
    defer std.testing.allocator.free(original);

    try std.testing.expectEqualSlices(u32, &expected, simdReversal(original));
}

test "test 100 elements" {
    const size: u32 = 100;
    const arr: [size]u32 = generateArr(size);
    const expected: [size]u32 = generateExpected(size);

    const original = std.testing.allocator.dupe(u32, &arr) catch unreachable;
    defer std.testing.allocator.free(original);

    try std.testing.expectEqualSlices(u32, &expected, simdReversal(original));
}

test "test 1,000,000 elements" {
    const size: u32 = 1e6;
    const arr: [size]u32 = generateArr(size);
    const expected: [size]u32 = generateExpected(size);

    const original = std.testing.allocator.dupe(u32, &arr) catch unreachable;
    defer std.testing.allocator.free(original);

    try std.testing.expectEqualSlices(u32, &expected, simdReversal(original));
}

fn generateArr(comptime size: u32) [size]u32 {
    var arr: [size]u32 = undefined;

    for (0..size) |i| {
        arr[i] = @as(u32, @intCast(i)) + 1;
    }

    return arr;
}

fn generateExpected(comptime size: u32) [size]u32 {
    var expected: [size]u32 = undefined;

    for (0..size) |i| {
        expected[i] = size - @as(u32, @intCast(i));
    }

    return expected;
}
