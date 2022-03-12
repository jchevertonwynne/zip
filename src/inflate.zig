const std = @import("std");

pub fn inflate(deflated: []const u8, uncompressedSize: usize, alloc: std.mem.Allocator) ![]u8 {
    var result = std.ArrayList(u8).init(alloc);
    defer result.deinit();
    try result.ensureTotalCapacity(uncompressedSize);

    var bitGetter = BitGetter.new(deflated);

    while (true) {
        std.debug.print("{b}\n", .{bitGetter.source[bitGetter.index]});
        var header = try Header.new(try bitGetter.array(3));

        std.debug.print("{}\n", .{header});

        switch (header.block) {
            .Stored => try inflateStoredBlock(&bitGetter, &result),
            .Static => try inflateStaticHuffman(&bitGetter, &result),
            .Dynamic => try inflateDynamicHuffman(&bitGetter, &result),
        }

        if (header.final) {
            break;
        }
    }

    return result.toOwnedSlice();
}

fn inflateStoredBlock(bitGetter: *BitGetter, result: *std.ArrayList(u8)) !void {
    try bitGetter.skipToByteBoundary();
    var len = arrayToInt(try bitGetter.array(16), .MSB);
    var nLen = arrayToInt(try bitGetter.array(16), .MSB);
    if (len != ~nLen) {
        return error.ZipFileLenMismatch;
    }
    try result.ensureUnusedCapacity(len);
    while (len > 0) {
        len -= 1;
        result.append(try bitGetter.byte()) catch unreachable;
    }
}

fn inflateStaticHuffman(bitGetter: *BitGetter, result: *std.ArrayList(u8)) !void {
    while (true) {
        var huffman = try bitGetter.array(7);
        var i: u9 = arrayToInt(huffman, .MSB);
        if (i <= 0b0010111) { // 256-279
            var val = i + 256;
            if (val == 256) {
                break;
            }
            try appendRepeatedString(val, bitGetter, result);
            continue;
        }
        i = (i << 1) + try bitGetter.next();
        if (i <= 0b10111111) { // 0 - 143
            var val = i - 0b00110000;
            try result.append(@truncate(u8, val));
            continue;
        }
        i = (i << 1) + try bitGetter.next();
        if (i <= 0b11000111) { // 280 - 287
            var val = i - 0b11000000 + 280;
            try appendRepeatedString(val, bitGetter, result);
            continue;
        } else { // 144 - 255
            var val = i - 0b110010000 + 144;
            try result.append(@truncate(u8, val));
            continue;
        }
    }
}

// reference: https://github.com/madler/zlib/blob/master/contrib/puff/puff.c#L665
fn inflateDynamicHuffman(bitGetter: *BitGetter, result: *std.ArrayList(u8)) !void {
    var hlit = @as(u16, arrayToInt(try bitGetter.array(5), .MSB)) + 257;
    var hdist = @as(u16, arrayToInt(try bitGetter.array(5), .MSB)) + 1;
    var hclen = @as(u16, arrayToInt(try bitGetter.array(4), .MSB)) + 4;
    std.debug.print("hlit = {}\nhdist = {}\nhclen = {}\n", .{ hlit, hdist, hclen });

    const indexOrdering = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    var lengths: [286 + 30]u64 = undefined;
    var index: usize = 0;
    while (index < hclen) : (index += 1) {
        lengths[indexOrdering[index]] = arrayToInt(try bitGetter.array(3), .MSB);
    }
    while (index < 19) : (index += 1) {
        lengths[indexOrdering[index]] = 0;
    }

    var lenCounts: [16]u8 = undefined; // maxbits + 1
    var lenSymbols: [286]u8 = undefined; // maxlcodes
    var dynamicHuffman1 = DynamicHuffman.new(&lenCounts, &lenSymbols, lengths[0..19]);

    index = 0;
    while (index < hlit + hdist) {
        var symbol: u64 = try decode(bitGetter, dynamicHuffman1);
        std.debug.print("symbol = {}\n", .{symbol});
        if (symbol < 16) {
            lengths[index] = symbol;
            index += 1;
        } else {
            var len: usize = 0;
            if (symbol == 16) {
                len = lengths[index - 1];
                symbol = 3 + @as(u64, arrayToInt(try bitGetter.array(2), .MSB));
            } else if (symbol == 17) {
                symbol = 3 + @as(u64, arrayToInt(try bitGetter.array(3), .MSB));
            } else {
                symbol = 11 + @as(u64, arrayToInt(try bitGetter.array(7), .MSB));
            }
            while (symbol > 0) {
                symbol -= 1;
                lengths[index] = len;
                index += 1;
            }
        }
    }

    std.debug.print("made it to here woohoo\n", .{});

    var lenHuffman = DynamicHuffman.new(&lenCounts, &lenSymbols, lengths[0..hlit]);
    var distCounts: [16]u8 = undefined; // maxbits + 1
    var distSymbols: [30]u8 = undefined; // maxlcodes
    var distHuffman = DynamicHuffman.new(&distCounts, &distSymbols, lengths[hlit .. hlit + hdist]);

    return try codes(bitGetter, lenHuffman, distHuffman, result);
}

