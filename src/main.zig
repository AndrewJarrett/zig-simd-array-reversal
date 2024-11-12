const std = @import("std");
const Timer = std.time.Timer;

pub fn main() !void {
    std.debug.print("Use 'zig test src/main.zig' in order to run tests.\n\n", .{});
    std.debug.print("Now performing basic benchmarks... Please build using 'zig build --release=fast'.\n\n", .{});

    const tests = 1000;

    //
    // Basic reversal
    std.debug.print("Test basic reversal with 1,000,000 elements...\n", .{});

    const size: u32 = 1e6;
    const arr: [size]u32 = generateArr(size);
    var output: []u32 = undefined;

    var totalTime: u64 = 0;
    var timer = try Timer.start();
    for (0..tests) |_| {
        timer.reset();
        output = basicReversal(&arr);
        totalTime += timer.read();

        //std.debug.print("Test {d}: {d} ns\n", .{ t, testTime });
    }
    std.debug.print("Total time: {d} ms\n", .{@divTrunc(totalTime, 1000000)});

    //
    // Xor Reversal
    std.debug.print("Test xor reversal with 1,000,000 elements...\n", .{});

    totalTime = 0;
    for (0..tests) |_| {
        timer.reset();
        output = xorReversal(&arr);
        totalTime += timer.read();

        //std.debug.print("Test {d}: {d} ns\n", .{ t, testTime });
    }
    std.debug.print("Total time: {d} ms\n", .{@divTrunc(totalTime, 1000000)});

    //
    // SIMD Reversal
    std.debug.print("Test SIMD reversal with 1,000,000 elements...\n", .{});

    totalTime = 0;
    for (0..tests) |_| {
        timer.reset();
        output = simdReversal(&arr);
        totalTime += timer.read();

        //std.debug.print("Test {d}: {d} ns\n", .{ t, testTime });
    }
    std.debug.print("Total time: {d} ms\n", .{@divTrunc(totalTime, 1000000)});
}

pub fn basicReversal(arr: []const u32) []u32 {
    // Since we have constant slice, we need to copy the array to an
    // allocated place in memory to be able to manipulate it
    var reversed: []u32 = std.heap.page_allocator.dupe(u32, arr) catch unreachable;

    for (0..reversed.len / 2) |i| {
        const j = reversed.len - 1 - i;
        const temp = reversed[i];
        reversed[i] = reversed[j];
        reversed[j] = temp;
    }

    return reversed;
}

pub fn xorReversal(arr: []const u32) []u32 {
    var reversed: []u32 = std.heap.page_allocator.dupe(u32, arr) catch unreachable;

    for (0..reversed.len / 2) |i| {
        const j = reversed.len - 1 - i;
        reversed[i] ^= reversed[j]; // i.e. 0010 (2) xor swap with 0001 (1) -> 0011 (3)
        reversed[j] ^= reversed[i]; // 0001 ^ 0011 -> 0010 (2)
        reversed[i] ^= reversed[j]; // 0010 ^ 0011 -> 0001 (1)
    }

    return reversed;
}

pub fn simdReversal(arr: []const u32) []u32 {
    //const suggestedSize: u32 = std.simd.suggestVectorLength(u32) orelse 4;
    //var simdSize: u32 = suggestedSize;

    var reversed: []u32 = std.heap.page_allocator.dupe(u32, arr) catch unreachable;

    // Process in compile time known chunk sizes
    const chunks: []const u32 = &.{ 4, 2, 1 };
    const totalSize: u32 = @intCast(reversed.len);

    // Keep trying simd with chunk sizes starting at the suggested size and
    // dividing in half until we can't evenly divide anymore (i.e. simdSize == 2)
    var i: u32 = 0;
    inline for (chunks) |simdSize| {
        const loops = (totalSize / 2) / simdSize;

        // Process total possible full chunks of each size (8 -> 4 -> 2 -> 1)
        while ((i / simdSize) < loops) : (i += simdSize) {
            const j = totalSize - i - simdSize;

            // Create a "reverse mask" by subtracting from the simdSize an increasing vector from 0..simdSize
            const reverseMask = @as(@Vector(simdSize, u32), @splat(simdSize - 1)) - std.simd.iota(u32, simdSize); // i.e. {7 7 7 ...} - {0 1 2 ...} = {7 6 5 ...}

            // Get the lower and upper chunks
            const lower: @Vector(simdSize, u32) = reversed[i..][0..simdSize].*;
            const upper: @Vector(simdSize, u32) = reversed[j..][0..simdSize].*;

            // Shuffle the bits by using the reverse mask
            const lowerReverse = @shuffle(u32, lower, undefined, reverseMask);
            const upperReverse = @shuffle(u32, upper, undefined, reverseMask);

            // Swap the chunks - cast to an array and get the pointer
            // then we memcpy to the reversed slice memory region
            @memcpy(reversed[i..][0..simdSize], &@as([simdSize]u32, upperReverse));
            @memcpy(reversed[j..][0..simdSize], &@as([simdSize]u32, lowerReverse));
        }
    }

    return reversed;
}

test "basic test for all 3" {
    const arr: []const u32 = &.{ 1, 2, 3, 4, 5 };
    const expected: []const u32 = &.{ 5, 4, 3, 2, 1 };
    try std.testing.expectEqualSlices(u32, expected, basicReversal(arr));
    try std.testing.expectEqualSlices(u32, expected, xorReversal(arr));
    try std.testing.expectEqualSlices(u32, expected, simdReversal(arr));
}

test "test 3 elements using simd" {
    const size: u32 = 3;
    const arr: [size]u32 = comptime generateArr(size);
    const expected: [size]u32 = comptime generateExpected(size);
    try std.testing.expectEqualSlices(u32, &expected, simdReversal(&arr));
}

test "test 5 elements using simd" {
    const size: u32 = 5;
    const arr: [size]u32 = comptime generateArr(size);
    const expected: [size]u32 = comptime generateExpected(size);
    try std.testing.expectEqualSlices(u32, &expected, simdReversal(&arr));
}

test "test 40 elements" {
    const size: u32 = 40;
    const arr: [size]u32 = generateArr(size);
    const expected: [size]u32 = generateExpected(size);
    try std.testing.expectEqualSlices(u32, &expected, simdReversal(&arr));
}

test "test 100 elements" {
    const size: u32 = 100;
    const arr: [size]u32 = generateArr(size);
    const expected: [size]u32 = generateExpected(size);
    try std.testing.expectEqualSlices(u32, &expected, simdReversal(&arr));
}

test "test 1,000,000 elements" {
    const size: u32 = 1e6;
    const arr: [size]u32 = generateArr(size);
    const expected: [size]u32 = generateExpected(size);
    try std.testing.expectEqualSlices(u32, &expected, simdReversal(&arr));
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
