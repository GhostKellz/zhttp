const std = @import("std");
const Io = std.Io;
const net = Io.net;
const compat = @import("compat.zig");
const Method = @import("method.zig").Method;
const Header = @import("header.zig");
const Body = @import("body.zig").Body;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Http1 = @import("http1.zig").Http1;
const Error = @import("error.zig").Error;

/// HTTP/1.1 Server configuration
pub const ServerOptions = struct {
    /// Server host address
    host: []const u8 = "127.0.0.1",
    /// Server port
    port: u16 = 8080,
    /// Maximum concurrent connections
    max_connections: u32 = 1000,
    /// Read timeout in milliseconds
    read_timeout: u64 = 30000,
    /// Write timeout in milliseconds
    write_timeout: u64 = 30000,
    /// Maximum request header size
    max_header_size: usize = 8 * 1024, // 8KB
    /// Maximum request body size
    max_body_size: usize = 10 * 1024 * 1024, // 10MB
    /// Keep-alive timeout in milliseconds
    keepalive_timeout: u64 = 60000,
    /// Enable TLS
    enable_tls: bool = false,
    /// TLS certificate path
    tls_cert_path: ?[]const u8 = null,
    /// TLS key path
    tls_key_path: ?[]const u8 = null,
};

/// HTTP Server request context
pub const ServerRequest = struct {
    method: Method,
    path: []const u8,
    version: Response.HttpVersion,
    headers: Header.HeaderMap,
    body: []const u8,
    remote_addr: net.IpAddress,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ServerRequest) void {
        self.headers.deinit();
        if (self.body.len > 0) {
            self.allocator.free(self.body);
        }
        if (self.path.len > 0) {
            self.allocator.free(self.path);
        }
    }

    /// Get query parameters from path
    pub fn query(self: ServerRequest) ?[]const u8 {
        const q = std.mem.indexOfScalar(u8, self.path, '?') orelse return null;
        return self.path[q + 1 ..];
    }

    /// Get path without query string
    pub fn pathWithoutQuery(self: ServerRequest) []const u8 {
        const q = std.mem.indexOfScalar(u8, self.path, '?') orelse return self.path;
        return self.path[0..q];
    }
};

/// HTTP Server response builder
pub const ServerResponse = struct {
    stream: net.Stream,
    status: u16 = 200,
    headers: Header.HeaderMap,
    body_sent: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, stream: net.Stream) ServerResponse {
        return .{
            .stream = stream,
            .headers = Header.HeaderMap.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ServerResponse) void {
        self.headers.deinit();
    }

    /// Set response status code
    pub fn setStatus(self: *ServerResponse, status: u16) void {
        self.status = status;
    }

    /// Set a response header
    pub fn setHeader(self: *ServerResponse, name: []const u8, value: []const u8) !void {
        try self.headers.set(name, value);
    }

    /// Send response with text body
    pub fn sendText(self: *ServerResponse, text: []const u8) !void {
        try self.setHeader("Content-Type", "text/plain; charset=utf-8");
        try self.send(text);
    }

    /// Send response with JSON body
    pub fn sendJson(self: *ServerResponse, json: []const u8) !void {
        try self.setHeader("Content-Type", "application/json; charset=utf-8");
        try self.send(json);
    }

    /// Send response with HTML body
    pub fn sendHtml(self: *ServerResponse, html: []const u8) !void {
        try self.setHeader("Content-Type", "text/html; charset=utf-8");
        try self.send(html);
    }

    /// Send response with custom body
    pub fn send(self: *ServerResponse, body: []const u8) !void {
        if (self.body_sent) return error.BodyAlreadySent;

        // Set Content-Length if not already set
        if (!self.headers.has("Content-Length")) {
            const len_str = try std.fmt.allocPrint(self.allocator, "{d}", .{body.len});
            defer self.allocator.free(len_str);
            try self.headers.set("Content-Length", len_str);
        }

        // Write status line
        const status_text = getStatusText(self.status);
        const status_line = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 {d} {s}\r\n",
            .{ self.status, status_text },
        );
        defer self.allocator.free(status_line);
        try compat.writeAll(self.stream, status_line);

        // Write headers
        for (self.headers.items()) |header| {
            const header_line = try std.fmt.allocPrint(
                self.allocator,
                "{s}: {s}\r\n",
                .{ header.name, header.value },
            );
            defer self.allocator.free(header_line);
            try compat.writeAll(self.stream, header_line);
        }

        // End headers
        try compat.writeAll(self.stream, "\r\n");

        // Write body
        try compat.writeAll(self.stream, body);

        self.body_sent = true;
    }

    /// Send empty response (status only)
    pub fn sendStatus(self: *ServerResponse) !void {
        try self.send(&[_]u8{});
    }
};

/// Request handler function signature
pub const Handler = *const fn (
    req: *ServerRequest,
    res: *ServerResponse,
) anyerror!void;

