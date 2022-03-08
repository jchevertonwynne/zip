const std = @import("std");
const inflate = @import("inflate.zig");

const expectedHeaders: struct {
    fileEntry: [4]u8 = .{ 80, 75, 3, 4 },
    centralRespositoryFile: [4]u8 = .{ 80, 75, 1, 2 },
    endOfCentralDirectoryRecord: [4]u8 = .{ 80, 75, 5, 6 },
} = .{};

pub const ZipFile = struct {
    fileEntries: ?[]FileEntry,
    centralDirectoryFileHeaders: []CentralDirectoryFileHeader,
    endOfCentralDirectoryRecord: EndOfCentralDirectoryRecord,

    pub fn new(file: *std.fs.File, alloc: std.mem.Allocator) !ZipFile {
        try file.seekFromEnd(-22);
        var buf: [4]u8 = undefined;
        var read = try file.read(&buf);
        if (read != buf.len) {
            return error.ZipFileTooShort;
        }
        while (!std.mem.eql(u8, &buf, &expectedHeaders.endOfCentralDirectoryRecord)) {
            try file.seekBy(-5);
            read = try file.read(&buf);
            if (read != buf.len) {
                return error.ZipFileTooShort;
            }
        }
        var end = try EndOfCentralDirectoryRecord.new(file, alloc, false);
        errdefer end.deinit(alloc);

        try file.seekTo(end.centralDirectoryOffset);

        var centralDirectoryFileHeaders = std.ArrayList(CentralDirectoryFileHeader).init(alloc);
        errdefer {
            for (centralDirectoryFileHeaders.items) |*c|
                c.deinit(alloc);
            centralDirectoryFileHeaders.deinit();
        }

        var i: usize = 0;
        while (i < end.totalRecords) : (i += 1) {
            var centralDirectoryFileHeader = try CentralDirectoryFileHeader.new(file, alloc, true);
            errdefer centralDirectoryFileHeader.deinit(alloc);
            try centralDirectoryFileHeaders.append(centralDirectoryFileHeader);
        }

        var result = ZipFile{
            .fileEntries = null,
            .centralDirectoryFileHeaders = centralDirectoryFileHeaders.toOwnedSlice(),
            .endOfCentralDirectoryRecord = end,
        };

        return result;
    }

    pub fn deinit(this: *@This(), alloc: std.mem.Allocator) void {
        if (this.fileEntries) |*entries| {
            for (entries.*) |*f| {
                f.deinit(alloc);
            }
            alloc.free(entries.*);
        }

        for (this.centralDirectoryFileHeaders) |*c|
            c.deinit(alloc);
        alloc.free(this.centralDirectoryFileHeaders);

        this.endOfCentralDirectoryRecord.deinit(alloc);
        this.* = undefined;
    }

    pub fn loadFiles(this: *@This(), file: *std.fs.File, alloc: std.mem.Allocator) !void {
        var files = std.ArrayList(FileEntry).init(alloc);
        errdefer {
            for (files.items) |*f|
                f.deinit(alloc);
            files.deinit();
        }

        for (this.centralDirectoryFileHeaders) |c| {
            try file.seekTo(c.relativeOffsetOfLocalFileHeader);
            var fileEntry = try FileEntry.new(file, alloc, true);
            errdefer fileEntry.deinit(alloc);
            try files.append(fileEntry);
        }

        this.fileEntries = files.toOwnedSlice();
    }
};

const FileEntry = struct {
    header: LocalFileHeader,
    contents: []u8,

    fn new(file: *std.fs.File, alloc: std.mem.Allocator, comptime checkHeader: bool) !FileEntry {
        var header = try LocalFileHeader.new(file, alloc, checkHeader);
        errdefer header.deinit(alloc);

        var contents = try alloc.alloc(u8, header.compressedSize);
        errdefer alloc.free(contents);

        var read = try file.read(contents);
        if (read != contents.len) {
            return error.ZipFileTooShort;
        }

        return FileEntry{ .header = header, .contents = contents };
    }

    pub fn decompressed(this: @This(), alloc: std.mem.Allocator) !DecompressionResult {
        return switch (this.header.compressionMethod) {
            0 => DecompressionResult{ .Already = this.contents },
            8 => DecompressionResult{ .Decompressed = try inflate.inflate(this.contents, alloc) },
            else => return error.DeflateMethodUnsupported,
        };
    }

    fn deinit(this: *@This(), alloc: std.mem.Allocator) void {
        this.header.deinit(alloc);
        alloc.free(this.contents);
        this.* = undefined;
    }
};

const DecompressionResult = union(enum) {
    Decompressed: []u8,
    Already: []u8,
};

