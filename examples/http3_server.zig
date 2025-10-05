const std = @import("std");
const zhttp = @import("zhttp");
const build_options = @import("build_options");

fn handler(req: *zhttp.Http3.ServerRequest, res: *zhttp.Http3.ServerResponse) !void {
    std.debug.print("{s} {s}\n", .{ req.method.toString(), req.path });

    if (std.mem.eql(u8, req.path, "/")) {
        try res.setHeader("content-type", "text/html; charset=utf-8");
        try res.send(
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>zhttp HTTP/3 Server</title></head>
            \\<body>
            \\  <h1>Welcome to zhttp HTTP/3 Server!</h1>
            \\  <p>This server runs over QUIC protocol!</p>
            \\  <ul>
            \\    <li><a href="/hello">GET /hello</a></li>
            \\    <li><a href="/json">GET /json</a></li>
            \\  </ul>
            \\</body>
            \\</html>
        );
    } else if (std.mem.eql(u8, req.path, "/hello")) {
        try res.sendText("Hello from zhttp HTTP/3 server over QUIC!");
    } else if (std.mem.eql(u8, req.path, "/json")) {
        try res.sendJson(
            \\{"message": "Hello, World!", "server": "zhttp", "protocol": "HTTP/3", "transport": "QUIC"}
        );
    } else {
        res.setStatus(404);
        try res.sendText("Not Found");
    }
}

pub fn main() !void {
    if (!build_options.engine_h3) {
        std.debug.print("HTTP/3 is not enabled. Build with -Dengine_h3=true -Dquic_backend=zquic\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Note: You need to provide TLS certificates for HTTP/3
    const cert_path = "cert.pem";
    const key_path = "key.pem";

    var server = zhttp.Http3.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 443,
        .cert_path = cert_path,
        .key_path = key_path,
        .enable_0rtt = false,
    }, handler);
    defer server.deinit();

    std.debug.print("Starting HTTP/3 server...\n", .{});
    std.debug.print("Note: Requires valid TLS certificates at {s} and {s}\n", .{ cert_path, key_path });
    try server.listen();
}
