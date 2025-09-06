const std = @import("std");
const zhttp = @import("zhttp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Testing HTTPS connection with certificate verification...", .{});
    
    // Enable certificate verification
    var options = zhttp.ClientOptions{};
    options.tls.verify_certificates = true;  // This should use system CA certificates
    
    var client = zhttp.Client.init(allocator, options);
    defer client.deinit();
    
    var request = zhttp.Request.init(allocator, .GET, "https://httpbin.org/get");
    defer request.deinit();
    
    std.log.info("Sending HTTPS request with cert verification...", .{});
    
    var response = client.send(request) catch |err| {
        std.log.err("Request failed: {}", .{err});
        return;
    };
    defer response.deinit();
    
    std.log.info("Got response with status: {}", .{response.status});
    
    const body = response.readAll(1024) catch |err| {
        std.log.err("Failed to read body: {}", .{err});
        return;
    };
    defer allocator.free(body);
    
    std.log.info("Successfully read {} bytes", .{body.len});
    if (body.len > 0) {
        std.log.info("First 100 chars: {s}", .{body[0..@min(100, body.len)]});
    }
}