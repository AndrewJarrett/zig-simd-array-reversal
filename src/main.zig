const std = @import("std");
const config = @import("config");

const Timer = std.time.Timer;

pub const alg = enum {
    std,
    basic,
    basic_inline,
    xor,
    xor_inline,
    simd,
    simd_bswap_only,
    simd_std_reverse_order,
};

pub fn main() !void {
    std.debug.print("Use 'zig test' in order to run tests. In order to build and benchmark, run 'zig build -Dtimer run-std run-basic run-xor run-simd...' to build one executable for each algorithm and run each.\n\n", .{});
    std.debug.print("If you want to test using an external tool like 'hyperfine', then you can just build using 'zig build' and pass each exe as a parameter to hyperfine to benchmark and compare.\n\n", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const tests = 1000;
    const size: u32 = 1e6;
    const arr: [size]u8 = generateArr(u8, size);
    var output: []u8 = undefined;

    // Copy the const array onto the heap to more accurately measure the algorithms
    var original = arena.allocator().dupe(u8, &arr) catch unreachable;

    const func = comptime switch (std.meta.stringToEnum(alg, config.algorithm) orelse .std) {
        .std => zReverse(u8, size).standard,
        .basic => zReverse(u8, size).basic,
        .basic_inline => zReverse(u8, size).basic_inline,
        .xor => zReverse(u8, size).xor,
        .xor_inline => zReverse(u8, size).xor_inline,
        .simd => zReverse(u8, size).simd,
        .simd_bswap_only => zReverse(u8, size).simd_bswap_only,
        .simd_std_reverse_order => zReverse(u8, size).simd_std_reverse_order,
    };

    std.debug.print("Testing {s} reversal with {d} elements {d} times...\n", .{ config.algorithm, size, tests });

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

            original = arena.allocator().dupe(u8, &arr) catch unreachable;
        }
        std.debug.print("Minimum time: {d} ns\n", .{minTime});
        std.debug.print("Total time: {d} ms\n", .{@divTrunc(totalTime, 1000000)});
    } else {
        for (0..tests) |_| {
            output = func(original);
            original = arena.allocator().dupe(u8, &arr) catch unreachable;
        }
    }
}

