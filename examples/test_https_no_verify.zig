const std = @import("std");
const zhttp = @import("zhttp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test HTTPS request with TLS (no certificate verification)
    std.log.info("Making HTTPS request to httpbin.org (no cert verification)...", .{});
    
    var options = zhttp.ClientOptions{};
    options.tls.verify_certificates = false; // Disable certificate verification
    var client = zhttp.Client.init(allocator, options);
    
    const request = zhttp.Request.init(allocator, .GET, "https://httpbin.org/get");
    
    var response = client.send(request) catch |err| {
        std.log.err("Failed to make HTTPS request: {}", .{err});
        return;
    };
    defer response.deinit();

    std.log.info("Status: {} {s}", .{ response.status, response.reason });
    
    if (response.isSuccess()) {
        const body = response.readAll(1024 * 1024) catch |err| {
            std.log.err("Failed to read response body: {}", .{err});
            return;
        };
        defer allocator.free(body);
        
        std.log.info("Response body ({d} bytes):", .{body.len});
        std.debug.print("{s}\n", .{body});
    } else {
        std.log.warn("Request failed with status {}", .{response.status});
    }
}