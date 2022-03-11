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
                var len = arrayToInt(16, bitGetter.array(16), .MSB);
                var nLen = arrayToInt(16, bitGetter.array(16), .MSB);
                if (len != ~nLen) {
                    return error.ZipFileLenMismatch;
                }
                try result.ensureUnusedCapacity(len);
                while (len > 0) {
                    len -= 1;
                    result.append(bitGetter.byte()) catch unreachable;
                }
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
                var hlit = @as(u16, arrayToInt(5, bitGetter.array(5), .MSB)) + 257;
                var hdist = @as(u16, arrayToInt(5, bitGetter.array(5), .MSB)) + 1;
                var hclen = @as(u16, arrayToInt(4, bitGetter.array(4), .MSB)) + 4;
                std.debug.print("{} {} {}\n", .{ hlit, hdist, hclen });

                const indexOrdering = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
                var lengths = std.mem.zeroes([19]u3);
                var index: usize = 0;
                while (hclen > 0) : (index += 1) {
                    hclen -= 1;
                    lengths[indexOrdering[index]] = arrayToInt(3, bitGetter.array(3), .MSB);
                }

                // lengths = .{ 3, 3, 3, 3, 3, 2, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

                var blCount = std.mem.zeroes([8]u16);
                for (lengths) |l| {
                    blCount[l] += 1;
                }

                blCount[0] = 0;
                var nextCode = std.mem.zeroes([8]u64);
                var code: u64 = 0;
                var bits: usize = 1;
                while (bits <= 7) : (bits += 1) {
                    code = (code + blCount[bits - 1]) << 1;
                    nextCode[bits] = code;
                }

                var codeValues = std.mem.zeroes([19]u64);
                for (codeValues) |*c, i| {
                    var len = lengths[i];
                    if (len != 0) {
                        c.* = nextCode[len];
                        nextCode[len] += 1;
                    }
                }
                std.debug.print("lengths = {d}\nblCount = {d}\nnext =    {d}\ncode values = {b}\n", .{ lengths, blCount, nextCode, codeValues });

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
    curr: u8,
    source: []const u8,
    index: usize,
    bit: usize,

    fn new(source: []const u8) @This() {
        return .{
            .curr = source[0],
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

    fn byte(this: *@This()) u8 {
        if (this.bit != 0) {
            @panic("only call Bitgetter.byte() when on a byte boundary");
        }
        var result = this.curr;
        this.index += 1;
        this.curr = this.source[this.index];
        return result;
    }

    fn next(this: *@This()) u1 {
        var bit = @boolToInt((this.curr & (@as(u8, 1) << @truncate(u3, this.bit))) != 0);
        this.bit += 1;
        if (this.bit == 8) {
            this.bit = 0;
            this.index += 1;
            this.curr = this.source[this.index];
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
