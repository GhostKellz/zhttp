const std = @import("std");
const zhttp = @import("zhttp");
const build_options = @import("build_options");

pub fn main() !void {
    if (!build_options.enable_async) {
        std.log.err("Async support is not enabled. Build with -Dasync=true", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Making async GET request to httpbin.org...", .{});

    // Create event loop for async operations
    var event_loop = try zhttp.AsyncRuntime.EventLoop.init(allocator);
    defer event_loop.deinit();

    // Make async HTTP request
    var response = try zhttp.getAsync(allocator, &event_loop, "http://httpbin.org/get");
    defer response.deinit();

    std.log.info("Async Status: {} {s}", .{ response.status, response.reason });

    if (response.isSuccess()) {
        const body = try response.readAll(1024 * 1024);
        defer allocator.free(body);

        std.log.info("Async Response body ({d} bytes):", .{body.len});
        std.debug.print("{s}\n", .{body});
    } else {
        std.log.warn("Async Request failed with status {}", .{response.status});
    }

    std.log.info("Async HTTP request completed!", .{});
}