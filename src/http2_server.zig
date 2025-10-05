const std = @import("std");
const net = std.net;
const Method = @import("method.zig").Method;
const Header = @import("header.zig");
const Response = @import("response.zig").Response;
const frame = @import("http2/frame.zig");
const hpack = @import("http2/hpack.zig");
const stream_mod = @import("http2/stream.zig");
const Stream = stream_mod.Stream;
const Connection = stream_mod.Connection;

/// HTTP/2 Server request
pub const Http2ServerRequest = struct {
    method: Method,
    path: []const u8,
    authority: []const u8,
    scheme: []const u8,
    headers: Header.HeaderMap,
    body: []const u8,
    stream_id: u31,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Http2ServerRequest) void {
        self.headers.deinit();
        if (self.body.len > 0) {
            self.allocator.free(self.body);
        }
        if (self.path.len > 0) {
            self.allocator.free(self.path);
        }
        if (self.authority.len > 0) {
            self.allocator.free(self.authority);
        }
        if (self.scheme.len > 0) {
            self.allocator.free(self.scheme);
        }
    }
};

/// HTTP/2 Server response
pub const Http2ServerResponse = struct {
    stream: net.Stream,
    stream_id: u31,
    status: u16 = 200,
    headers: Header.HeaderMap,
    encoder: *hpack.Encoder,
    allocator: std.mem.Allocator,
    headers_sent: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        stream: net.Stream,
        stream_id: u31,
        encoder: *hpack.Encoder,
    ) Http2ServerResponse {
        return .{
            .stream = stream,
            .stream_id = stream_id,
            .headers = Header.HeaderMap.init(allocator),
            .encoder = encoder,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Http2ServerResponse) void {
        self.headers.deinit();
    }

    pub fn setStatus(self: *Http2ServerResponse, status: u16) void {
        self.status = status;
    }

    pub fn setHeader(self: *Http2ServerResponse, name: []const u8, value: []const u8) !void {
        try self.headers.set(name, value);
    }

    /// Send response
    pub fn send(self: *Http2ServerResponse, body: []const u8) !void {
        if (self.headers_sent) return error.HeadersAlreadySent;

        // Encode headers
        var header_block = std.ArrayList(u8).init(self.allocator);
        defer header_block.deinit();

        // Encode :status pseudo-header
        const status_str = try std.fmt.allocPrint(self.allocator, "{d}", .{self.status});
        defer self.allocator.free(status_str);
        try self.encoder.encodeHeader(header_block.writer(), ":status", status_str);

        // Encode regular headers
        for (self.headers.items()) |header| {
            try self.encoder.encodeHeader(header_block.writer(), header.name, header.value);
        }

        // Send HEADERS frame
        const headers_flags = frame.FrameFlags.END_HEADERS |
            (if (body.len == 0) frame.FrameFlags.END_STREAM else 0);

        const headers_frame = frame.FrameHeader.init(
            .headers,
            headers_flags,
            self.stream_id,
            @intCast(header_block.items.len),
        );

        var frame_buf = std.ArrayList(u8).init(self.allocator);
        defer frame_buf.deinit();

        try headers_frame.encode(frame_buf.writer());
        try frame_buf.appendSlice(header_block.items);
        try self.stream.writeAll(frame_buf.items);

        self.headers_sent = true;

        // Send body if present
        if (body.len > 0) {
            const data_frame = frame.FrameHeader.init(
                .data,
                frame.FrameFlags.END_STREAM,
                self.stream_id,
                @intCast(body.len),
            );

            var data_buf = std.ArrayList(u8).init(self.allocator);
            defer data_buf.deinit();

            try data_frame.encode(data_buf.writer());
            try data_buf.appendSlice(body);
            try self.stream.writeAll(data_buf.items);
        }
    }

    pub fn sendText(self: *Http2ServerResponse, text: []const u8) !void {
        try self.setHeader("content-type", "text/plain; charset=utf-8");
        try self.send(text);
    }

    pub fn sendJson(self: *Http2ServerResponse, json: []const u8) !void {
        try self.setHeader("content-type", "application/json; charset=utf-8");
        try self.send(json);
    }
};

/// HTTP/2 Server handler
pub const Http2Handler = *const fn (
    req: *Http2ServerRequest,
    res: *Http2ServerResponse,
) anyerror!void;

/// HTTP/2 Server options
pub const Http2ServerOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8443,
    max_connections: u32 = 1000,
    max_concurrent_streams: u32 = 100,
    initial_window_size: i32 = 65535,
    enable_push: bool = false,
    enable_tls: bool = true, // HTTP/2 typically requires TLS
};