fn codes(bitGetter: *BitGetter, lenHuffman: DynamicHuffman, distHuffman: DynamicHuffman, result: *std.ArrayList(u8)) !void {
    const lengths: [29]u64 = .{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
    const lengthExtras: [29]u64 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
    const distances: [30]u64 = .{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
    const distanceExtras: [30]u64 = .{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

    while (true) {
        var symbol = try decode(bitGetter, lenHuffman);
        if (symbol == 256) {
            break;
        } else if (symbol < 256) {
            try result.append(@truncate(u8, symbol));
            std.debug.print("{c}\n", .{@truncate(u8, symbol)});
        } else {
            symbol -= 257;

            var len: usize = lengths[symbol];
            var add: usize = 0;
            var lenExtra = lengthExtras[symbol];
            while (lenExtra > 0) {
                lenExtra -= 1;
                add <<= 1;
                add += try bitGetter.next();
            }
            len += add;

            symbol = try decode(bitGetter, distHuffman);
            var dist: usize = distances[symbol];
            var extra = distanceExtras[symbol];
            add = 0;
            while (extra > 0) {
                extra -= 1;
                add <<= 1;
                add += try bitGetter.next();
            }
            dist += add;

            try result.ensureUnusedCapacity(len);
            var start = result.items.len - dist;
            result.appendSlice(result.items[start .. start + dist]) catch unreachable;
            std.debug.print("{s}\n", .{result.items[start .. start + dist]});
        }
    }
}

fn decode(bitGetter: *BitGetter, huffman: DynamicHuffman) !u64 {
    var code: u64 = 0;
    var first: u64 = 0;
    var index: u64 = 0;

    var len: usize = 1;
    while (len <= 15) : (len += 1) {
        code += try bitGetter.next();
        var count = huffman.counts[len];
        if (code < first + count) {
            return huffman.symbols[index + (code - first)];
        }
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }

    return error.DecodeOverMaxBits;
}

const DynamicHuffman = struct {
    counts: []u8,
    symbols: []u8,

    fn new(counts: []u8, symbols: []u8, lengths: []u64) DynamicHuffman {
        var result = DynamicHuffman{ .counts = counts, .symbols = symbols };

        for (result.counts) |*c| {
            c.* = 0;
        }
        for (lengths) |l| {
            result.counts[l] += 1;
        }

        var offsets: [16]u64 = undefined;
        offsets[1] = 0;
        var len: usize = 1;
        while (len < 15) : (len += 1) {
            offsets[len + 1] = offsets[len] + result.counts[len];
        }

        for (lengths) |length, i| {
            if (length != 0) {
                result.symbols[offsets[length]] = @truncate(u8, i);
                offsets[length] += 1;
            }
        }

        return result;
    }
};

fn appendRepeatedString(val: u9, bitGetter: *BitGetter, result: *std.ArrayList(u8)) !void {
    var copyLengthInfo = copyLengths[val - 257];
    var copyLengthExtraBits = copyLengthInfo.extraBits;
    var copyLength = copyLengthInfo.lengthMinimum;
    var add: u16 = 0;
    var place: u4 = 0;
    while (copyLengthExtraBits > 0) : (copyLengthExtraBits -= 1) {
        add |= @as(u16, try bitGetter.next()) << place;
        place += 1;
    }
    copyLengthExtraBits += add;

    var fromIndex: usize = arrayToInt(try bitGetter.array(5), .MSB);

    var copyDistanceInfo = copyDistances[fromIndex];
    var copyDistanceExtraBits = copyDistanceInfo.extraBits;
    var copyDistance: u32 = copyDistanceInfo.distanceMinimum;
    add = 0;
    while (copyDistanceExtraBits > 0) : (copyDistanceExtraBits -= 1) {
        add |= @as(u16, try bitGetter.next()) << place;
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
        var block: u2 = arrayToInt(source, .LSB);
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

    fn skipToByteBoundary(this: *@This()) !void {
        while (this.bit != 0) {
            _ = try this.next();
        }
    }

    fn byte(this: *@This()) !u8 {
        if (this.atEnd()) {
            return error.BitGetterReachedEnd;
        }
        if (this.bit != 0) {
            return error.BitGetterByteNotAtBoundary;
        }
        var result = this.source[this.index];
        this.index += 1;
        return result;
    }

    fn next(this: *@This()) !u1 {
        if (this.atEnd()) {
            return error.BitGetterReachedEnd;
        }
        var bit = @boolToInt((this.source[this.index] & (@as(u8, 1) << @truncate(u3, this.bit))) != 0);
        this.bit += 1;
        if (this.bit == 8) {
            this.bit = 0;
            this.index += 1;
        }
        return bit;
    }

    fn array(this: *@This(), comptime size: usize) ![size]u1 {
        var result: [size]u1 = undefined;
        for (result) |*r| {
            r.* = try this.next();
        }
        return result;
    }
};

fn arrayToInt(arr: anytype, comptime ordering: Ordering) std.meta.Int(.unsigned, @typeInfo(@TypeOf(arr)).Array.len) {
    if (@typeInfo(@TypeOf(arr)).Array.child != u1) {
        @compileError("only arrays of u1 are supported");
    }
    var result: std.meta.Int(.unsigned, @typeInfo(@TypeOf(arr)).Array.len) = 0;
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

const copyLengths = [29]struct { extraBits: u16, lengthMinimum: u16 }{
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

const copyDistances = [30]struct { extraBits: u16, distanceMinimum: u16 }{
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
