const std = @import("std");
const build_options = @import("build_options");
const Method = @import("method.zig").Method;
const Header = @import("header.zig");
const Response = @import("response.zig").Response;
const h3_frame = @import("http3/frame.zig");
const qpack = @import("http3/qpack.zig");

// Conditionally import zquic
const zquic = if (build_options.engine_h3 and !std.mem.eql(u8, build_options.quic_backend, "none"))
    @import("zquic")
else
    struct {};

/// HTTP/3 Server request
pub const Http3ServerRequest = struct {
    method: Method,
    path: []const u8,
    authority: []const u8,
    scheme: []const u8,
    headers: Header.HeaderMap,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Http3ServerRequest) void {
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

/// HTTP/3 Server response
pub const Http3ServerResponse = struct {
    stream: if (build_options.engine_h3 and !std.mem.eql(u8, build_options.quic_backend, "none")) *zquic.Stream else *void,
    status: u16 = 200,
    headers: Header.HeaderMap,
    allocator: std.mem.Allocator,
    headers_sent: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        stream: if (build_options.engine_h3 and !std.mem.eql(u8, build_options.quic_backend, "none")) *zquic.Stream else *void,
    ) Http3ServerResponse {
        return .{
            .stream = stream,
            .headers = Header.HeaderMap.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Http3ServerResponse) void {
        self.headers.deinit();
    }

    pub fn setStatus(self: *Http3ServerResponse, status: u16) void {
        self.status = status;
    }

    pub fn setHeader(self: *Http3ServerResponse, name: []const u8, value: []const u8) !void {
        try self.headers.set(name, value);
    }

    /// Send response
    pub fn send(self: *Http3ServerResponse, body: []const u8) !void {
        if (comptime !build_options.engine_h3 or std.mem.eql(u8, build_options.quic_backend, "none")) {
            return error.Http3NotEnabled;
        }

        if (self.headers_sent) return error.HeadersAlreadySent;

        // Encode headers using QPACK
        var header_aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer header_aw.deinit();

        // Encode :status pseudo-header
        const status_str = try std.fmt.allocPrint(self.allocator, "{d}", .{self.status});
        defer self.allocator.free(status_str);
        try qpack.encodeHeader(&header_aw.writer, ":status", status_str);

        // Encode regular headers
        for (self.headers.items()) |header| {
            try qpack.encodeHeader(&header_aw.writer, header.name, header.value);
        }

        const header_block = header_aw.writer.buffered();

        // Create HEADERS frame
        var frame_aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer frame_aw.deinit();

        try h3_frame.VarInt.encode(&frame_aw.writer, h3_frame.FrameType.headers.toInt());
        try h3_frame.VarInt.encode(&frame_aw.writer, header_block.len);
        try frame_aw.writer.writeVec(&[_][]const u8{header_block});

        // Send headers
        try self.stream.write(frame_aw.writer.buffered());

        self.headers_sent = true;

        // Send body if present (as DATA frame)
        if (body.len > 0) {
            var data_aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer data_aw.deinit();

            try h3_frame.VarInt.encode(&data_aw.writer, h3_frame.FrameType.data.toInt());
            try h3_frame.VarInt.encode(&data_aw.writer, body.len);
            try data_aw.writer.writeVec(&[_][]const u8{body});

            try self.stream.write(data_aw.writer.buffered());
        }

        // Finish the stream
        try self.stream.finish();
    }

    pub fn sendText(self: *Http3ServerResponse, text: []const u8) !void {
        try self.setHeader("content-type", "text/plain; charset=utf-8");
        try self.send(text);
    }

    pub fn sendJson(self: *Http3ServerResponse, json: []const u8) !void {
        try self.setHeader("content-type", "application/json; charset=utf-8");
        try self.send(json);
    }
};

/// HTTP/3 Server handler
pub const Http3Handler = *const fn (
    req: *Http3ServerRequest,
    res: *Http3ServerResponse,
) anyerror!void;

/// HTTP/3 Server options
pub const Http3ServerOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 443,
    max_connections: u32 = 1000,
    max_concurrent_streams: u32 = 100,
    enable_0rtt: bool = false,
    cert_path: []const u8,
    key_path: []const u8,
};

