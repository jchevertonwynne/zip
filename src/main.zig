const std = @import("std");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    var alloc = gpa.allocator();

    var file = try std.fs.cwd().openFile("out.zip", .{});
    var zipFile = try FileEntry.new(&file, alloc);
    defer zipFile.deinit(alloc);

    std.debug.print("{} {s}\n", .{zipFile.header, zipFile.header.fileName});

    var zipFile2 = try FileEntry.new(&file, alloc);
    defer zipFile2.deinit(alloc);

    std.debug.print("{} {s}\n", .{zipFile2.header, zipFile2.header.fileName});
}

const FileEntry = struct {
    header: LocalFileHeader,
    contents: []u8,

    fn new(file: *std.fs.File, alloc: std.mem.Allocator) !FileEntry {
        var header = try LocalFileHeader.new(file, alloc);
        errdefer header.deinit(alloc);

        var contents = try alloc.alloc(u8, header.compressedSize);
        errdefer alloc.free(contents);

        var read = try file.read(contents);
        if (read != contents.len) {
            return error.ZipFileTooShort;
        }

        return FileEntry{ .header = header, .contents = contents };
    }

    fn deinit(this: *@This(), alloc: std.mem.Allocator) void {
        this.header.deinit(alloc);
        alloc.free(this.contents);
        this.* = undefined;
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

    fn new(file: *std.fs.File, alloc: std.mem.Allocator) !LocalFileHeader {
        var buf: [30]u8 = undefined;
        var read = try file.read(&buf);
        if (read != buf.len) {
            return error.ZipFileTooShort;
        }

        var expectedHeader = [4]u8{ 80, 75, 3, 4 };
        if (!std.mem.eql(u8, buf[0..4], &expectedHeader)) {
            std.debug.print("found {d}\n", .{@as([]u8, buf[0..4])});
            return error.ZipFileIncorrectHeader;
        }

        var zipInfo = LocalFileHeader{
            .minVersion = (@as(u16, buf[5]) << 8) + buf[4],
            .bitFlag = (@as(u16, buf[7]) << 8) + buf[6],
            .compressionMethod = (@as(u16, buf[9]) << 8) + buf[8],
            .lastModificationTime = (@as(u16, buf[11]) << 8) + buf[10],
            .lastModificationDate = (@as(u16, buf[13]) << 8) + buf[12],
            .crc32 = (@as(u32, buf[17]) << 24) + (@as(u32, buf[16]) << 16) + (@as(u32, buf[15]) << 8) + buf[14],
            .compressedSize = (@as(u32, buf[21]) << 24) + (@as(u32, buf[20]) << 16) + (@as(u32, buf[19]) << 8) + buf[18],
            .uncompressedSize = (@as(u32, buf[25]) << 24) + (@as(u32, buf[24]) << 16) + (@as(u32, buf[23]) << 8) + buf[22],
            .fileNameLength = (@as(u16, buf[27]) << 8) + buf[26],
            .extraFieldLength = (@as(u16, buf[29]) << 8) + buf[28],
            .fileName = undefined,
            .extraField = undefined,
        };

        var fileName = try alloc.alloc(u8, zipInfo.fileNameLength);
        errdefer alloc.free(fileName);

        read = try file.read(fileName);
        if (read != fileName.len) {
            return error.ZipFileTooShort;
        }

        zipInfo.fileName = fileName;

        var extraField = try alloc.alloc(u8, zipInfo.extraFieldLength);
        errdefer alloc.free(extraField);

        read = try file.read(extraField);
        if (read != extraField.len) {
            return error.ZipFileTooShort;
        }

        zipInfo.extraField = extraField;

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

    fn new(file: *std.fs.File, alloc: std.mem.Allocator) !CentralDirectoryFileHeader {
        _ = file;
        _ = alloc;
        return undefined;
    }
};