/// HTTP/1.1 Server
pub const Server = struct {
    allocator: std.mem.Allocator,
    options: ServerOptions,
    listener: ?net.Server = null,
    handler: Handler,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: ServerOptions, handler: Handler) Server {
        return .{
            .allocator = allocator,
            .options = options,
            .handler = handler,
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.listener) |*listener| {
            listener.deinit();
        }
    }

    /// Start the server
    pub fn listen(self: *Server) !void {
        const address = try net.IpAddress.parse(self.options.host, self.options.port);

        // Use Io.Threaded for blocking server
        var io = Io.Threaded.init(self.allocator);
        defer io.deinit();

        var listener = try address.listen(io.io(), .{
            .reuse_address = true,
        });
        self.listener = listener;
        self.running = true;

        std.debug.print("HTTP/1.1 Server listening on {s}:{d}\n", .{ self.options.host, self.options.port });

        while (self.running) {
            const connection = listener.accept() catch |err| {
                std.debug.print("Failed to accept connection: {}\n", .{err});
                continue;
            };

            // Handle connection (for now, single-threaded)
            self.handleConnection(connection) catch |err| {
                std.debug.print("Error handling connection: {}\n", .{err});
                connection.stream.close();
            };
        }
    }

    /// Handle a single client connection
    fn handleConnection(self: *Server, connection: net.Server.Connection) !void {
        defer connection.stream.close();

        var keep_alive = true;
        while (keep_alive) {
            // Parse request
            var request = self.parseRequest(connection) catch |err| {
                if (err == error.EndOfStream or err == error.ConnectionResetByPeer) {
                    // Client closed connection
                    return;
                }
                // Send 400 Bad Request
                try compat.writeAll(connection.stream, "HTTP/1.1 400 Bad Request\r\n\r\n");
                return err;
            };
            defer request.deinit();

            // Create response
            var response = ServerResponse.init(self.allocator, connection.stream);
            defer response.deinit();

            // Call user handler
            self.handler(&request, &response) catch |err| {
                std.debug.print("Handler error: {}\n", .{err});
                if (!response.body_sent) {
                    response.setStatus(500);
                    try response.sendText("Internal Server Error");
                }
            };

            // Check if we should keep the connection alive
            keep_alive = Http1.shouldKeepAlive(request.version, request.headers);
            if (keep_alive) {
                const timeout = std.time.ns_per_ms * self.options.keepalive_timeout;
                _ = timeout; // TODO: Implement timeout
            } else {
                break;
            }
        }
    }

    /// Parse HTTP request from connection
    fn parseRequest(self: *Server, connection: net.Server.Connection) !ServerRequest {
        // Read until we have the full request headers
        var request_buf: [16384]u8 = undefined;
        var total_read: usize = 0;

        // Read headers
        while (total_read < request_buf.len) {
            const bytes_read = try connection.stream.read(request_buf[total_read..]);
            if (bytes_read == 0) return error.EndOfStream;
            total_read += bytes_read;

            // Check for end of headers (\r\n\r\n)
            if (total_read >= 4) {
                if (std.mem.indexOf(u8, request_buf[0..total_read], "\r\n\r\n")) |_| {
                    break;
                }
            }
        }

        const header_data = request_buf[0..total_read];

        // Find end of headers
        const headers_end = std.mem.indexOf(u8, header_data, "\r\n\r\n") orelse return error.InvalidRequest;
        const headers_section = header_data[0..headers_end];

        // Split into lines
        var lines = std.mem.splitSequence(u8, headers_section, "\r\n");

        // Parse request line
        const request_line = lines.next() orelse return error.InvalidRequestLine;
        var parts = std.mem.splitSequence(u8, request_line, " ");
        const method_str = parts.next() orelse return error.InvalidRequestLine;
        const path_str = parts.next() orelse return error.InvalidRequestLine;
        const version_str = parts.next() orelse return error.InvalidRequestLine;

        const method = Method.fromString(method_str) orelse return error.InvalidMethod;
        const path = try self.allocator.dupe(u8, path_str);
        const version = Response.HttpVersion.fromString(version_str) orelse return error.InvalidVersion;

        // Parse headers
        var headers = Header.HeaderMap.init(self.allocator);
        var content_length: usize = 0;

        while (lines.next()) |line| {
            if (line.len == 0) break;

            const header = try Http1.parseHeaderLine(line);
            try headers.append(header.name, header.value);

            if (std.ascii.eqlIgnoreCase(header.name, "content-length")) {
                content_length = try std.fmt.parseInt(usize, header.value, 10);
                if (content_length > self.options.max_body_size) {
                    return error.BodyTooLarge;
                }
            }
        }

        // Read body if present
        var body: []const u8 = &[_]u8{};
        if (content_length > 0) {
            const body_buf = try self.allocator.alloc(u8, content_length);

            // Check if we already read some body data
            const body_start = headers_end + 4;
            const already_read = if (total_read > body_start) total_read - body_start else 0;

            if (already_read > 0) {
                @memcpy(body_buf[0..already_read], header_data[body_start..total_read]);
            }

            // Read remaining body
            if (already_read < content_length) {
                var remaining = content_length - already_read;
                var offset = already_read;
                while (remaining > 0) {
                    const bytes_read = try connection.stream.read(body_buf[offset..content_length]);
                    if (bytes_read == 0) {
                        self.allocator.free(body_buf);
                        return error.IncompleteBody;
                    }
                    offset += bytes_read;
                    remaining -= bytes_read;
                }
            }

            body = body_buf;
        }

        return ServerRequest{
            .method = method,
            .path = path,
            .version = version,
            .headers = headers,
            .body = body,
            .remote_addr = connection.address,
            .allocator = self.allocator,
        };
    }

    /// Stop the server
    pub fn stop(self: *Server) void {
        self.running = false;
    }
};

/// Get HTTP status text for status code
fn getStatusText(status: u16) []const u8 {
    return switch (status) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        413 => "Payload Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Unknown",
    };
}

test "status text lookup" {
    try std.testing.expectEqualStrings("OK", getStatusText(200));
    try std.testing.expectEqualStrings("Not Found", getStatusText(404));
    try std.testing.expectEqualStrings("Internal Server Error", getStatusText(500));
}
