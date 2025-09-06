const std = @import("std");
const zhttp = @import("zhttp");
const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("zhttp - HTTP Client Library for Zig 0.16+\n\n", .{});
    
    // Show build configuration
    std.debug.print("Build Configuration:\n", .{});
    std.debug.print("  HTTP/1.1 Engine: {}\n", .{build_options.engine_h1});
    std.debug.print("  HTTP/2 Engine: {}\n", .{build_options.engine_h2});
    std.debug.print("  HTTP/3 Engine: {}\n", .{build_options.engine_h3});
    std.debug.print("  Async Runtime: {}\n", .{build_options.enable_async});
    std.debug.print("  Brotli Support: {}\n", .{build_options.with_brotli});
    std.debug.print("  zlib Support: {}\n", .{build_options.with_zlib});
    std.debug.print("  QUIC Backend: {s}\n\n", .{build_options.quic_backend});
    
    std.debug.print("Examples:\n", .{});
    std.debug.print("  zig build run-get           # Simple GET request\n", .{});
    std.debug.print("  zig build run-post_json     # POST with JSON\n", .{});
    std.debug.print("  zig build run-download -- <url> <file>  # Download file\n\n", .{});
    
    // Demonstrate basic usage
    std.debug.print("Testing basic functionality...\n", .{});
    
    // Test URL parsing
    const test_url = "https://example.com:8080/path?query=value";
    
    // Create a request to test URL parsing
    var test_request = zhttp.Request.init(allocator, .GET, test_url);
    defer test_request.deinit();
    
    const url_components = test_request.parseUrl(allocator) catch |err| {
        std.debug.print("URL parsing failed: {}\n", .{err});
        return;
    };
    
    std.debug.print("Parsed URL '{s}':\n", .{test_url});
    std.debug.print("  Scheme: {s}\n", .{url_components.scheme});
    std.debug.print("  Host: {s}\n", .{url_components.host});
    std.debug.print("  Port: {d}\n", .{url_components.port});
    std.debug.print("  Path: {s}\n", .{url_components.path});
    if (url_components.query) |q| {
        std.debug.print("  Query: {s}\n", .{q});
    }
    std.debug.print("  Secure: {}\n\n", .{url_components.isSecure()});
    
    // Test request building
    var builder = zhttp.RequestBuilder.init(allocator, .GET, test_url);
    defer builder.deinit();
    
    _ = builder
        .header("User-Agent", "zhttp-demo/0.1")
        .header("Accept", "application/json")
        .timeout(5000);
        
    const request = builder.build();
    std.debug.print("Built request:\n", .{});
    std.debug.print("  Method: {s}\n", .{request.method.toString()});
    std.debug.print("  URL: {s}\n", .{request.url});
    std.debug.print("  Headers: {d}\n", .{request.headers.count()});
    if (request.timeout) |t| {
        std.debug.print("  Timeout: {d}ms\n", .{t});
    }
    
    std.debug.print("\nzhttp is ready for use!\n", .{});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
