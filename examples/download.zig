const std = @import("std");
const zhttp = @import("zhttp");

pub fn main(process: std.process.Init.Minimal) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get command line arguments using iterator
    var args_iter = std.process.Args.Iterator.init(process.args);

    const prog_name = args_iter.next() orelse "download";
    const url = args_iter.next() orelse {
        std.debug.print("Usage: {s} <url> <output_file>\n", .{prog_name});
        return;
    };
    const output_file = args_iter.next() orelse {
        std.debug.print("Usage: {s} <url> <output_file>\n", .{prog_name});
        return;
    };

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
}