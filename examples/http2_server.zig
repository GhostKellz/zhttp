const std = @import("std");
const zhttp = @import("zhttp");
const build_options = @import("build_options");

fn handler(req: *zhttp.Http2.ServerRequest, res: *zhttp.Http2.ServerResponse) !void {
    std.debug.print("{s} {s}\n", .{ req.method.toString(), req.path });

    if (std.mem.eql(u8, req.path, "/")) {
        try res.setHeader("content-type", "text/html; charset=utf-8");
        try res.send(
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>zhttp HTTP/2 Server</title></head>
            \\<body>
            \\  <h1>Welcome to zhttp HTTP/2 Server!</h1>
            \\  <p>This server supports HTTP/2 multiplexing!</p>
            \\  <ul>
            \\    <li><a href="/hello">GET /hello</a></li>
            \\    <li><a href="/json">GET /json</a></li>
            \\  </ul>
            \\</body>
            \\</html>
        );
    } else if (std.mem.eql(u8, req.path, "/hello")) {
        try res.sendText("Hello from zhttp HTTP/2 server!");
    } else if (std.mem.eql(u8, req.path, "/json")) {
        try res.sendJson(
            \\{"message": "Hello, World!", "server": "zhttp", "protocol": "HTTP/2"}
        );
    } else {
        res.setStatus(404);
        try res.sendText("Not Found");
    }
}

pub fn main() !void {
    if (!build_options.engine_h2) {
        std.debug.print("HTTP/2 is not enabled. Build with -Dengine_h2=true\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = zhttp.Http2.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 8443,
        .enable_tls = false, // For testing, disable TLS (normally required for HTTP/2)
    }, handler);
    defer server.deinit();

    std.debug.print("Starting HTTP/2 server...\n", .{});
    std.debug.print("Note: This is a basic implementation. TLS with ALPN negotiation recommended.\n", .{});
    try server.listen();
}
