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

    pub fn loadFiles(this: *@This(), file: *std.fs.File, alloc: std.mem.Allocator) !void {
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
        var header: ?[4]u8 = if (checkHeader) expectedHeaders.fileEntry else null;
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

    fn new(file: *std.fs.File, alloc: std.mem.Allocator, comptime checkHeader: bool) !CentralDirectoryFileHeader {
        var header: ?[4]u8 = if (checkHeader) expectedHeaders.centralRespositoryFile else null;
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

    fn new(file: *std.fs.File, alloc: std.mem.Allocator, comptime checkHeader: bool) !EndOfCentralDirectoryRecord {
        var header: ?[4]u8 = if (checkHeader) expectedHeaders.endOfCentralDirectoryRecord else null;
        return fillObject(@This(), file, alloc, header);
    }

    fn deinit(this: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(this.comment);
        this.* = undefined;
    }
};

fn fillObject(comptime T: type, file: *std.fs.File, alloc: std.mem.Allocator, comptime header: ?[4]u8) !T {
    // TODO - work out how to do cleanup

    // var allocatedSlices = std.BoundedArray(usize, @typeInfo(T).Struct.fields.len).init(0) catch unreachable;
    // errdefer {
    //     for (allocatedSlices.slice()) |fieldIndex| {
    //         std.debug.print("error for field {}`n", .{fieldIndex});
    //         var slice = @field(result, @typeInfo(T).Struct.fields[fieldIndex]);
    //         alloc.free(slice);
    //     }
    // }

    if (header) |h| {
        var buf: [4]u8 = undefined;
        var read = try file.read(&buf);
        if (read != buf.len) {
            return error.ZipFileTooShort;
        }
        if (!std.mem.eql(u8, &buf, &h)) {
            return error.ZipFileIncorrectHeader;
        }
    }

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
                var ind = buf.len;
                while (ind > 0) {
                    ind -= 1;
                    val <<= 8;
                    val += buf[ind];
                }
                @field(result, field.name) = val;
            },
            .Pointer => |pointerType| {
                if (pointerType.size != .Slice or pointerType.child != u8) {
                    @compileError("only support pointer is []u8");
                }
                const fieldLengthName = field.name ++ "Length";
                var length = @field(result, fieldLengthName);
                var slice = try alloc.alloc(u8, length);
                errdefer alloc.free(slice);
                var read = try file.read(slice);
                if (read != slice.len) {
                    return error.ZipFileTooShort;
                }
                @field(result, field.name) = slice;
                // allocatedSlices.append(fieldIndex) catch unreachable;
            },
            else => @compileError("unsupported field type: " ++ field.name),
        }
    }

    return result;
}
