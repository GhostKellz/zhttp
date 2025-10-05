const std = @import("std");
const net = std.net;
const Method = @import("method.zig").Method;
const Header = @import("header.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const frame = @import("http2/frame.zig");
const hpack = @import("http2/hpack.zig");
const stream_mod = @import("http2/stream.zig");
const Stream = stream_mod.Stream;
const Connection = stream_mod.Connection;

/// HTTP/2 Client configuration
pub const Http2ClientOptions = struct {
    /// Connection timeout in milliseconds
    connect_timeout: u64 = 10000,
    /// Read timeout in milliseconds
    read_timeout: u64 = 30000,
    /// Maximum concurrent streams
    max_concurrent_streams: u32 = 100,
    /// Initial window size
    initial_window_size: i32 = 65535,
    /// Enable server push
    enable_push: bool = false,
};

/// HTTP/2 Client
pub const Http2Client = struct {
    allocator: std.mem.Allocator,
    options: Http2ClientOptions,
    connection: ?Connection = null,
    stream_handle: ?net.Stream = null,
    connected: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Http2ClientOptions) Http2Client {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn deinit(self: *Http2Client) void {
        if (self.connection) |*conn| {
            conn.deinit();
        }
        if (self.stream_handle) |stream| {
            stream.close();
        }
    }

    /// Connect to HTTP/2 server
    pub fn connect(self: *Http2Client, host: []const u8, port: u16, use_tls: bool) !void {
        const address = try net.Address.parseIp(host, port);
        const stream = try net.tcpConnectToAddress(address);
        self.stream_handle = stream;

        // For TLS connections, ALPN should negotiate "h2"
        _ = use_tls; // TODO: Implement TLS with ALPN

        // Send HTTP/2 connection preface
        try stream.writeAll("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n");

        // Initialize HTTP/2 connection
        var conn = try Connection.init(self.allocator, true); // true = client
        conn.settings.enable_push = self.options.enable_push;
        conn.settings.max_concurrent_streams = self.options.max_concurrent_streams;
        conn.settings.initial_window_size = self.options.initial_window_size;

        self.connection = conn;

        // Send initial SETTINGS frame
        var settings_buf = std.ArrayList(u8).init(self.allocator);
        defer settings_buf.deinit();

        try self.connection.?.sendSettings(settings_buf.writer(), false);
        try stream.writeAll(settings_buf.items);

        self.connected = true;
    }

    /// Send HTTP/2 request
    pub fn send(self: *Http2Client, request: Request) !Response {
        if (!self.connected) return error.NotConnected;
        if (self.connection == null) return error.NotConnected;

        var conn = &self.connection.?;
        const stream_handle = self.stream_handle.?;

        // Create new stream
        const http2_stream = try conn.createStream();

        // Encode headers using HPACK
        var header_block = std.ArrayList(u8).init(self.allocator);
        defer header_block.deinit();

        // Add pseudo-headers (required for HTTP/2)
        try conn.encoder.encodeHeader(header_block.writer(), ":method", request.method.toString());
        try conn.encoder.encodeHeader(header_block.writer(), ":path", request.url);
        try conn.encoder.encodeHeader(header_block.writer(), ":scheme", "https"); // TODO: Detect scheme

        // Extract authority from headers or construct from URL
        const authority = request.headers.get("Host") orelse "localhost";
        try conn.encoder.encodeHeader(header_block.writer(), ":authority", authority);

        // Encode regular headers
        for (request.headers.items()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "Host")) {
                try conn.encoder.encodeHeader(header_block.writer(), header.name, header.value);
            }
        }

        // Create HEADERS frame
        const headers_frame = frame.FrameHeader.init(
            .headers,
            frame.FrameFlags.END_HEADERS | (if (request.body.isEmpty()) frame.FrameFlags.END_STREAM else 0),
            http2_stream.id,
            @intCast(header_block.items.len),
        );

        // Send HEADERS frame
        var frame_buf = std.ArrayList(u8).init(self.allocator);
        defer frame_buf.deinit();

        try headers_frame.encode(frame_buf.writer());
        try frame_buf.appendSlice(header_block.items);
        try stream_handle.writeAll(frame_buf.items);

        // Send body if present
        if (!request.body.isEmpty()) {
            // TODO: Implement body sending with proper chunking
            // For now, we'll skip body support
        }

        // Read response
        return try self.readResponse(http2_stream.id);
    }

    /// Read HTTP/2 response
    fn readResponse(self: *Http2Client, stream_id: u31) !Response {
        if (self.connection == null) return error.NotConnected;
        const stream_handle = self.stream_handle.?;
        var conn = &self.connection.?;

        var read_buf: [8192]u8 = undefined;
        const reader = stream_handle.reader(&read_buf);

        var response_headers: ?Header.HeaderMap = null;
        var response_status: u16 = 0;
        var response_body = std.ArrayList(u8).init(self.allocator);

        while (true) {
            // Read frame header
            const frame_header = try frame.FrameHeader.decode(reader);

            // Only process frames for our stream (or connection-level frames)
            if (frame_header.stream_id != stream_id and frame_header.stream_id != 0) {
                // Skip frames for other streams
                try reader.skipBytes(frame_header.length, .{});
                continue;
            }

            switch (frame_header.type) {
                .headers => {
                    // Read and decode headers
                    const header_data = try self.allocator.alloc(u8, frame_header.length);
                    defer self.allocator.free(header_data);
                    _ = try reader.readAll(header_data);

                    var decoded_headers = try conn.decoder.decodeHeaderBlock(header_data);
                    defer decoded_headers.deinit();

                    // Parse headers
                    var headers = Header.HeaderMap.init(self.allocator);
                    for (decoded_headers.items) |h| {
                        if (std.mem.eql(u8, h.name, ":status")) {
                            response_status = try std.fmt.parseInt(u16, h.value, 10);
                        } else if (!std.mem.startsWith(u8, h.name, ":")) {
                            // Regular header
                            try headers.append(h.name, h.value);
                        }
                        self.allocator.free(h.name);
                        self.allocator.free(h.value);
                    }

                    response_headers = headers;

                    // Check for END_STREAM flag
                    if ((frame_header.flags & frame.FrameFlags.END_STREAM) != 0) {
                        break;
                    }
                },

                .data => {
                    // Read data
                    const data = try self.allocator.alloc(u8, frame_header.length);
                    defer self.allocator.free(data);
                    _ = try reader.readAll(data);

                    try response_body.appendSlice(data);

                    // Update flow control
                    conn.local_window_size -= @intCast(data.len);

                    // Check for END_STREAM flag
                    if ((frame_header.flags & frame.FrameFlags.END_STREAM) != 0) {
                        break;
                    }
                },

                .settings => {
                    // Handle settings
                    const settings_frame = try frame.SettingsFrame.decode(self.allocator, frame_header, reader);
                    defer self.allocator.free(settings_frame.settings);

                    if ((frame_header.flags & frame.FrameFlags.ACK) == 0) {
                        // Send SETTINGS ACK
                        var ack_buf = std.ArrayList(u8).init(self.allocator);
                        defer ack_buf.deinit();
                        try conn.sendSettings(ack_buf.writer(), true);
                        try stream_handle.writeAll(ack_buf.items);
                    }
                },

                .window_update, .ping, .goaway => {
                    // Process connection-level frames
                    try conn.processFrame(frame_header, reader);
                },

                else => {
                    // Unknown frame - skip
                    try reader.skipBytes(frame_header.length, .{});
                },
            }
        }

        // Construct response
        const headers = response_headers orelse Header.HeaderMap.init(self.allocator);

        return Response{
            .status = response_status,
            .headers = headers,
            .body = @import("body.zig").Body{ .bytes = try response_body.toOwnedSlice() },
            .version = .http_2_0,
            .allocator = self.allocator,
        };
    }

    /// Close the connection
    pub fn close(self: *Http2Client) void {
        self.connected = false;
        if (self.stream_handle) |stream| {
            stream.close();
            self.stream_handle = null;
        }
    }
};