pub fn zReverse(comptime T: anytype, comptime size: usize) type {
    return struct {
        const self = @This();
        const bits = @bitSizeOf(T);
        const bytes = @sizeOf(T);

        pub fn standard(reversed: []T) []T {
            std.mem.reverse(T, reversed);
            return reversed;
        }

        pub fn basic(reversed: []T) []T {
            for (0..(size / 2)) |i| {
                const j = size - 1 - i;
                const temp = reversed[i];
                reversed[i] = reversed[j];
                reversed[j] = temp;
            }

            return reversed;
        }

        pub inline fn basic_inline(reversed: []T) []T {
            for (0..(size / 2)) |i| {
                const j = size - 1 - i;
                const temp = reversed[i];
                reversed[i] = reversed[j];
                reversed[j] = temp;
            }

            return reversed;
        }

        pub fn xor(reversed: []T) []T {
            for (0..(size / 2)) |i| {
                const j = size - 1 - i;
                reversed[i] ^= reversed[j]; // i.e. 0010 (2) xor swap with 0001 (1) -> 0011 (3)
                reversed[j] ^= reversed[i]; // 0001 ^ 0011 -> 0010 (2)
                reversed[i] ^= reversed[j]; // 0010 ^ 0011 -> 0001 (1)
            }

            return reversed;
        }

        pub inline fn xor_inline(reversed: []T) []T {
            for (0..(size / 2)) |i| {
                const j = size - 1 - i;
                reversed[i] ^= reversed[j]; // i.e. 0010 (2) xor swap with 0001 (1) -> 0011 (3)
                reversed[j] ^= reversed[i]; // 0001 ^ 0011 -> 0010 (2)
                reversed[i] ^= reversed[j]; // 0010 ^ 0011 -> 0001 (1)
            }

            return reversed;
        }

        pub fn simd(reversed: []T) []T {
            if (@mod(@bitSizeOf(T), 8) != 0) {
                @compileError("Please specify a type that is byte-aligned.");
            }

            if (@typeInfo(T) != .Int or @typeInfo(T).Int.signedness != .unsigned) {
                @compileError("Reversal requires an unsigned integer array, found " ++ @typeName(T));
            }

            switch (T) {
                // Special SIMD optimization for reversing single byte unsigned arrays
                inline u8 => {
                    comptime var vecSize: usize = std.simd.suggestVectorLength(T) orelse 1;

                    const bufSize = comptime std.math.log2_int(@TypeOf(vecSize), vecSize) + 1;
                    comptime var buffer: [bufSize]usize = undefined;

                    comptime var idx = 0;
                    inline while (vecSize >= 1) : ({
                        idx += 1;
                        vecSize /= 2;
                    }) {
                        buffer[idx] = vecSize;
                    }
                    const chunks: []const usize = buffer[0..bufSize];

                    //comptime var i: usize = 0;
                    var i: usize = 0;
                    inline for (chunks) |simdSize| {
                        const loops = (size / 2) / simdSize;

                        const reverseMask = @as(@Vector(simdSize, u8), @splat(simdSize - 1)) - std.simd.iota(u8, simdSize); // i.e. {7 7 7 ...} - {0 1 2 ...} = {7 6 5 ...}

                        while ((i / simdSize) < loops) : (i += simdSize) {
                            const j = size - i - simdSize;
                            var lowerSlice: []u8 = reversed[i..(i + simdSize)];
                            var upperSlice: []u8 = reversed[j..(j + simdSize)];
                            switch (simdSize) {
                                // Shuffle for 256 and 128 bit width simdSize
                                inline 32, 16 => {
                                    var lower: @Vector(simdSize, u8) = lowerSlice[0..simdSize].*;
                                    var upper: @Vector(simdSize, u8) = upperSlice[0..simdSize].*;

                                    lower = @shuffle(u8, lower, undefined, reverseMask);
                                    upper = @shuffle(u8, upper, undefined, reverseMask);

                                    @memcpy(lowerSlice, &@as([simdSize]u8, upper));
                                    @memcpy(upperSlice, &@as([simdSize]u8, lower));
                                },
                                // Bswap / movbe / rot for 64, 32, and 16 bit register sizes
                                inline 8, 4, 2 => {
                                    const RegType = std.meta.Int(.unsigned, @intCast(simdSize * bits));
                                    const lower: @Vector(1, RegType) = @bitCast(lowerSlice[0..simdSize].*);
                                    const upper: @Vector(1, RegType) = @bitCast(upperSlice[0..simdSize].*);

                                    @memcpy(lowerSlice, &@as([simdSize]u8, @bitCast(@byteSwap(upper))));
                                    @memcpy(upperSlice, &@as([simdSize]u8, @bitCast(@byteSwap(lower))));
                                },
                                // Naive reversal for singular byte elements
                                inline 1 => {
                                    const temp = reversed[i];
                                    reversed[i] = reversed[j];
                                    reversed[j] = temp;
                                },
                                inline else => @compileError("Unknown register size is not handled for type " ++ @TypeOf(T)),
                            }
                        }
                    }
                },
                inline else => {
                    // Fall back to std reverse algorithm for other arrays
                    std.mem.reverse(T, reversed);
                },
            }

            return reversed;
        }

        pub fn simd_bswap_only(reversed: []T) []T {
            if (@mod(@bitSizeOf(T), 8) != 0) {
                @compileError("Please specify a type that is byte-aligned.");
            }

            if (@typeInfo(T) != .Int or @typeInfo(T).Int.signedness != .unsigned) {
                @compileError("Reversal requires an unsigned integer array, found " ++ @typeName(T));
            }

            switch (T) {
                // Special SIMD optimization for reversing single byte unsigned arrays
                inline u8 => {
                    comptime var vecSize: usize = std.simd.suggestVectorLength(T) orelse 1;

                    const bufSize = comptime std.math.log2_int(@TypeOf(vecSize), vecSize) + 1;
                    comptime var buffer: [bufSize]usize = undefined;

                    comptime var idx = 0;
                    inline while (vecSize >= 1) : ({
                        idx += 1;
                        vecSize /= 2;
                    }) {
                        buffer[idx] = vecSize;
                    }
                    const chunks: []const usize = buffer[0..bufSize];

                    //comptime var i: usize = 0;
                    var i: usize = 0;
                    inline for (chunks) |simdSize| {
                        const loops = (size / 2) / simdSize;

                        while ((i / simdSize) < loops) : (i += simdSize) {
                            const j = size - i - simdSize;
                            var lowerSlice: []u8 = reversed[i..(i + simdSize)];
                            var upperSlice: []u8 = reversed[j..(j + simdSize)];
                            switch (simdSize) {
                                // Bswap / movbe / rot for 256, 128, 64, 32, and 16 bit register sizes
                                inline 32, 16, 8, 4, 2 => {
                                    const RegType = std.meta.Int(.unsigned, @intCast(simdSize * bits));
                                    const lower: @Vector(1, RegType) = @bitCast(lowerSlice[0..simdSize].*);
                                    const upper: @Vector(1, RegType) = @bitCast(upperSlice[0..simdSize].*);

                                    @memcpy(lowerSlice, &@as([simdSize]u8, @bitCast(@byteSwap(upper))));
                                    @memcpy(upperSlice, &@as([simdSize]u8, @bitCast(@byteSwap(lower))));
                                },
                                // Naive reversal for singular byte elements
                                inline 1 => {
                                    const temp = reversed[i];
                                    reversed[i] = reversed[j];
                                    reversed[j] = temp;
                                },
                                inline else => @compileError("Unknown register size is not handled for type " ++ @TypeOf(T)),
                            }
                        }
                    }
                },
                inline else => {
                    // Fall back to std reverse algorithm for other arrays
                    std.mem.reverse(T, reversed);
                },
            }

            return reversed;
        }

        pub fn simd_std_reverse_order(reversed: []T) []T {
            if (@mod(@bitSizeOf(T), 8) != 0) {
                @compileError("Please specify a type that is byte-aligned.");
            }

            if (@typeInfo(T) != .Int or @typeInfo(T).Int.signedness != .unsigned) {
                @compileError("Reversal requires an unsigned integer array, found " ++ @typeName(T));
            }

            switch (T) {
                // Special SIMD optimization for reversing single byte unsigned arrays
                inline u8 => {
                    comptime var vecSize: usize = std.simd.suggestVectorLength(T) orelse 1;

                    const bufSize = comptime std.math.log2_int(@TypeOf(vecSize), vecSize) + 1;
                    comptime var buffer: [bufSize]usize = undefined;

                    comptime var idx = 0;
                    inline while (vecSize >= 1) : ({
                        idx += 1;
                        vecSize /= 2;
                    }) {
                        buffer[idx] = vecSize;
                    }
                    const chunks: []const usize = buffer[0..bufSize];

                    var i: usize = 0;
                    inline for (chunks) |simdSize| {
                        const loops = (size / 2) / simdSize;

                        while ((i / simdSize) < loops) : (i += simdSize) {
                            const j = size - i - simdSize;
                            var lowerSlice: []u8 = reversed[i..(i + simdSize)];
                            var upperSlice: []u8 = reversed[j..(j + simdSize)];
                            switch (simdSize) {
                                // Bswap / movbe / rot for 256, 128, 64, 32, and 16 bit register sizes
                                inline 32, 16, 8, 4, 2 => {
                                    const RegType = std.meta.Int(.unsigned, @intCast(simdSize * bits));
                                    const lower: @Vector(1, RegType) = @bitCast(lowerSlice[0..simdSize].*);
                                    const upper: @Vector(1, RegType) = @bitCast(upperSlice[0..simdSize].*);

                                    @memcpy(lowerSlice, &@as([simdSize]u8, @bitCast(std.simd.reverseOrder(upper))));
                                    @memcpy(upperSlice, &@as([simdSize]u8, @bitCast(std.simd.reverseOrder(lower))));
                                },
                                // Naive reversal for singular byte elements
                                inline 1 => {
                                    const temp = reversed[i];
                                    reversed[i] = reversed[j];
                                    reversed[j] = temp;
                                },
                                inline else => @compileError("Unknown register size is not handled for type " ++ @TypeOf(T)),
                            }
                        }
                    }
                },
                inline else => {
                    // Fall back to std reverse algorithm for other arrays
                    std.mem.reverse(T, reversed);
                },
            }

            return reversed;
        }
    };
}

