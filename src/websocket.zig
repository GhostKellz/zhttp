const std = @import("std");

/// WebSocket Protocol Implementation (RFC 6455)
/// HTTP/1.1 Upgrade to WebSocket

/// WebSocket opcode
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(self: Opcode) bool {
        return @intFromEnum(self) >= 0x8;
    }
};

/// WebSocket close codes (RFC 6455 Section 7.4.1)
pub const CloseCode = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    no_status_received = 1005,
    abnormal_closure = 1006,
    invalid_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    missing_extension = 1010,
    internal_error = 1011,
    service_restart = 1012,
    try_again_later = 1013,
    _,
};

/// WebSocket frame header
pub const FrameHeader = struct {
    fin: bool,
    rsv1: bool = false,
    rsv2: bool = false,
    rsv3: bool = false,
    opcode: Opcode,
    masked: bool,
    payload_length: u64,
    masking_key: ?[4]u8,

    pub fn decode(reader: anytype) !FrameHeader {
        const byte1 = try reader.readByte();
        const byte2 = try reader.readByte();

        const fin = (byte1 & 0x80) != 0;
        const rsv1 = (byte1 & 0x40) != 0;
        const rsv2 = (byte1 & 0x20) != 0;
        const rsv3 = (byte1 & 0x10) != 0;
        const opcode: Opcode = @enumFromInt(byte1 & 0x0F);

        const masked = (byte2 & 0x80) != 0;
        var payload_length: u64 = byte2 & 0x7F;

        // Extended payload length
        if (payload_length == 126) {
            payload_length = try reader.readInt(u16, .big);
        } else if (payload_length == 127) {
            payload_length = try reader.readInt(u64, .big);
        }

        // Masking key
        var masking_key: ?[4]u8 = null;
        if (masked) {
            var key: [4]u8 = undefined;
            _ = try reader.readAll(&key);
            masking_key = key;
        }

        return .{
            .fin = fin,
            .rsv1 = rsv1,
            .rsv2 = rsv2,
            .rsv3 = rsv3,
            .opcode = opcode,
            .masked = masked,
            .payload_length = payload_length,
            .masking_key = masking_key,
        };
    }

    pub fn encode(self: FrameHeader, writer: anytype) !void {
        // First byte: FIN, RSV, Opcode
        var byte1: u8 = @intFromEnum(self.opcode);
        if (self.fin) byte1 |= 0x80;
        if (self.rsv1) byte1 |= 0x40;
        if (self.rsv2) byte1 |= 0x20;
        if (self.rsv3) byte1 |= 0x10;
        try writer.writeByte(byte1);

        // Second byte: MASK, Payload length
        var byte2: u8 = 0;
        if (self.masked) byte2 |= 0x80;

        if (self.payload_length < 126) {
            byte2 |= @intCast(self.payload_length);
            try writer.writeByte(byte2);
        } else if (self.payload_length < 65536) {
            byte2 |= 126;
            try writer.writeByte(byte2);
            try writer.writeInt(u16, @intCast(self.payload_length), .big);
        } else {
            byte2 |= 127;
            try writer.writeByte(byte2);
            try writer.writeInt(u64, self.payload_length, .big);
        }

        // Masking key
        if (self.masking_key) |key| {
            try writer.writeAll(&key);
        }
    }
};

