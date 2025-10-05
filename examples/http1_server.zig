const std = @import("std");
const zhttp = @import("zhttp");

fn handler(req: *zhttp.ServerRequest, res: *zhttp.ServerResponse) !void {
    std.debug.print("{s} {s}\n", .{ req.method.toString(), req.path });

    if (std.mem.eql(u8, req.pathWithoutQuery(), "/")) {
        try res.sendHtml(
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>zhttp HTTP/1.1 Server</title></head>
            \\<body>
            \\  <h1>Welcome to zhttp HTTP/1.1 Server!</h1>
            \\  <p>Try these endpoints:</p>
            \\  <ul>
            \\    <li><a href="/hello">GET /hello</a></li>
            \\    <li><a href="/json">GET /json</a></li>
            \\    <li><a href="/echo">POST /echo</a></li>
            \\  </ul>
            \\</body>
            \\</html>
        );
    } else if (std.mem.eql(u8, req.path, "/hello")) {
        try res.sendText("Hello from zhttp HTTP/1.1 server!");
    } else if (std.mem.eql(u8, req.path, "/json")) {
        try res.sendJson(
            \\{"message": "Hello, World!", "server": "zhttp", "protocol": "HTTP/1.1"}
        );
    } else if (std.mem.eql(u8, req.path, "/echo")) {
        if (req.method == .POST) {
            try res.setHeader("Content-Type", "text/plain");
            try res.send(req.body);
        } else {
            res.setStatus(405);
            try res.sendText("Method Not Allowed");
        }
    } else {
        res.setStatus(404);
        try res.sendText("Not Found");
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = zhttp.Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 8080,
    }, handler);
    defer server.deinit();

    std.debug.print("Starting HTTP/1.1 server...\n", .{});
    try server.listen();
}
