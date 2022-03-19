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
        while (!std.meta.eql(buf, expectedHeaders.endOfCentralDirectoryRecord)) {
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
            for (centralDirectoryFileHeaders.items) |*c| {
                c.deinit(alloc);
            }
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

        for (this.centralDirectoryFileHeaders) |*c| {
            c.deinit(alloc);
        }
        alloc.free(this.centralDirectoryFileHeaders);

        this.endOfCentralDirectoryRecord.deinit(alloc);
        this.* = undefined;
    }

    pub fn loadFiles(this: *@This(), file: *std.fs.File, alloc: std.mem.Allocator) ![]FileEntry {
        var files = std.ArrayList(FileEntry).init(alloc);
        errdefer {
            for (files.items) |*f| {
                f.deinit(alloc);
            }
            files.deinit();
        }

        for (this.centralDirectoryFileHeaders) |c| {
            try file.seekTo(c.relativeOffsetOfLocalFileHeader);
            var fileEntry = try FileEntry.new(file, alloc, true);
            errdefer fileEntry.deinit(alloc);
            try files.append(fileEntry);
        }

        var result = files.toOwnedSlice();
        this.fileEntries = result;
        return result;
    }
};

const FileEntry = struct {
    header: LocalFileHeader,
    contents: []u8,

    fn new(file: *std.fs.File, alloc: std.mem.Allocator, comptime checkHeader: bool) !@This() {
        var header = try LocalFileHeader.new(file, alloc, checkHeader);
        errdefer header.deinit(alloc);

        var contents = try alloc.alloc(u8, header.compressedSize);
        errdefer alloc.free(contents);

        var read = try file.read(contents);
        if (read != contents.len) {
            return error.ZipFileTooShort;
        }

        return @This(){ .header = header, .contents = contents };
    }

    pub fn decompressed(this: @This(), useC: bool, alloc: std.mem.Allocator) !DecompressionResult {
        return switch (this.header.compressionMethod) {
            0 => DecompressionResult{ .Already = this.contents },
            8 => DecompressionResult{ .Decompressed = try inflate.inflate(this.contents, this.header.uncompressedSize, useC, alloc) },
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

    pub fn deinit(this: *@This(), alloc: std.mem.Allocator) void {
        switch (this.*) {
            .Decompressed => |d| alloc.free(d),
            else => {},
        }
    }

    pub fn contents(this: @This()) []u8 {
        return switch (this) {
            .Decompressed => |decompressed| decompressed,
            .Already => |already| already,
        };
    }
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

    fn new(file: *std.fs.File, alloc: std.mem.Allocator, comptime checkHeader: bool) !@This() {
        const header: ?[4]u8 = if (checkHeader) expectedHeaders.fileEntry else null;
        return fillObject(@This(), file, alloc, header);
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

    fn new(file: *std.fs.File, alloc: std.mem.Allocator, comptime checkHeader: bool) !@This() {
        const header: ?[4]u8 = if (checkHeader) expectedHeaders.centralRespositoryFile else null;
        return fillObject(@This(), file, alloc, header);
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

    fn new(file: *std.fs.File, alloc: std.mem.Allocator, comptime checkHeader: bool) !@This() {
        const header: ?[4]u8 = if (checkHeader) expectedHeaders.endOfCentralDirectoryRecord else null;
        return fillObject(@This(), file, alloc, header);
    }

    fn deinit(this: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(this.comment);
        this.* = undefined;
    }
};

fn intFieldSize(comptime T: type) usize {
    var size: usize = 0;

    for (@typeInfo(T).Struct.fields) |field| {
        if (@typeInfo(field.field_type) == .Int) {
            size += @sizeOf(field.field_type);
        }
    }

    return size;
}

fn fillObject(comptime T: type, file: *std.fs.File, alloc: std.mem.Allocator, comptime header: ?[4]u8) !T {
    @setEvalBranchQuota(100_000);
    const fieldCount = @typeInfo(T).Struct.fields.len;
    var result: T = undefined;

    var cleanup: [fieldCount]bool = .{false} ** fieldCount;

    errdefer { // bit horrible but probably works
        inline for (@typeInfo(T).Struct.fields) |field, fieldIndex| {
            if (cleanup[fieldIndex]) {
                if (@typeInfo(field.field_type) == .Pointer) {
                    alloc.free(@field(result, field.name));
                } else unreachable;
            }
        }
    }

    const headerOffset = if (header != null) 4 else 0;
    var buf: [intFieldSize(T) + headerOffset]u8 = undefined;
    {
        var read = try file.read(&buf);
        if (read != buf.len) {
            return error.ZipFileTooShort;
        }
    }

    if (header) |h| {
        if (!std.meta.eql(buf[0..4].*, h)) {
            return error.ZipFileIncorrectHeader;
        }
    }

    var ind: usize = headerOffset;

    inline for (@typeInfo(T).Struct.fields) |field, fieldIndex| {
        switch (@typeInfo(field.field_type)) {
            .Int => |intType| {
                if (intType.bits % 8 != 0) {
                    @compileError("error for field '" ++ field.name ++ "': only full byte integer sizes are supported");
                }
                var intBuf: []u8 = buf[ind .. ind + @sizeOf(field.field_type)];
                var val: std.meta.Int(intType.signedness, intType.bits) = 0;
                var intInd = intBuf.len;
                while (intInd > 0) {
                    intInd -= 1;
                    val <<= 8;
                    val += intBuf[intInd];
                }
                @field(result, field.name) = val;
                ind += @sizeOf(field.field_type);
            },
            .Pointer => |pointerType| {
                if (pointerType.size != .Slice or pointerType.child != u8) {
                    @compileError("error with field '" ++ field.name ++ "': only support pointer is []u8");
                }
                const fieldLengthName = field.name ++ "Length";
                var length = @field(result, fieldLengthName);
                var slice = try alloc.alloc(u8, length);
                errdefer alloc.free(slice);
                {
                    var read = try file.read(slice);
                    if (read != slice.len) {
                        return error.ZipFileTooShort;
                    }
                }
                @field(result, field.name) = slice;
                cleanup[fieldIndex] = true;
            },
            else => @compileError("unsupported field type: " ++ field.name),
        }
    }

    return result;
}
