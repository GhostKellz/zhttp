const std = @import("std");
const zhttp = @import("zhttp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} <url> <output_file>\n", .{args[0]});
        return;
    }

    const url = args[1];
    const output_file = args[2];

    std.log.info("Downloading {s} to {s}...", .{ url, output_file });

    // Use convenience download function
    zhttp.download(allocator, url, output_file) catch |err| switch (err) {
        error.RequestFailed => {
            std.log.err("Download failed: HTTP request unsuccessful", .{});
            return;
        },
        error.FileNotFound => {
            std.log.err("Download failed: Could not create output file", .{});
            return;
        },
        else => {
            std.log.err("Download failed: {}", .{err});
            return;
        },
    };

    std.log.info("Download completed successfully!", .{});

    // Show file size
    const file = std.fs.cwd().openFile(output_file, .{}) catch |err| {
        std.log.warn("Could not check file size: {}", .{err});
        return;
    };
    defer file.close();

    const file_size = file.getEndPos() catch 0;
    std.log.info("Downloaded {d} bytes", .{file_size});
}