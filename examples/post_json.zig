const std = @import("std");
const zhttp = @import("zhttp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a client with custom options
    var client = zhttp.Client.init(allocator, zhttp.ClientOptions{
        .user_agent = "zhttp-example/1.0",
        .connect_timeout = 5000,
    });
    defer client.deinit();

    // Build a POST request with JSON body
    var builder = zhttp.RequestBuilder.init(allocator, .POST, "http://httpbin.org/post");
    defer builder.deinit();
    
    const json_data = 
        \\{
        \\  "name": "zhttp",
        \\  "version": "0.1.0",
        \\  "features": ["http1", "connection_pooling", "json"]
        \\}
    ;
    
    _ = builder
        .header("Content-Type", "application/json")
        .header("Accept", "application/json")
        .body(zhttp.Body.fromString(json_data))
        .timeout(10000);
    
    const request = builder.build();
    
    std.log.info("Making POST request with JSON data...", .{});
    
    var response = client.send(request) catch |err| {
        std.log.err("Failed to send POST request: {}", .{err});
        return;
    };
    defer response.deinit();

    std.log.info("Status: {} {s}", .{ response.status, response.reason });
    
    // Print response headers
    std.log.info("Response headers:", .{});
    for (response.headers.items()) |header| {
        std.debug.print("  {s}: {s}\n", .{ header.name, header.value });
    }
    
    if (response.isSuccess()) {
        const body = response.readAll(1024 * 1024) catch |err| {
            std.log.err("Failed to read response body: {}", .{err});
            return;
        };
        defer allocator.free(body);
        
        std.log.info("Response body ({d} bytes):", .{body.len});
        std.debug.print("{s}\n", .{body});
    }
}