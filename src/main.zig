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

    if (!parsedArgs.options.valid()) {
        std.debug.print("invalid file provided\n", .{});
        std.os.exit(1);
    }

    try handleOperation(parsedArgs.options, alloc);
}

const Args = struct {
    file: []const u8 = &[_]u8{},
    mode: enum { zip, unzip } = .unzip,
    usec: bool = false,

    pub const shorthands = .{
        .f = "file",
        .m = "mode",
        .c = "usec",
    };

    fn valid(this: @This()) bool {
        return this.file.len > 0;
    }
};

fn handleOperation(args: Args, alloc: std.mem.Allocator) !void {
    switch (args.mode) {
        .unzip => try unzipZipFile(args, alloc),
        .zip => {
            std.debug.print("zip is currently unimplemented\n", .{});
            return error.ZipFileZipUnimplemented;
        },
    }
}

fn unzipZipFile(args: Args, alloc: std.mem.Allocator) !void {
    std.debug.print("reading from file {s}\n", .{args.file});

    var file = try std.fs.cwd().openFile(args.file, .{});
    var zipFile = try ZipFile.new(&file, alloc);
    defer zipFile.deinit(alloc);

    var outDir = std.fs.cwd();

    for (try zipFile.loadFiles(&file, alloc)) |fileEntry| {
        std.debug.print("processing {s}...\n", .{fileEntry.header.fileName});

        var outFile = outDir.createFile(fileEntry.header.fileName, .{}) catch |err| {
            if (err == error.IsDir) {
                try outDir.makeDir(fileEntry.header.fileName);
                continue;
            }
            return err;
        };
        defer outFile.close();

        var mustFree = false;

        var toWrite = switch (try fileEntry.decompressed(args.usec, alloc)) {
            .Decompressed => |decompressed| blk: {
                mustFree = true;
                break :blk decompressed;
            },
            .Already => |alreadyDecompressed| alreadyDecompressed,
        };
        defer {
            if (mustFree) {
                alloc.free(toWrite);
            }
        }

        if (fileEntry.header.crc32 != crc32(toWrite)) {
            std.debug.print("crc32 check failed for file {s}\n", .{fileEntry.header.fileName});
            return error.ZipFileCrc32Mismatch;
        }

        var written = try outFile.write(toWrite);
        if (written != toWrite.len) {
            std.debug.print("failed to fully write file {s}\n", .{fileEntry.header.fileName});
            return error.ZipFileWriteTooShort;
        }
    }
}
