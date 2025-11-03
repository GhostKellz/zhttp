const std = @import("std");
const build_options = @import("build_options");
const Method = @import("method.zig").Method;
const Header = @import("header.zig");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const h3_frame = @import("http3/frame.zig");
const qpack = @import("http3/qpack.zig");

// Conditionally import zquic
const zquic = if (build_options.engine_h3 and !std.mem.eql(u8, build_options.quic_backend, "none"))
    @import("zquic")
else
    struct {};

/// HTTP/3 Client options
pub const Http3ClientOptions = struct {
    /// Connection timeout in milliseconds
    connect_timeout: u64 = 10000,
    /// Read timeout in milliseconds
    read_timeout: u64 = 30000,
    /// Maximum concurrent streams
    max_concurrent_streams: u32 = 100,
    /// Enable 0-RTT
    enable_0rtt: bool = false,
};

/// HTTP/3 Client
pub const Http3Client = struct {
    allocator: std.mem.Allocator,
    options: Http3ClientOptions,
    quic_connection: if (build_options.engine_h3 and !std.mem.eql(u8, build_options.quic_backend, "none")) ?*zquic.Connection else ?*void,
    connected: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Http3ClientOptions) Http3Client {
        return .{
            .allocator = allocator,
            .options = options,
            .quic_connection = null,
        };
    }

    pub fn deinit(self: *Http3Client) void {
        if (comptime !build_options.engine_h3 or std.mem.eql(u8, build_options.quic_backend, "none")) {
            return;
        }

        if (self.quic_connection) |conn| {
            conn.close();
            self.quic_connection = null;
        }
    }

    /// Connect to HTTP/3 server
    pub fn connect(self: *Http3Client, host: []const u8, port: u16) !void {
        if (comptime !build_options.engine_h3 or std.mem.eql(u8, build_options.quic_backend, "none")) {
            return error.Http3NotEnabled;
        }

        // Initialize QUIC connection
        const conn = try zquic.Connection.connect(
            self.allocator,
            host,
            port,
            .{
                .alpn = &[_][]const u8{"h3"},
                .enable_0rtt = self.options.enable_0rtt,
            },
        );

        self.quic_connection = conn;
        self.connected = true;

        // Send HTTP/3 SETTINGS frame on control stream (stream 0)
        try self.sendSettings(conn);
    }

    fn sendSettings(self: *Http3Client, conn: anytype) !void {
        var settings_aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer settings_aw.deinit();

        // Encode SETTINGS frame
        try h3_frame.VarInt.encode(&settings_aw.writer, h3_frame.FrameType.settings.toInt());

        // For now, send empty settings (will extend later)
        try h3_frame.VarInt.encode(&settings_aw.writer, 0); // Length = 0

        // Open control stream and send settings
        const control_stream = try conn.openStream(.unidirectional);
        try control_stream.write(settings_aw.writer.buffered());
    }

    /// Send HTTP/3 request
    pub fn send(self: *Http3Client, request: Request) !Response {
        if (comptime !build_options.engine_h3 or std.mem.eql(u8, build_options.quic_backend, "none")) {
            return error.Http3NotEnabled;
        }

        if (!self.connected or self.quic_connection == null) {
            return error.NotConnected;
        }

        const conn = self.quic_connection.?;

        // Open bidirectional stream for request
        const stream = try conn.openStream(.bidirectional);

        // Encode headers using QPACK
        var header_aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer header_aw.deinit();

        // Add pseudo-headers
        try qpack.encodeHeader(&header_aw.writer, ":method", request.method.toString());
        try qpack.encodeHeader(&header_aw.writer, ":path", request.url);
        try qpack.encodeHeader(&header_aw.writer, ":scheme", "https");

        const authority = request.headers.get("Host") orelse "localhost";
        try qpack.encodeHeader(&header_aw.writer, ":authority", authority);

        // Add regular headers
        for (request.headers.items()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "Host")) {
                try qpack.encodeHeader(&header_aw.writer, header.name, header.value);
            }
        }

        const header_block = header_aw.writer.buffered();

        // Create HEADERS frame
        var frame_aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer frame_aw.deinit();

        try h3_frame.VarInt.encode(&frame_aw.writer, h3_frame.FrameType.headers.toInt());
        try h3_frame.VarInt.encode(&frame_aw.writer, header_block.len);
        try frame_aw.writer.writeVec(&[_][]const u8{header_block});

        // Send frame
        try stream.write(frame_aw.writer.buffered());

        // Send body if present (as DATA frame)
        if (!request.body.isEmpty()) {
            // TODO: Implement body sending
        }

        // Read response
        return try self.readResponse(stream);
    }

    fn readResponse(self: *Http3Client, stream: anytype) !Response {
        var response_headers: ?Header.HeaderMap = null;
        var response_status: u16 = 0;
        var response_body: std.ArrayList(u8) = .{};

        while (true) {
            // Read frame type
            const frame_type_int = try h3_frame.VarInt.decode(stream.reader());
            const frame_type = h3_frame.FrameType.fromInt(frame_type_int);

            // Read frame length
            const frame_length = try h3_frame.VarInt.decode(stream.reader());

            switch (frame_type) {
                .headers => {
                    // Read header block
                    const header_data = try self.allocator.alloc(u8, @intCast(frame_length));
                    defer self.allocator.free(header_data);
                    _ = try stream.read(header_data);

                    // Decode QPACK headers
                    var headers = Header.HeaderMap.init(self.allocator);
                    var offset: usize = 0;

                    while (offset < header_data.len) {
                        const header = try qpack.decodeHeader(header_data[offset..]);
                        offset += header.bytes_consumed;

                        if (std.mem.eql(u8, header.name, ":status")) {
                            response_status = try std.fmt.parseInt(u16, header.value, 10);
                            self.allocator.free(header.name);
                            self.allocator.free(header.value);
                        } else if (!std.mem.startsWith(u8, header.name, ":")) {
                            try headers.append(header.name, header.value);
                            self.allocator.free(header.name);
                            self.allocator.free(header.value);
                        }
                    }

                    response_headers = headers;
                },

                .data => {
                    // Read data
                    const data = try self.allocator.alloc(u8, @intCast(frame_length));
                    defer self.allocator.free(data);
                    _ = try stream.read(data);

                    try response_body.appendSlice(self.allocator, data);
                },

                else => {
                    // Unknown frame - skip
                    try stream.reader().skipBytes(@intCast(frame_length), .{});
                },
            }

            // Check if stream is finished
            if (stream.isFinished()) break;
        }

        const headers = response_headers orelse Header.HeaderMap.init(self.allocator);

        return Response{
            .status = response_status,
            .headers = headers,
            .body = @import("body.zig").Body{ .owned_bytes = try response_body.toOwnedSlice(self.allocator) },
            .version = .http_3_0,
            .allocator = self.allocator,
        };
    }

    pub fn close(self: *Http3Client) void {
        if (comptime !build_options.engine_h3 or std.mem.eql(u8, build_options.quic_backend, "none")) {
            return;
        }

        self.connected = false;
        if (self.quic_connection) |conn| {
            conn.close();
            self.quic_connection = null;
        }
    }
};

// Stub implementations when HTTP/3 is not enabled
pub fn notEnabled() error{Http3NotEnabled}!void {
    return error.Http3NotEnabled;
}