test "basic test for all 7 algorithms" {
    const arr: []const u8 = &.{ 1, 2, 3, 4, 5 };
    const expected: []const u8 = &.{ 5, 4, 3, 2, 1 };

    const one = std.testing.allocator.dupe(u8, arr) catch unreachable;
    const two = std.testing.allocator.dupe(u8, arr) catch unreachable;
    const three = std.testing.allocator.dupe(u8, arr) catch unreachable;
    const four = std.testing.allocator.dupe(u8, arr) catch unreachable;
    const five = std.testing.allocator.dupe(u8, arr) catch unreachable;
    const six = std.testing.allocator.dupe(u8, arr) catch unreachable;
    const seven = std.testing.allocator.dupe(u8, arr) catch unreachable;
    defer std.testing.allocator.free(one);
    defer std.testing.allocator.free(two);
    defer std.testing.allocator.free(three);
    defer std.testing.allocator.free(four);
    defer std.testing.allocator.free(five);
    defer std.testing.allocator.free(six);
    defer std.testing.allocator.free(seven);

    try std.testing.expectEqualSlices(u8, expected, zReverse(u8, arr.len).basic(one));
    try std.testing.expectEqualSlices(u8, expected, zReverse(u8, arr.len).basic_inline(two));
    try std.testing.expectEqualSlices(u8, expected, zReverse(u8, arr.len).xor(three));
    try std.testing.expectEqualSlices(u8, expected, zReverse(u8, arr.len).xor_inline(four));
    try std.testing.expectEqualSlices(u8, expected, zReverse(u8, arr.len).simd(five));
    try std.testing.expectEqualSlices(u8, expected, zReverse(u8, arr.len).simd_bswap_only(six));
    try std.testing.expectEqualSlices(u8, expected, zReverse(u8, arr.len).simd(seven));
}