const LocalFileHeader = struct {
    minVersion: u16,
    bitFlag: u16,
    compressionMethod: u16,
    lastModificationTime: u16,
    lastModificationDate: u16,
    crc32: u32,
    compressedSize: u32,
    uncompressedSize: u32,
    fileNameLength: u16,
    extraFieldLength: u16,
    fileName: []u8,
    extraField: []u8,

    fn new(file: *std.fs.File, alloc: std.mem.Allocator, comptime checkHeader: bool) !LocalFileHeader {
        var buf: [30]u8 = undefined;
        var read = if (checkHeader) try file.read(&buf) else try file.read(buf[4..]);
        const expectedRead = if (checkHeader) 30 else 26;
        if (read != expectedRead) {
            return error.ZipFileTooShort;
        }

        if (checkHeader and !std.mem.eql(u8, buf[0..4], &expectedHeaders.fileEntry)) {
            std.debug.print("found {d}\n", .{@as([]u8, buf[0..4])});
            return error.ZipFileIncorrectHeader;
        }

        var zipInfo = LocalFileHeader{
            .minVersion = readFromBytes(u16, &buf, 4),
            .bitFlag = readFromBytes(u16, &buf, 6),
            .compressionMethod = readFromBytes(u16, &buf, 8),
            .lastModificationTime = readFromBytes(u16, &buf, 10),
            .lastModificationDate = readFromBytes(u16, &buf, 12),
            .crc32 = readFromBytes(u32, &buf, 14),
            .compressedSize = readFromBytes(u32, &buf, 18),
            .uncompressedSize = readFromBytes(u32, &buf, 22),
            .fileNameLength = readFromBytes(u16, &buf, 26),
            .extraFieldLength = readFromBytes(u16, &buf, 28),
            .fileName = undefined,
            .extraField = undefined,
        };

        try readBytes(file, zipInfo.fileNameLength, &zipInfo.fileName, alloc);
        errdefer alloc.free(zipInfo.fileName);

        try readBytes(file, zipInfo.extraFieldLength, &zipInfo.extraField, alloc);
        errdefer alloc.free(zipInfo.extraField);

        return zipInfo;
    }

    fn deinit(this: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(this.fileName);
        alloc.free(this.extraField);
        this.* = undefined;
    }
};

const CentralDirectoryFileHeader = struct {
    versionMadeBy: u16,
    minVersion: u16,
    generalPurposeBitFlag: u16,
    compressionMethod: u16,
    lastModificationTime: u16,
    lastModificationDate: u16,
    crc32: u32,
    compressedSize: u32,
    uncompressedSize: u32,
    fileNameLength: u16,
    extraFieldLength: u16,
    fileCommentLength: u16,
    diskNumber: u16,
    internalFileAttributes: u16,
    externalFileAttributes: u32,
    relativeOffsetOfLocalFileHeader: u32,
    fileName: []u8,
    extraField: []u8,
    fileComment: []u8,

    fn new(file: *std.fs.File, alloc: std.mem.Allocator, comptime checkHeader: bool) !CentralDirectoryFileHeader {
        var buf: [46]u8 = undefined;
        var read = if (checkHeader) try file.read(&buf) else try file.read(buf[4..]);
        const expectedRead = if (checkHeader) 46 else 42;
        if (read != expectedRead) {
            return error.ZipFileTooShort;
        }

        if (checkHeader and !std.mem.eql(u8, buf[0..4], &expectedHeaders.centralRespositoryFile)) {
            std.debug.print("found {d}\n", .{@as([]u8, buf[0..4])});
            return error.ZipFileIncorrectHeader;
        }

        var centralDirectoryFileHeader = CentralDirectoryFileHeader{
            .versionMadeBy = readFromBytes(u16, &buf, 4),
            .minVersion = readFromBytes(u16, &buf, 6),
            .generalPurposeBitFlag = readFromBytes(u16, &buf, 8),
            .compressionMethod = readFromBytes(u16, &buf, 10),
            .lastModificationTime = readFromBytes(u16, &buf, 12),
            .lastModificationDate = readFromBytes(u16, &buf, 14),
            .crc32 = readFromBytes(u32, &buf, 16),
            .compressedSize = readFromBytes(u32, &buf, 20),
            .uncompressedSize = readFromBytes(u32, &buf, 24),
            .fileNameLength = readFromBytes(u16, &buf, 28),
            .extraFieldLength = readFromBytes(u16, &buf, 30),
            .fileCommentLength = readFromBytes(u16, &buf, 32),
            .diskNumber = readFromBytes(u16, &buf, 34),
            .internalFileAttributes = readFromBytes(u16, &buf, 36),
            .externalFileAttributes = readFromBytes(u32, &buf, 38),
            .relativeOffsetOfLocalFileHeader = readFromBytes(u32, &buf, 42),
            .fileName = undefined,
            .extraField = undefined,
            .fileComment = undefined,
        };

        try readBytes(file, centralDirectoryFileHeader.fileNameLength, &centralDirectoryFileHeader.fileName, alloc);
        errdefer alloc.free(centralDirectoryFileHeader.fileName);

        try readBytes(file, centralDirectoryFileHeader.extraFieldLength, &centralDirectoryFileHeader.extraField, alloc);
        errdefer alloc.free(centralDirectoryFileHeader.extraField);

        try readBytes(file, centralDirectoryFileHeader.fileCommentLength, &centralDirectoryFileHeader.fileComment, alloc);
        errdefer alloc.free(centralDirectoryFileHeader.fileComment);

        return centralDirectoryFileHeader;
    }

    fn deinit(this: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(this.fileName);
        alloc.free(this.extraField);
        alloc.free(this.fileComment);
        this.* = undefined;
    }
};

