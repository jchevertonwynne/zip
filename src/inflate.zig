const std = @import("std");

pub fn inflate(deflated: []const u8, alloc: std.mem.Allocator) ![]u8 {
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
                // TODO - finish impl
                std.debug.print("{d} {d}\n", .{ len, nLen });
            },
            .Static => {
                while (true) {
                    var huffman = bitGetter.array(7);
                    var i: u9 = arrayToInt(7, huffman, .MSB);
                    if (i <= 0b0010111) { // 256-279
                        var val = i + 256;
                        if (val == 256) {
                            break;
                        }
                        try appendRepeatedString(val, &bitGetter, &result);
                        continue;
                    }
                    i = (i << 1) + bitGetter.next();
                    if (i <= 0b10111111) { // 0 - 143
                        var val = i - 0b00110000;
                        try result.append(@truncate(u8, val));
                        continue;
                    }
                    i = (i << 1) + bitGetter.next();
                    if (i <= 0b11000111) { // 280 - 287
                        var val = i - 0b11000000 + 280;
                        try appendRepeatedString(val, &bitGetter, &result);
                        continue;
                    } else { // 144 - 255
                        var val = i - 0b110010000 + 144;
                        try result.append(@truncate(u8, val));
                        continue;
                    }
                }
            },
            .Dynamic => {
                // TODO - finish impl
            },
        }

        if (header.final) {
            break;
        }
    }

    return result.toOwnedSlice();
}

fn appendRepeatedString(val: u9, bitGetter: *BitGetter, result: *std.ArrayList(u8)) !void {
    var copyLengthInfo = copyLengths[val - 257];
    var copyLengthExtraBits = copyLengthInfo.extraBits;
    var copyLength = copyLengthInfo.lengthMinimum;
    var add: u16 = 0;
    var place: u4 = 0;
    while (copyLengthExtraBits > 0) : (copyLengthExtraBits -= 1) {
        add |= @as(u16, bitGetter.next()) << place;
        place += 1;
    }
    copyLengthExtraBits += add;

    var fromIndex: usize = arrayToInt(5, bitGetter.array(5), .MSB);

    var copyDistanceInfo = copyDistances[fromIndex];
    var copyDistanceExtraBits = copyDistanceInfo.extraBits;
    var copyDistance: u32 = copyDistanceInfo.distanceMinimum;
    add = 0;
    while (copyDistanceExtraBits > 0) : (copyDistanceExtraBits -= 1) {
        add |= @as(u16, bitGetter.next()) << place;
        place += 1;
    }
    copyDistance += add;

    try result.ensureUnusedCapacity(copyLength);
    var start = result.items.len - copyDistance;
    result.appendSlice(result.items[start .. start + copyLength]) catch unreachable;
}

const Header = struct {
    final: bool,
    block: Block,

    fn new(source: [3]u1) !Header {
        return Header{
            .final = source[0] == 1,
            .block = try Block.from(source[1..].*),
        };
    }
};

const Block = enum {
    Stored,
    Static,
    Dynamic,

    fn from(source: [2]u1) !Block {
        var block: u2 = arrayToInt(2, source, .LSB);
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
        while (this.bit != 0) {
            _ = this.next();
        }
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
        for (result) |*r| {
            r.* = this.next();
        }
        return result;
    }
};

fn arrayToInt(comptime size: u16, arr: [size]u1, comptime ordering: Ordering) std.meta.Int(.unsigned, size) {
    var result: std.meta.Int(.unsigned, size) = 0;
    switch (ordering) {
        .MSB => {
            for (arr) |a| {
                result <<= 1;
                result += a;
            }
        },
        .LSB => {
            var i: usize = arr.len;
            while (i > 0) {
                i -= 1;
                result <<= 1;
                result += arr[i];
            }
        },
    }

    return result;
}

const Ordering = enum {
    MSB,
    LSB,
};

const LengthRow = struct {
    extraBits: u16,
    lengthMinimum: u16,
};

const DistRow = struct {
    extraBits: u16,
    distanceMinimum: u16,
};