/// WebSocket frame
pub const Frame = struct {
    header: FrameHeader,
    payload: []u8,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }

    /// Read a frame from the stream
    pub fn read(allocator: std.mem.Allocator, reader: anytype) !Frame {
        const header = try FrameHeader.decode(reader);

        // Read payload
        const payload = try allocator.alloc(u8, @intCast(header.payload_length));
        errdefer allocator.free(payload);
        _ = try reader.readAll(payload);

        // Unmask if needed
        if (header.masking_key) |key| {
            for (payload, 0..) |*byte, i| {
                byte.* ^= key[i % 4];
            }
        }

        return .{
            .header = header,
            .payload = payload,
        };
    }

    /// Write a frame to the stream
    pub fn write(self: Frame, writer: anytype) !void {
        try self.header.encode(writer);

        // Mask payload if needed
        if (self.header.masking_key) |key| {
            var masked = try std.heap.page_allocator.alloc(u8, self.payload.len);
            defer std.heap.page_allocator.free(masked);

            for (self.payload, 0..) |byte, i| {
                masked[i] = byte ^ key[i % 4];
            }

            try writer.writeAll(masked);
        } else {
            try writer.writeAll(self.payload);
        }
    }

    /// Create a text frame
    pub fn text(allocator: std.mem.Allocator, message: []const u8, masked: bool) !Frame {
        const payload = try allocator.dupe(u8, message);
        var masking_key: ?[4]u8 = null;

        if (masked) {
            var prng = std.Random.DefaultPrng.init(@intCast((try std.time.Instant.now()).timestamp.sec));
            const random = prng.random();
            var key: [4]u8 = undefined;
            random.bytes(&key);
            masking_key = key;
        }

        return .{
            .header = .{
                .fin = true,
                .opcode = .text,
                .masked = masked,
                .payload_length = payload.len,
                .masking_key = masking_key,
            },
            .payload = payload,
        };
    }

    /// Create a binary frame
    pub fn binary(allocator: std.mem.Allocator, data: []const u8, masked: bool) !Frame {
        const payload = try allocator.dupe(u8, data);
        var masking_key: ?[4]u8 = null;

        if (masked) {
            var prng = std.Random.DefaultPrng.init(@intCast((try std.time.Instant.now()).timestamp.sec));
            const random = prng.random();
            var key: [4]u8 = undefined;
            random.bytes(&key);
            masking_key = key;
        }

        return .{
            .header = .{
                .fin = true,
                .opcode = .binary,
                .masked = masked,
                .payload_length = payload.len,
                .masking_key = masking_key,
            },
            .payload = payload,
        };
    }

    /// Create a close frame
    pub fn close(_: std.mem.Allocator, code: CloseCode, reason: ?[]const u8, masked: bool) !Frame {
        var payload = .{ };
        errdefer payload.deinit();

        // Write close code (2 bytes, big-endian)
        const code_val: u16 = @intFromEnum(code);
        try payload.append(@intCast((code_val >> 8) & 0xFF));
        try payload.append(@intCast(code_val & 0xFF));

        // Write reason (if present)
        if (reason) |r| {
            try payload.appendSlice(r);
        }

        var masking_key: ?[4]u8 = null;
        if (masked) {
            var prng = std.Random.DefaultPrng.init(@intCast((try std.time.Instant.now()).timestamp.sec));
            const random = prng.random();
            var key: [4]u8 = undefined;
            random.bytes(&key);
            masking_key = key;
        }

        return .{
            .header = .{
                .fin = true,
                .opcode = .close,
                .masked = masked,
                .payload_length = payload.items.len,
                .masking_key = masking_key,
            },
            .payload = try payload.toOwnedSlice(),
        };
    }

    /// Create a ping frame
    pub fn ping(allocator: std.mem.Allocator, data: ?[]const u8, masked: bool) !Frame {
        const payload = if (data) |d| try allocator.dupe(u8, d) else try allocator.alloc(u8, 0);

        var masking_key: ?[4]u8 = null;
        if (masked) {
            var prng = std.Random.DefaultPrng.init(@intCast((try std.time.Instant.now()).timestamp.sec));
            const random = prng.random();
            var key: [4]u8 = undefined;
            random.bytes(&key);
            masking_key = key;
        }

        return .{
            .header = .{
                .fin = true,
                .opcode = .ping,
                .masked = masked,
                .payload_length = payload.len,
                .masking_key = masking_key,
            },
            .payload = payload,
        };
    }

    /// Create a pong frame
    pub fn pong(allocator: std.mem.Allocator, data: ?[]const u8, masked: bool) !Frame {
        const payload = if (data) |d| try allocator.dupe(u8, d) else try allocator.alloc(u8, 0);

        var masking_key: ?[4]u8 = null;
        if (masked) {
            var prng = std.Random.DefaultPrng.init(@intCast((try std.time.Instant.now()).timestamp.sec));
            const random = prng.random();
            var key: [4]u8 = undefined;
            random.bytes(&key);
            masking_key = key;
        }

        return .{
            .header = .{
                .fin = true,
                .opcode = .pong,
                .masked = masked,
                .payload_length = payload.len,
                .masking_key = masking_key,
            },
            .payload = payload,
        };
    }
};

