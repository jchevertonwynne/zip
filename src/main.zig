const std = @import("std");
const ZipFile = @import("zip.zig").ZipFile;
const crc32 = @import("crc32.zig").crc32;
const zigargs = @import("zigargs");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    var alloc = gpa.allocator();

    var parsedArgs = try zigargs.parseForCurrentProcess(Args, alloc, .print);
    defer parsedArgs.deinit();

    try parsedArgs.options.valid();

    switch (parsedArgs.options.mode) {
        .unzip => try unzipZipFile(parsedArgs.options, alloc),
        .zip => {
            std.debug.print("zip is currently unimplemented\n", .{});
            return error.ZipFileZipUnimplemented;
        },
    }
}

const Args = struct {
    file: []const u8 = &[_]u8{},
    outputdir: []const u8 = ".",
    mode: enum { zip, unzip } = .unzip,
    usec: bool = false,

    pub const shorthands = .{
        .f = "file",
        .o = "outputdir",
        .m = "mode",
        .c = "usec",
    };

    fn valid(this: @This()) !void {
        if (this.file.len == 0) {
            return error.ArgsZipFileNameNotProvided;
        }
    }
};

fn unzipZipFile(args: Args, alloc: std.mem.Allocator) !void {
    std.debug.print("reading from file {s}\n", .{args.file});

    var file = try std.fs.cwd().openFile(args.file, .{});
    defer file.close();
    var zipFile = try ZipFile.new(&file, alloc);
    defer zipFile.deinit(alloc);

    var h = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(h);
    std.debug.print("base path: {s}\n", .{h});

    var outDir = try std.fs.cwd().openDir(args.outputdir, .{});
    defer outDir.close();

    var path = try outDir.realpathAlloc(alloc, ".");
    defer alloc.free(path);
    std.debug.print("writing zip file contents to: {s}\n", .{path});

    for (try zipFile.loadFiles(&file, alloc)) |fileEntry| {
        std.debug.print("processing {s}...\n", .{fileEntry.header.fileName});

        var decompressedEntry = try fileEntry.decompressed(args.usec, alloc);
        defer decompressedEntry.deinit(alloc);
        var toWrite = decompressedEntry.contents();

        if (fileEntry.header.crc32 != crc32(toWrite)) {
            std.debug.print("crc32 check failed for file {s}\n", .{fileEntry.header.fileName});
            return error.ZipFileCrc32Mismatch;
        }

        if (fileEntry.header.fileName[fileEntry.header.fileName.len - 1] == '/') {
            try outDir.makeDir(fileEntry.header.fileName);
            continue;
        }

        try outDir.writeFile(fileEntry.header.fileName, toWrite);
    }
}