const copyLengths = [29]LengthRow{
    .{ .extraBits = 0, .lengthMinimum = 3 },
    .{ .extraBits = 0, .lengthMinimum = 4 },
    .{ .extraBits = 0, .lengthMinimum = 5 },
    .{ .extraBits = 0, .lengthMinimum = 6 },
    .{ .extraBits = 0, .lengthMinimum = 7 },
    .{ .extraBits = 0, .lengthMinimum = 8 },
    .{ .extraBits = 0, .lengthMinimum = 9 },
    .{ .extraBits = 0, .lengthMinimum = 10 },
    .{ .extraBits = 1, .lengthMinimum = 11 },
    .{ .extraBits = 1, .lengthMinimum = 13 },

    .{ .extraBits = 1, .lengthMinimum = 15 },
    .{ .extraBits = 1, .lengthMinimum = 17 },
    .{ .extraBits = 2, .lengthMinimum = 19 },
    .{ .extraBits = 2, .lengthMinimum = 23 },
    .{ .extraBits = 2, .lengthMinimum = 27 },
    .{ .extraBits = 2, .lengthMinimum = 31 },
    .{ .extraBits = 3, .lengthMinimum = 35 },
    .{ .extraBits = 3, .lengthMinimum = 43 },
    .{ .extraBits = 3, .lengthMinimum = 51 },
    .{ .extraBits = 3, .lengthMinimum = 59 },

    .{ .extraBits = 4, .lengthMinimum = 67 },
    .{ .extraBits = 4, .lengthMinimum = 83 },
    .{ .extraBits = 4, .lengthMinimum = 99 },
    .{ .extraBits = 4, .lengthMinimum = 115 },
    .{ .extraBits = 5, .lengthMinimum = 131 },
    .{ .extraBits = 5, .lengthMinimum = 163 },
    .{ .extraBits = 5, .lengthMinimum = 195 },
    .{ .extraBits = 5, .lengthMinimum = 227 },
    .{ .extraBits = 0, .lengthMinimum = 258 },
};

const copyDistances = [30]DistRow{
    .{ .extraBits = 0, .distanceMinimum = 1 },
    .{ .extraBits = 0, .distanceMinimum = 2 },
    .{ .extraBits = 0, .distanceMinimum = 3 },
    .{ .extraBits = 0, .distanceMinimum = 4 },
    .{ .extraBits = 1, .distanceMinimum = 5 },
    .{ .extraBits = 1, .distanceMinimum = 7 },
    .{ .extraBits = 2, .distanceMinimum = 9 },
    .{ .extraBits = 2, .distanceMinimum = 13 },
    .{ .extraBits = 3, .distanceMinimum = 17 },
    .{ .extraBits = 3, .distanceMinimum = 25 },

    .{ .extraBits = 4, .distanceMinimum = 33 },
    .{ .extraBits = 4, .distanceMinimum = 49 },
    .{ .extraBits = 5, .distanceMinimum = 65 },
    .{ .extraBits = 5, .distanceMinimum = 97 },
    .{ .extraBits = 6, .distanceMinimum = 129 },
    .{ .extraBits = 6, .distanceMinimum = 193 },
    .{ .extraBits = 7, .distanceMinimum = 257 },
    .{ .extraBits = 7, .distanceMinimum = 385 },
    .{ .extraBits = 8, .distanceMinimum = 513 },
    .{ .extraBits = 8, .distanceMinimum = 769 },

    .{ .extraBits = 9, .distanceMinimum = 1025 },
    .{ .extraBits = 9, .distanceMinimum = 1537 },
    .{ .extraBits = 10, .distanceMinimum = 2049 },
    .{ .extraBits = 10, .distanceMinimum = 3073 },
    .{ .extraBits = 11, .distanceMinimum = 4097 },
    .{ .extraBits = 11, .distanceMinimum = 6145 },
    .{ .extraBits = 12, .distanceMinimum = 8193 },
    .{ .extraBits = 12, .distanceMinimum = 12289 },
    .{ .extraBits = 13, .distanceMinimum = 16385 },
    .{ .extraBits = 13, .distanceMinimum = 24577 },
};