/// WebSocket connection upgrade
pub const Upgrade = struct {
    /// Generate WebSocket accept key from client key
    pub fn generateAcceptKey(allocator: std.mem.Allocator, client_key: []const u8) ![]u8 {
        // RFC 6455: Concatenate with magic string and SHA-1
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        const concatenated = try std.fmt.allocPrint(allocator, "{s}{s}", .{ client_key, magic });
        defer allocator.free(concatenated);

        // SHA-1 hash
        var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        std.crypto.hash.Sha1.hash(concatenated, &hash, .{});

        // Base64 encode
        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(hash.len);
        const result = try allocator.alloc(u8, encoded_len);
        _ = encoder.encode(result, &hash);

        return result;
    }

    /// Create upgrade request headers
    pub fn createUpgradeHeaders(_: std.mem.Allocator, host: []const u8, path: []const u8, key: []const u8) !std.ArrayList(struct { name: []const u8, value: []const u8 }) {
        var headers = .{ };

        try headers.append(.{ .name = "Host", .value = host });
        try headers.append(.{ .name = "Upgrade", .value = "websocket" });
        try headers.append(.{ .name = "Connection", .value = "Upgrade" });
        try headers.append(.{ .name = "Sec-WebSocket-Key", .value = key });
        try headers.append(.{ .name = "Sec-WebSocket-Version", .value = "13" });
        _ = path; // Path goes in request line, not headers

        return headers;
    }

    /// Generate random WebSocket key
    pub fn generateKey(allocator: std.mem.Allocator) ![]u8 {
        var prng = std.Random.DefaultPrng.init(@intCast((try std.time.Instant.now()).timestamp.sec));
        const random = prng.random();

        var key_bytes: [16]u8 = undefined;
        random.bytes(&key_bytes);

        const encoder = std.base64.standard.Encoder;
        const encoded_len = encoder.calcSize(key_bytes.len);
        const result = try allocator.alloc(u8, encoded_len);
        _ = encoder.encode(result, &key_bytes);

        return result;
    }
};

test "websocket frame header encoding" {
    _ = std.testing.allocator;

    const header = FrameHeader{
        .fin = true,
        .opcode = .text,
        .masked = false,
        .payload_length = 5,
        .masking_key = null,
    };

    var buffer = .{ };
    defer buffer.deinit();

    try header.encode(buffer.writer());

    try std.testing.expectEqual(@as(usize, 2), buffer.items.len);
    try std.testing.expectEqual(@as(u8, 0x81), buffer.items[0]); // FIN + text opcode
    try std.testing.expectEqual(@as(u8, 0x05), buffer.items[1]); // payload length 5
}

test "websocket text frame" {
    const allocator = std.testing.allocator;

    var frame = try Frame.text(allocator, "Hello", false);
    defer frame.deinit(allocator);

    try std.testing.expect(frame.header.fin);
    try std.testing.expectEqual(Opcode.text, frame.header.opcode);
    try std.testing.expectEqualStrings("Hello", frame.payload);
}

test "websocket accept key generation" {
    const allocator = std.testing.allocator;

    const client_key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept_key = try Upgrade.generateAcceptKey(allocator, client_key);
    defer allocator.free(accept_key);

    // Expected value from RFC 6455 example
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept_key);
}
