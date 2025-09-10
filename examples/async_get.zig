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
    _ = gpa.allocator(); // Avoid unused variable error

    // Create a task that performs async HTTP requests
    const AsyncHttpTask = struct {
        fn task(io: @import("zsync").Io) !void {
            std.log.info("Making async GET request to httpbin.org...", .{});
            
            // Create mutable io for async operations
            var mut_io = io;
            
            var response = zhttp.getAsync(io.getAllocator(), &mut_io, "http://httpbin.org/get") catch |err| {
                std.log.err("Failed to make async GET request: {}", .{err});
                return;
            };
            defer response.deinit();

            std.log.info("Async Status: {} {s}", .{ response.status, response.reason });
            
            if (response.isSuccess()) {
                const body = response.readAll(1024 * 1024) catch |err| {
                    std.log.err("Failed to read response body: {}", .{err});
                    return;
                };
                defer io.getAllocator().free(body);
                
                std.log.info("Async Response body ({d} bytes):", .{body.len});
                std.debug.print("{s}\n", .{body});
            } else {
                std.log.warn("Async Request failed with status {}", .{response.status});
            }
        }
    };
    
    // Run with zsync runtime
    const zsync = @import("zsync");
    try zsync.runBlocking(AsyncHttpTask.task, {});
    
    std.log.info("Async HTTP request completed!", .{});
}