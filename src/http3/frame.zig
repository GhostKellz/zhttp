const std = @import("std");

/// HTTP/3 Frame Types (RFC 9114 Section 7.2)
pub const FrameType = enum(u64) {
    data = 0x00,
    headers = 0x01,
    cancel_push = 0x03,
    settings = 0x04,
    push_promise = 0x05,
    goaway = 0x07,
    max_push_id = 0x0d,
    _,

    pub fn fromInt(value: u64) FrameType {
        return @enumFromInt(value);
    }

    pub fn toInt(self: FrameType) u64 {
        return @intFromEnum(self);
    }
};

/// HTTP/3 Settings Parameters (RFC 9114 Section 7.2.4.1)
pub const SettingsParameter = enum(u64) {
    max_field_section_size = 0x06,
    qpack_max_table_capacity = 0x01,
    qpack_blocked_streams = 0x07,
    _,

    pub fn fromInt(value: u64) SettingsParameter {
        return @enumFromInt(value);
    }

    pub fn toInt(self: SettingsParameter) u64 {
        return @intFromEnum(self);
    }
};

/// Variable-length integer encoding/decoding (QUIC-style)
pub const VarInt = struct {
    /// Encode a variable-length integer
    pub fn encode(writer: anytype, value: u64) !void {
        if (value < 64) {
            // 1 byte: 00xxxxxx
            try writer.writeByte(@intCast(value));
        } else if (value < 16384) {
            // 2 bytes: 01xxxxxx xxxxxxxx
            try writer.writeByte(@intCast(0x40 | (value >> 8)));
            try writer.writeByte(@intCast(value & 0xFF));
        } else if (value < 1073741824) {
            // 4 bytes: 10xxxxxx ...
            try writer.writeByte(@intCast(0x80 | (value >> 24)));
            try writer.writeByte(@intCast((value >> 16) & 0xFF));
            try writer.writeByte(@intCast((value >> 8) & 0xFF));
            try writer.writeByte(@intCast(value & 0xFF));
        } else {
            // 8 bytes: 11xxxxxx ...
            try writer.writeByte(@intCast(0xC0 | (value >> 56)));
            try writer.writeByte(@intCast((value >> 48) & 0xFF));
            try writer.writeByte(@intCast((value >> 40) & 0xFF));
            try writer.writeByte(@intCast((value >> 32) & 0xFF));
            try writer.writeByte(@intCast((value >> 24) & 0xFF));
            try writer.writeByte(@intCast((value >> 16) & 0xFF));
            try writer.writeByte(@intCast((value >> 8) & 0xFF));
            try writer.writeByte(@intCast(value & 0xFF));
        }
    }

    /// Decode a variable-length integer
    pub fn decode(reader: anytype) !u64 {
        const first = try reader.readByte();
        const prefix = first >> 6;

        return switch (prefix) {
            0 => first & 0x3F, // 1 byte
            1 => {
                const second = try reader.readByte();
                return (@as(u64, first & 0x3F) << 8) | second;
            },
            2 => {
                const b2 = try reader.readByte();
                const b3 = try reader.readByte();
                const b4 = try reader.readByte();
                return (@as(u64, first & 0x3F) << 24) |
                    (@as(u64, b2) << 16) |
                    (@as(u64, b3) << 8) |
                    b4;
            },
            3 => {
                const b2 = try reader.readByte();
                const b3 = try reader.readByte();
                const b4 = try reader.readByte();
                const b5 = try reader.readByte();
                const b6 = try reader.readByte();
                const b7 = try reader.readByte();
                const b8 = try reader.readByte();
                return (@as(u64, first & 0x3F) << 56) |
                    (@as(u64, b2) << 48) |
                    (@as(u64, b3) << 40) |
                    (@as(u64, b4) << 32) |
                    (@as(u64, b5) << 24) |
                    (@as(u64, b6) << 16) |
                    (@as(u64, b7) << 8) |
                    b8;
            },
            else => unreachable,
        };
    }
};

/// HTTP/3 Frame Header
pub const FrameHeader = struct {
    frame_type: FrameType,
    length: u64,

    pub fn encode(self: FrameHeader, writer: anytype) !void {
        try VarInt.encode(writer, self.frame_type.toInt());
        try VarInt.encode(writer, self.length);
    }

    pub fn decode(reader: anytype) !FrameHeader {
        const frame_type_int = try VarInt.decode(reader);
        const length = try VarInt.decode(reader);

        return .{
            .frame_type = FrameType.fromInt(frame_type_int),
            .length = length,
        };
    }
};

/// HTTP/3 DATA Frame
pub const DataFrame = struct {
    header: FrameHeader,
    data: []const u8,

    pub fn init(data: []const u8) DataFrame {
        return .{
            .header = .{
                .frame_type = .data,
                .length = data.len,
            },
            .data = data,
        };
    }

    pub fn encode(self: DataFrame, writer: anytype) !void {
        try self.header.encode(writer);
        try writer.writeAll(self.data);
    }
};