/// HTTP/2 Server
pub const Http2Server = struct {
    allocator: std.mem.Allocator,
    options: Http2ServerOptions,
    listener: ?net.Server = null,
    handler: Http2Handler,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Http2ServerOptions, handler: Http2Handler) Http2Server {
        return .{
            .allocator = allocator,
            .options = options,
            .handler = handler,
        };
    }

    pub fn deinit(self: *Http2Server) void {
        if (self.listener) |*listener| {
            listener.deinit();
        }
    }

    pub fn listen(self: *Http2Server) !void {
        const address = try net.Address.parseIp(self.options.host, self.options.port);

        var listener = try address.listen(.{
            .reuse_address = true,
        });
        self.listener = listener;
        self.running = true;

        std.debug.print("HTTP/2 Server listening on {s}:{d}\n", .{ self.options.host, self.options.port });

        while (self.running) {
            const connection = listener.accept() catch |err| {
                std.debug.print("Failed to accept connection: {}\n", .{err});
                continue;
            };

            self.handleConnection(connection) catch |err| {
                std.debug.print("Error handling connection: {}\n", .{err});
                connection.stream.close();
            };
        }
    }

    fn handleConnection(self: *Http2Server, connection: net.Server.Connection) !void {
        defer connection.stream.close();

        var read_buf: [8192]u8 = undefined;
        const reader = connection.stream.reader(&read_buf);

        // Read HTTP/2 connection preface
        var preface_buf: [24]u8 = undefined;
        _ = try reader.readAll(&preface_buf);

        const expected_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
        if (!std.mem.eql(u8, &preface_buf, expected_preface)) {
            return error.InvalidPreface;
        }

        // Initialize HTTP/2 connection
        var conn = try Connection.init(self.allocator, false); // false = server
        defer conn.deinit();

        conn.settings.enable_push = self.options.enable_push;
        conn.settings.max_concurrent_streams = self.options.max_concurrent_streams;
        conn.settings.initial_window_size = self.options.initial_window_size;

        // Send initial SETTINGS frame
        try conn.sendSettings(connection.stream.writer(), false);

        // Process frames
        while (true) {
            const frame_header = frame.FrameHeader.decode(reader) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };

            try self.processFrame(&conn, frame_header, reader, connection.stream);
        }
    }

    fn processFrame(
        self: *Http2Server,
        conn: *Connection,
        frame_header: frame.FrameHeader,
        reader: anytype,
        stream: net.Stream,
    ) !void {
        switch (frame_header.type) {
            .headers => {
                // Read header block
                const header_data = try self.allocator.alloc(u8, frame_header.length);
                defer self.allocator.free(header_data);
                _ = try reader.readAll(header_data);

                // Decode HPACK headers
                var decoded_headers = try conn.decoder.decodeHeaderBlock(header_data);
                defer {
                    for (decoded_headers.items) |h| {
                        self.allocator.free(h.name);
                        self.allocator.free(h.value);
                    }
                    decoded_headers.deinit();
                }

                // Parse request from headers
                var request = try self.parseRequestFromHeaders(decoded_headers.items, frame_header.stream_id);
                defer request.deinit();

                // Create response
                var response = Http2ServerResponse.init(
                    self.allocator,
                    stream,
                    frame_header.stream_id,
                    &conn.encoder,
                );
                defer response.deinit();

                // Call handler
                self.handler(&request, &response) catch |err| {
                    std.debug.print("Handler error: {}\n", .{err});
                    if (!response.headers_sent) {
                        response.setStatus(500);
                        try response.sendText("Internal Server Error");
                    }
                };
            },

            .data => {
                // TODO: Handle data frames
                try reader.skipBytes(frame_header.length, .{});
            },

            .settings => {
                const settings_frame = try frame.SettingsFrame.decode(self.allocator, frame_header, reader);
                defer self.allocator.free(settings_frame.settings);

                if ((frame_header.flags & frame.FrameFlags.ACK) == 0) {
                    // Send SETTINGS ACK
                    try conn.sendSettings(stream.writer(), true);
                }
            },

            .window_update, .ping, .goaway, .rst_stream => {
                try conn.processFrame(frame_header, reader);
            },

            else => {
                // Unknown frame - skip
                try reader.skipBytes(frame_header.length, .{});
            },
        }
    }

    fn parseRequestFromHeaders(
        self: *Http2Server,
        headers: []const hpack.HeaderField,
        stream_id: u31,
    ) !Http2ServerRequest {
        var method: ?Method = null;
        var path: ?[]const u8 = null;
        var authority: ?[]const u8 = null;
        var scheme: ?[]const u8 = null;
        var header_map = Header.HeaderMap.init(self.allocator);

        for (headers) |h| {
            if (std.mem.eql(u8, h.name, ":method")) {
                method = Method.fromString(h.value);
            } else if (std.mem.eql(u8, h.name, ":path")) {
                path = try self.allocator.dupe(u8, h.value);
            } else if (std.mem.eql(u8, h.name, ":authority")) {
                authority = try self.allocator.dupe(u8, h.value);
            } else if (std.mem.eql(u8, h.name, ":scheme")) {
                scheme = try self.allocator.dupe(u8, h.value);
            } else if (!std.mem.startsWith(u8, h.name, ":")) {
                try header_map.append(h.name, h.value);
            }
        }

        return Http2ServerRequest{
            .method = method orelse return error.MissingMethod,
            .path = path orelse return error.MissingPath,
            .authority = authority orelse "",
            .scheme = scheme orelse "https",
            .headers = header_map,
            .body = &[_]u8{},
            .stream_id = stream_id,
            .allocator = self.allocator,
        };
    }

    pub fn stop(self: *Http2Server) void {
        self.running = false;
    }
};