test "test 3 elements using simd" {
    const size: u32 = 3;
    const arr: [size]u8 = comptime generateArr(u8, size);
    const expected: [size]u8 = comptime generateExpected(u8, size);

    const original = std.testing.allocator.dupe(u8, &arr) catch unreachable;
    defer std.testing.allocator.free(original);

    try std.testing.expectEqualSlices(u8, &expected, zReverse(u8, size).simd(original));
}

test "test 5 elements using simd" {
    const size: u32 = 5;
    const arr: [size]u8 = comptime generateArr(u8, size);
    const expected: [size]u8 = comptime generateExpected(u8, size);

    const original = std.testing.allocator.dupe(u8, &arr) catch unreachable;
    defer std.testing.allocator.free(original);

    try std.testing.expectEqualSlices(u8, &expected, zReverse(u8, size).simd(original));
}

test "test 40 elements" {
    const size: u32 = 40;
    const arr: [size]u8 = comptime generateArr(u8, size);
    const expected: [size]u8 = comptime generateExpected(u8, size);

    const original = std.testing.allocator.dupe(u8, &arr) catch unreachable;
    defer std.testing.allocator.free(original);

    try std.testing.expectEqualSlices(u8, &expected, zReverse(u8, size).simd(original));
}

test "test 100 elements" {
    const size: u32 = 100;
    const arr: [size]u8 = comptime generateArr(u8, size);
    const expected: [size]u8 = comptime generateExpected(u8, size);

    const original = std.testing.allocator.dupe(u8, &arr) catch unreachable;
    defer std.testing.allocator.free(original);

    try std.testing.expectEqualSlices(u8, &expected, zReverse(u8, size).simd(original));
}

test "test 1000 elements" {
    const size: u32 = 1000;
    @setEvalBranchQuota(10000);
    const arr: [size]u8 = comptime generateArr(u8, size);

    const original = std.testing.allocator.dupe(u8, &arr) catch unreachable;
    const expected = std.testing.allocator.dupe(u8, &arr) catch unreachable;
    defer std.testing.allocator.free(original);
    defer std.testing.allocator.free(expected);

    std.mem.reverse(u8, expected);

    try std.testing.expectEqualSlices(u8, expected, zReverse(u8, size).simd(original));
}

test "test 1,000,000 elements" {
    const size: u32 = 1e6;
    const arr: [size]u32 = generateArr(u32, size);
    const expected: [size]u32 = generateExpected(u32, size);

    const original = std.testing.allocator.dupe(u32, &arr) catch unreachable;
    defer std.testing.allocator.free(original);

    try std.testing.expectEqualSlices(u32, &expected, zReverse(u32, size).simd(original));
}

test "test 1,000,000 u8 elements" {
    const size: u32 = 1e6;
    const arr: [size]u8 = generateArr(u8, size);

    const original = std.testing.allocator.dupe(u8, &arr) catch unreachable;
    const expected = std.testing.allocator.dupe(u8, &arr) catch unreachable;
    defer std.testing.allocator.free(original);
    defer std.testing.allocator.free(expected);

    std.mem.reverse(u8, expected);

    try std.testing.expectEqualSlices(u8, expected, zReverse(u8, size).simd(original));
}

fn generateArr(comptime T: anytype, comptime size: usize) [size]T {
    var arr: [size]T = undefined;

    for (0..size) |i| {
        arr[i] = @as(T, @intCast(@mod(i, std.math.maxInt(T)))) + 1;
    }

    return arr;
}

fn generateExpected(comptime T: anytype, comptime size: usize) [size]T {
    var expected: [size]T = undefined;

    for (0..size) |i| {
        expected[i] = @as(T, @min(size, std.math.maxInt(T))) - @as(T, @intCast(@mod(i, std.math.maxInt(T) + 1)));
    }

    return expected;
}