const EndOfCentralDirectoryRecord = struct {
    diskNumber: u16,
    startDiskNumber: u16,
    recordsOnDisk: u16,
    totalRecords: u16,
    centralDirectorySize: u32,
    centralDirectoryOffset: u32,
    commentLength: u16,
    comment: []u8,

    fn new(file: *std.fs.File, alloc: std.mem.Allocator, comptime checkHeader: bool) !EndOfCentralDirectoryRecord {
        var buf: [22]u8 = undefined;
        var read = if (checkHeader) try file.read(&buf) else try file.read(buf[4..]);
        const expectedRead = if (checkHeader) 22 else 18;
        if (read != expectedRead) {
            return error.ZipFileTooShort;
        }

        if (checkHeader and !std.mem.eql(u8, buf[0..4], &expectedHeaders.endOfCentralDirectoryRecord)) {
            std.debug.print("found {d}\n", .{@as([]u8, buf[0..4])});
            return error.ZipFileIncorrectHeader;
        }

        var endOfCentralDirectoryRecord = EndOfCentralDirectoryRecord{
            .diskNumber = readFromBytes(u16, &buf, 4),
            .startDiskNumber = readFromBytes(u16, &buf, 6),
            .recordsOnDisk = readFromBytes(u16, &buf, 8),
            .totalRecords = readFromBytes(u16, &buf, 10),
            .centralDirectorySize = readFromBytes(u32, &buf, 12),
            .centralDirectoryOffset = readFromBytes(u32, &buf, 16),
            .commentLength = readFromBytes(u16, &buf, 20),
            .comment = undefined,
        };

        try readBytes(file, endOfCentralDirectoryRecord.commentLength, &endOfCentralDirectoryRecord.comment, alloc);
        errdefer alloc.free(endOfCentralDirectoryRecord.comment);

        return endOfCentralDirectoryRecord;
        // return try fillObject(EndOfCentralDirectoryRecord, file, alloc);
    }

    fn deinit(this: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(this.comment);
        this.* = undefined;
    }
};

fn fillObject(comptime T: type, file: *std.fs.File, alloc: std.mem.Allocator) !T {
    var result: T = undefined;
    inline for (@typeInfo(T).Struct.fields) |field| {
        switch (@typeInfo(field.field_type)) {
            .Int => |intType| {
                const expectedBytes = (intType.bits + 7) / 8;
                var buf: [expectedBytes]u8 = undefined;
                var read = try file.read(&buf);
                if (read != expectedBytes) {
                    return error.ZipFileTooShort;
                }
                var val: std.meta.Int(intType.signedness, intType.bits) = 0;
                for (buf) |b| {
                    val <<= 8;
                    val += b;
                }
                @field(result, field.name) = val;
            },
            .Pointer => |pointerType| {
                if (pointerType.size != .Slice or pointerType.child != u8) {
                    @compileError("only slice pointers are supported");
                }
                var fieldLengthName = field.name ++ "Length";
                var length = @field(result, fieldLengthName);
                var slice = try alloc.alloc(u8, length);
                errdefer alloc.free(slice);
                var read = try file.read(&slice);
                if (read != slice.len) {
                    return error.ZipFileTooShort;
                }
                @field(result, field.name) = slice;
                @compileError(fieldLengthName); 
            },
            else => {}
        }
    }
    // const t: std.builtin.TypeInfo;
}

fn readBytes(file: *std.fs.File, expectedRead: usize, dest: *[]u8, alloc: std.mem.Allocator) !void {
    var buf = try alloc.alloc(u8, expectedRead);
    errdefer alloc.free(buf);

    var read = try file.read(buf);
    if (read != expectedRead) {
        return error.ReadTooShort;
    }

    dest.* = buf;
}

fn readFromBytes(comptime T: type, bytes: []u8, offset: usize) T {
    if (@typeInfo(T).Int.signedness == .signed)
        @compileError("function only takes an unsigned integer");

    const size = @sizeOf(T);

    var result: T = undefined;
    var ind = offset + size;
    while (ind > offset) {
        ind -= 1;
        result <<= 8;
        result += bytes[ind];
    }
    return result;
}