/// HTTP/3 Server
pub const Http3Server = struct {
    allocator: std.mem.Allocator,
    options: Http3ServerOptions,
    quic_listener: if (build_options.engine_h3 and !std.mem.eql(u8, build_options.quic_backend, "none")) ?*zquic.Listener else ?*void,
    handler: Http3Handler,
    running: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Http3ServerOptions, handler: Http3Handler) Http3Server {
        return .{
            .allocator = allocator,
            .options = options,
            .quic_listener = null,
            .handler = handler,
        };
    }

    pub fn deinit(self: *Http3Server) void {
        if (comptime !build_options.engine_h3 or std.mem.eql(u8, build_options.quic_backend, "none")) {
            return;
        }

        if (self.quic_listener) |listener| {
            listener.close();
            self.quic_listener = null;
        }
    }

    pub fn listen(self: *Http3Server) !void {
        if (comptime !build_options.engine_h3 or std.mem.eql(u8, build_options.quic_backend, "none")) {
            return error.Http3NotEnabled;
        }

        // Create QUIC listener
        const listener = try zquic.Listener.bind(
            self.allocator,
            self.options.host,
            self.options.port,
            .{
                .alpn = &[_][]const u8{"h3"},
                .cert_path = self.options.cert_path,
                .key_path = self.options.key_path,
                .enable_0rtt = self.options.enable_0rtt,
            },
        );

        self.quic_listener = listener;
        self.running = true;

        std.debug.print("HTTP/3 Server listening on {s}:{d}\n", .{ self.options.host, self.options.port });

        while (self.running) {
            const connection = listener.accept() catch |err| {
                std.debug.print("Failed to accept connection: {}\n", .{err});
                continue;
            };

            // Handle connection (in production, spawn thread/task)
            self.handleConnection(connection) catch |err| {
                std.debug.print("Error handling connection: {}\n", .{err});
            };
        }
    }

    fn handleConnection(self: *Http3Server, connection: anytype) !void {
        defer connection.close();

        // Read control stream settings
        // In HTTP/3, client sends settings on control stream (stream 0 or 2)
        // For simplicity, we'll process request streams directly

        while (true) {
            // Accept incoming stream
            const stream = connection.acceptStream() catch |err| {
                if (err == error.NoMoreStreams) break;
                return err;
            };

            // Handle stream
            try self.handleStream(stream);
        }
    }

    fn handleStream(self: *Http3Server, stream: anytype) !void {
        defer stream.close();

        // Read frames from stream
        var request: ?Http3ServerRequest = null;
        var request_body: std.ArrayList(u8) = .{};

        while (true) {
            // Read frame type
            const frame_type_int = h3_frame.VarInt.decode(stream.reader()) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            const frame_type = h3_frame.FrameType.fromInt(frame_type_int);

            // Read frame length
            const frame_length = try h3_frame.VarInt.decode(stream.reader());

            switch (frame_type) {
                .headers => {
                    // Read header block
                    const header_data = try self.allocator.alloc(u8, @intCast(frame_length));
                    defer self.allocator.free(header_data);
                    _ = try stream.read(header_data);

                    // Parse request from headers
                    request = try self.parseRequestFromHeaders(header_data);
                },

                .data => {
                    // Read data
                    const data = try self.allocator.alloc(u8, @intCast(frame_length));
                    defer self.allocator.free(data);
                    _ = try stream.read(data);

                    try request_body.appendSlice(self.allocator, data);
                },

                else => {
                    // Unknown frame - skip
                    try stream.reader().skipBytes(@intCast(frame_length), .{});
                },
            }
        }

        if (request) |*req| {
            defer req.deinit();

            // Set body
            req.body = try request_body.toOwnedSlice(self.allocator);

            // Create response
            var response = Http3ServerResponse.init(self.allocator, stream);
            defer response.deinit();

            // Call handler
            self.handler(req, &response) catch |err| {
                std.debug.print("Handler error: {}\n", .{err});
                if (!response.headers_sent) {
                    response.setStatus(500);
                    try response.sendText("Internal Server Error");
                }
            };
        }
    }

    fn parseRequestFromHeaders(self: *Http3Server, header_data: []const u8) !Http3ServerRequest {
        var method: ?Method = null;
        var path: ?[]const u8 = null;
        var authority: ?[]const u8 = null;
        var scheme: ?[]const u8 = null;
        var header_map = Header.HeaderMap.init(self.allocator);

        var offset: usize = 0;
        while (offset < header_data.len) {
            const header = try qpack.decodeHeader(header_data[offset..]);
            offset += header.bytes_consumed;

            if (std.mem.eql(u8, header.name, ":method")) {
                method = Method.fromString(header.value);
                self.allocator.free(header.name);
                self.allocator.free(header.value);
            } else if (std.mem.eql(u8, header.name, ":path")) {
                path = header.value;
                self.allocator.free(header.name);
            } else if (std.mem.eql(u8, header.name, ":authority")) {
                authority = header.value;
                self.allocator.free(header.name);
            } else if (std.mem.eql(u8, header.name, ":scheme")) {
                scheme = header.value;
                self.allocator.free(header.name);
            } else if (!std.mem.startsWith(u8, header.name, ":")) {
                try header_map.append(header.name, header.value);
                self.allocator.free(header.name);
                self.allocator.free(header.value);
            }
        }

        return Http3ServerRequest{
            .method = method orelse return error.MissingMethod,
            .path = path orelse return error.MissingPath,
            .authority = authority orelse "",
            .scheme = scheme orelse "https",
            .headers = header_map,
            .body = &[_]u8{},
            .allocator = self.allocator,
        };
    }

    pub fn stop(self: *Http3Server) void {
        self.running = false;
    }
};
