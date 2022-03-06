const std = @import("std");

pub fn inflate(deflated: []const u8, alloc: std.mem.Allocator) ![]u8 {
    if (copyLengthExtraBits.len != copyLengthMinimums.len)
        @compileError("mismatch number of items in each array");

    var result = std.ArrayList(u8).init(alloc);
    defer result.deinit();

    var bitGetter = BitGetter.new(deflated);

    while (true) {
        var headerArr = bitGetter.array(3);
        var header = try Header.new(headerArr);

        std.debug.print("{}\n", .{header});

        switch (header.block) {
            .Stored => {
                bitGetter.skipToByteBoundary();
                var len = bitGetter.array(16);
                var nLen = bitGetter.array(16);
                std.debug.print("{d} {d}\n", .{ len, nLen });
            },
            .Static => {
                inner: while (true) {
                    var huffman = bitGetter.array(7);
                    var i: u9 = arrayToInt(7, huffman, .MSB);
                    if (i <= 0b0010111) { // 256-279
                        var val = i - 0b0000000 + 256;
                        if (val == 256) {
                            break :inner;
                        }

                        var copyLengthExtraBit = copyLengthExtraBits[val - 257];
                        var copyLength = copyLengthMinimums[val - 257];
                        var add: u8 = 0;
                        var place: u3 = 0;
                        while (copyLengthExtraBit > 0) : (copyLengthExtraBit -= 1) {
                            add |= @as(u8, bitGetter.next()) << place;
                            place += 1;
                        }
                        copyLengthExtraBit += add;

                        var fromIndexArray = bitGetter.array(5);
                        var fromIndex: usize = arrayToInt(5, fromIndexArray, .MSB);

                        var copyIndexExtraBit = copyFromExtraBits[fromIndex];
                        var copyIndexLength: u32 = copyFromLengthMinimums[fromIndex];
                        add = 0;
                        while (copyIndexExtraBit > 0) : (copyIndexExtraBit -= 1) {
                            add |= @as(u8, bitGetter.next()) << place;
                            place += 1;
                        }
                        copyIndexLength += add;

                        try result.ensureUnusedCapacity(copyLength);
                        var start = result.items.len - copyIndexLength + 1;
                        result.appendSlice(result.items[start..start + copyLength]) catch unreachable;

                        continue;
                    }
                    i = (i << 1) + bitGetter.next();
                    if (i <= 0b10111111) { // 0 - 143
                        var val = i - 0b00110000 + 0;
                        try result.append(@truncate(u8, val));
                        continue;
                    }
                    i = (i << 1) + bitGetter.next();
                    if (i <= 0b11000111) { // 280 - 287
                        var val = i - 0b11000000 + 280;

                        var copyLengthExtraBit = copyLengthExtraBits[val - 257];
                        var copyLength = copyLengthMinimums[val - 257];
                        var add: u8 = 0;
                        var place: u3 = 0;
                        while (copyLengthExtraBit > 0) : (copyLengthExtraBit -= 1) {
                            add |= @as(u8, bitGetter.next()) << place;
                            place += 1;
                        }
                        copyLengthExtraBit += add;

                        var fromIndexArray = bitGetter.array(5);
                        var fromIndex: usize = arrayToInt(5, fromIndexArray, .MSB);

                        var copyIndexExtraBit = copyFromExtraBits[fromIndex];
                        var copyIndexLength: u32 = copyFromLengthMinimums[fromIndex];
                        add = 0;
                        while (copyIndexExtraBit > 0) : (copyIndexExtraBit -= 1) {
                            add |= @as(u8, bitGetter.next()) << place;
                            place += 1;
                        }
                        copyIndexLength += add;

                        try result.ensureUnusedCapacity(copyLength);
                        var start = result.items.len - copyIndexLength + 1;
                        result.appendSlice(result.items[start..start + copyLength]) catch unreachable;

                        continue;
                    } else { // 144 - 255
                        var val = i - 0b110010000 + 144;
                        try result.append(@truncate(u8, val));
                        continue;
                    }
                }
            },
            .Dynamic => {

            },
            else => {},
        }

        if (header.final)
            break;
    }

    return result.toOwnedSlice();
}

const Header = struct {
    final: bool,
    block: Block,

    fn new(source: [3]u1) !Header {
        return Header{ .final = source[0] == 1, .block = try Block.from(source[1..].*) };
    }
};

const Block = enum {
    Stored,
    Static,
    Dynamic,

    fn from(source: [2]u1) !Block {
        var block: u2 = (@as(u2, source[1]) << 1) + source[0];
        return switch (block) {
            0b00 => .Stored,
            0b01 => .Static,
            0b10 => .Dynamic,
            0b11 => return error.InvalidBlockType,
        };
    }
};

const BitGetter = struct {
    source: []const u8,
    index: usize,
    bit: usize,

    fn new(source: []const u8) @This() {
        return .{
            .source = source,
            .index = 0,
            .bit = 0,
        };
    }

    fn atEnd(this: @This()) bool {
        return this.index == this.source.len;
    }

    fn skipToByteBoundary(this: *@This()) void {
        while (this.bit != 0)
            _ = this.next();
    }

    fn next(this: *@This()) u1 {
        var bit = @boolToInt((this.source[this.index] & (@as(u8, 1) << @truncate(u3, this.bit))) != 0);
        this.bit += 1;
        if (this.bit == 8) {
            this.bit = 0;
            this.index += 1;
        }
        return bit;
    }

    fn array(this: *@This(), comptime size: usize) [size]u1 {
        var result: [size]u1 = undefined;
        for (result) |*r|
            r.* = this.next();
        return result;
    }
};

fn arrayToInt(comptime size: u16, arr: [size]u1, comptime ordering: Ordering) std.meta.Int(.unsigned, size) {
    var result: std.meta.Int(.unsigned, size) = 0;
    if (ordering == .MSB) {
        for (arr) |a| {
            result <<= 1;
            result += a;
        }
    } else {
        var i: usize = arr.len;
        while (i > 0) {
            i -= 1;
            result <<= 1;
            result += arr[i];
        }
    }

    return result;
}

const Ordering = enum {
    MSB,
    LSB
};

const copyLengthExtraBits = [_]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1,
    1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 
    4, 4, 4, 4, 5, 5, 5, 5, 0,
};

const copyLengthMinimums = [_]u16{
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13,
    15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 
    67, 83, 99, 115, 131, 163, 195, 227, 258,
};

const copyFromExtraBits = [_]u8 {
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3,
    4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 
    9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
};

const copyFromLengthMinimums = [_]u16 { 
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13,
    15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
    67, 83, 99, 115, 131, 163, 195, 227, 258,
};