/// HTTP/3 HEADERS Frame
pub const HeadersFrame = struct {
    header: FrameHeader,
    encoded_field_section: []const u8,

    pub fn init(encoded_field_section: []const u8) HeadersFrame {
        return .{
            .header = .{
                .frame_type = .headers,
                .length = encoded_field_section.len,
            },
            .encoded_field_section = encoded_field_section,
        };
    }

    pub fn encode(self: HeadersFrame, writer: anytype) !void {
        try self.header.encode(writer);
        try writer.writeAll(self.encoded_field_section);
    }
};

/// HTTP/3 SETTINGS Frame
pub const SettingsFrame = struct {
    header: FrameHeader,
    settings: []const Setting,

    pub const Setting = struct {
        parameter: SettingsParameter,
        value: u64,
    };

    pub fn init(settings: []const Setting) SettingsFrame {
        // Calculate length
        var length: u64 = 0;
        for (settings) |_| {
            // Each setting is parameter ID + value (both varint)
            // Approximate: 2 bytes per setting (can be more)
            length += 2 + 2; // Simplified
        }

        return .{
            .header = .{
                .frame_type = .settings,
                .length = length,
            },
            .settings = settings,
        };
    }

    pub fn encode(self: SettingsFrame, writer: anytype) !void {
        // Write frame type and length
        try VarInt.encode(writer, self.header.frame_type.toInt());

        // Calculate actual length
        var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
        defer aw.deinit();

        for (self.settings) |setting| {
            try VarInt.encode(&aw.writer, setting.parameter.toInt());
            try VarInt.encode(&aw.writer, setting.value);
        }

        const length_buffer = aw.writer.buffered();
        try VarInt.encode(writer, length_buffer.len);
        try writer.writeAll(length_buffer);
    }

    pub fn decode(allocator: std.mem.Allocator, header: FrameHeader, reader: anytype) !SettingsFrame {
        var settings: std.ArrayList(Setting) = .{};

        var bytes_read: u64 = 0;
        while (bytes_read < header.length) {
            const param_id = try VarInt.decode(reader);
            const value = try VarInt.decode(reader);

            try settings.append(allocator, .{
                .parameter = SettingsParameter.fromInt(param_id),
                .value = value,
            });

            bytes_read += 2; // Approximate
        }

        return .{
            .header = header,
            .settings = try settings.toOwnedSlice(allocator),
        };
    }
};

/// HTTP/3 GOAWAY Frame
pub const GoAwayFrame = struct {
    header: FrameHeader,
    stream_id: u64,

    pub fn init(stream_id: u64) GoAwayFrame {
        return .{
            .header = .{
                .frame_type = .goaway,
                .length = 8, // Approximate
            },
            .stream_id = stream_id,
        };
    }

    pub fn encode(self: GoAwayFrame, writer: anytype) !void {
        try self.header.encode(writer);
        try VarInt.encode(writer, self.stream_id);
    }

    pub fn decode(header: FrameHeader, reader: anytype) !GoAwayFrame {
        const stream_id = try VarInt.decode(reader);
        return .{
            .header = header,
            .stream_id = stream_id,
        };
    }
};

/// HTTP/3 MAX_PUSH_ID Frame
pub const MaxPushIdFrame = struct {
    header: FrameHeader,
    push_id: u64,

    pub fn init(push_id: u64) MaxPushIdFrame {
        return .{
            .header = .{
                .frame_type = .max_push_id,
                .length = 8, // Approximate
            },
            .push_id = push_id,
        };
    }

    pub fn encode(self: MaxPushIdFrame, writer: anytype) !void {
        try self.header.encode(writer);
        try VarInt.encode(writer, self.push_id);
    }

    pub fn decode(header: FrameHeader, reader: anytype) !MaxPushIdFrame {
        const push_id = try VarInt.decode(reader);
        return .{
            .header = header,
            .push_id = push_id,
        };
    }
};

test "varint encoding/decoding" {
    const allocator = std.testing.allocator;

    // Test 1-byte
    {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try VarInt.encode(&aw.writer, 42);

        const buffer = aw.writer.buffered();
        var reader = std.Io.Reader.fixed(buffer);
        const decoded = try VarInt.decode(&reader);
        try std.testing.expectEqual(@as(u64, 42), decoded);
    }

    // Test 2-byte
    {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try VarInt.encode(&aw.writer, 1000);

        const buffer = aw.writer.buffered();
        var reader = std.Io.Reader.fixed(buffer);
        const decoded = try VarInt.decode(&reader);
        try std.testing.expectEqual(@as(u64, 1000), decoded);
    }
}

test "http3 frame header" {
    const allocator = std.testing.allocator;

    const header = FrameHeader{
        .frame_type = .data,
        .length = 100,
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try header.encode(&aw.writer);

    const buffer = aw.writer.buffered();
    var reader = std.Io.Reader.fixed(buffer);
    const decoded = try FrameHeader.decode(&reader);

    try std.testing.expectEqual(header.frame_type, decoded.frame_type);
    try std.testing.expectEqual(header.length, decoded.length);
}
