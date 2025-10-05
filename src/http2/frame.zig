const std = @import("std");

/// HTTP/2 Frame Types (RFC 7540 Section 6)
pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,
};

/// HTTP/2 Frame Flags
pub const FrameFlags = struct {
    pub const END_STREAM: u8 = 0x1;
    pub const END_HEADERS: u8 = 0x4;
    pub const PADDED: u8 = 0x8;
    pub const PRIORITY: u8 = 0x20;
    pub const ACK: u8 = 0x1; // For SETTINGS and PING
};

/// HTTP/2 Error Codes (RFC 7540 Section 7)
pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    connect_error = 0xa,
    enhance_your_calm = 0xb,
    inadequate_security = 0xc,
    http_1_1_required = 0xd,
};

/// HTTP/2 Settings Parameters
pub const SettingsParameter = enum(u16) {
    header_table_size = 0x1,
    enable_push = 0x2,
    max_concurrent_streams = 0x3,
    initial_window_size = 0x4,
    max_frame_size = 0x5,
    max_header_list_size = 0x6,
};

/// HTTP/2 Frame Header (9 bytes)
pub const FrameHeader = struct {
    length: u24, // 24-bit length
    type: FrameType,
    flags: u8,
    stream_id: u31, // 31-bit stream identifier (R bit is reserved)

    pub const SIZE = 9;

    pub fn init(frame_type: FrameType, flags: u8, stream_id: u31, length: u24) FrameHeader {
        return .{
            .length = length,
            .type = frame_type,
            .flags = flags,
            .stream_id = stream_id,
        };
    }

    pub fn encode(self: FrameHeader, writer: anytype) !void {
        // Write 24-bit length (3 bytes, big-endian)
        try writer.writeByte(@intCast((self.length >> 16) & 0xFF));
        try writer.writeByte(@intCast((self.length >> 8) & 0xFF));
        try writer.writeByte(@intCast(self.length & 0xFF));

        // Write type
        try writer.writeByte(@intFromEnum(self.type));

        // Write flags
        try writer.writeByte(self.flags);

        // Write stream ID (31-bit, R bit is 0)
        try writer.writeInt(u32, self.stream_id, .big);
    }

    pub fn decode(reader: anytype) !FrameHeader {
        // Read 24-bit length
        const len_high = try reader.readByte();
        const len_mid = try reader.readByte();
        const len_low = try reader.readByte();
        const length: u24 = (@as(u24, len_high) << 16) | (@as(u24, len_mid) << 8) | @as(u24, len_low);

        // Read type
        const type_byte = try reader.readByte();
        const frame_type = @as(FrameType, @enumFromInt(type_byte));

        // Read flags
        const flags = try reader.readByte();

        // Read stream ID (31-bit)
        const stream_id_raw = try reader.readInt(u32, .big);
        const stream_id: u31 = @intCast(stream_id_raw & 0x7FFFFFFF); // Mask R bit

        return .{
            .length = length,
            .type = frame_type,
            .flags = flags,
            .stream_id = stream_id,
        };
    }
};

/// HTTP/2 DATA Frame
pub const DataFrame = struct {
    header: FrameHeader,
    pad_length: ?u8,
    data: []const u8,

    pub fn init(stream_id: u31, data: []const u8, end_stream: bool) DataFrame {
        const flags: u8 = if (end_stream) FrameFlags.END_STREAM else 0;
        return .{
            .header = FrameHeader.init(.data, flags, stream_id, @intCast(data.len)),
            .pad_length = null,
            .data = data,
        };
    }

    pub fn encode(self: DataFrame, writer: anytype) !void {
        try self.header.encode(writer);
        if (self.pad_length) |pad_len| {
            try writer.writeByte(pad_len);
        }
        try writer.writeAll(self.data);
        if (self.pad_length) |pad_len| {
            try writer.writeByteNTimes(0, pad_len);
        }
    }
};

/// HTTP/2 HEADERS Frame
pub const HeadersFrame = struct {
    header: FrameHeader,
    pad_length: ?u8,
    priority: ?Priority,
    header_block: []const u8,

    pub const Priority = struct {
        exclusive: bool,
        stream_dependency: u31,
        weight: u8,
    };

    pub fn init(stream_id: u31, header_block: []const u8, end_headers: bool, end_stream: bool) HeadersFrame {
        var flags: u8 = 0;
        if (end_headers) flags |= FrameFlags.END_HEADERS;
        if (end_stream) flags |= FrameFlags.END_STREAM;

        return .{
            .header = FrameHeader.init(.headers, flags, stream_id, @intCast(header_block.len)),
            .pad_length = null,
            .priority = null,
            .header_block = header_block,
        };
    }

    pub fn encode(self: HeadersFrame, writer: anytype) !void {
        try self.header.encode(writer);
        if (self.pad_length) |pad_len| {
            try writer.writeByte(pad_len);
        }
        if (self.priority) |pri| {
            const dep_id: u32 = if (pri.exclusive)
                @as(u32, 0x80000000) | @as(u32, pri.stream_dependency)
            else
                @as(u32, pri.stream_dependency);
            try writer.writeInt(u32, dep_id, .big);
            try writer.writeByte(pri.weight);
        }
        try writer.writeAll(self.header_block);
        if (self.pad_length) |pad_len| {
            try writer.writeByteNTimes(0, pad_len);
        }
    }
};

/// HTTP/2 SETTINGS Frame
pub const SettingsFrame = struct {
    header: FrameHeader,
    settings: []const Setting,

    pub const Setting = struct {
        parameter: SettingsParameter,
        value: u32,
    };

    pub fn init(settings: []const Setting, ack: bool) SettingsFrame {
        const flags: u8 = if (ack) FrameFlags.ACK else 0;
        const length: u24 = if (ack) 0 else @intCast(settings.len * 6);

        return .{
            .header = FrameHeader.init(.settings, flags, 0, length),
            .settings = settings,
        };
    }

    pub fn encode(self: SettingsFrame, writer: anytype) !void {
        try self.header.encode(writer);
        for (self.settings) |setting| {
            try writer.writeInt(u16, @intFromEnum(setting.parameter), .big);
            try writer.writeInt(u32, setting.value, .big);
        }
    }

    pub fn decode(allocator: std.mem.Allocator, header: FrameHeader, reader: anytype) !SettingsFrame {
        const num_settings = header.length / 6;
        var settings = try allocator.alloc(Setting, num_settings);

        for (0..num_settings) |i| {
            const param = try reader.readInt(u16, .big);
            const value = try reader.readInt(u32, .big);
            settings[i] = .{
                .parameter = @enumFromInt(param),
                .value = value,
            };
        }

        return .{
            .header = header,
            .settings = settings,
        };
    }
};

/// HTTP/2 WINDOW_UPDATE Frame
pub const WindowUpdateFrame = struct {
    header: FrameHeader,
    window_size_increment: u31,

    pub fn init(stream_id: u31, increment: u31) WindowUpdateFrame {
        return .{
            .header = FrameHeader.init(.window_update, 0, stream_id, 4),
            .window_size_increment = increment,
        };
    }

    pub fn encode(self: WindowUpdateFrame, writer: anytype) !void {
        try self.header.encode(writer);
        try writer.writeInt(u32, self.window_size_increment, .big);
    }

    pub fn decode(header: FrameHeader, reader: anytype) !WindowUpdateFrame {
        const increment_raw = try reader.readInt(u32, .big);
        const increment: u31 = @intCast(increment_raw & 0x7FFFFFFF);

        return .{
            .header = header,
            .window_size_increment = increment,
        };
    }
};

/// HTTP/2 PING Frame
pub const PingFrame = struct {
    header: FrameHeader,
    opaque_data: [8]u8,

    pub fn init(data: [8]u8, ack: bool) PingFrame {
        const flags: u8 = if (ack) FrameFlags.ACK else 0;
        return .{
            .header = FrameHeader.init(.ping, flags, 0, 8),
            .opaque_data = data,
        };
    }

    pub fn encode(self: PingFrame, writer: anytype) !void {
        try self.header.encode(writer);
        try writer.writeAll(&self.opaque_data);
    }

    pub fn decode(header: FrameHeader, reader: anytype) !PingFrame {
        var data: [8]u8 = undefined;
        _ = try reader.readAll(&data);

        return .{
            .header = header,
            .opaque_data = data,
        };
    }
};

/// HTTP/2 GOAWAY Frame
pub const GoAwayFrame = struct {
    header: FrameHeader,
    last_stream_id: u31,
    error_code: ErrorCode,
    debug_data: []const u8,

    pub fn init(last_stream_id: u31, error_code: ErrorCode, debug_data: []const u8) GoAwayFrame {
        const length: u24 = @intCast(8 + debug_data.len);
        return .{
            .header = FrameHeader.init(.goaway, 0, 0, length),
            .last_stream_id = last_stream_id,
            .error_code = error_code,
            .debug_data = debug_data,
        };
    }

    pub fn encode(self: GoAwayFrame, writer: anytype) !void {
        try self.header.encode(writer);
        try writer.writeInt(u32, self.last_stream_id, .big);
        try writer.writeInt(u32, @intFromEnum(self.error_code), .big);
        try writer.writeAll(self.debug_data);
    }
};

/// HTTP/2 RST_STREAM Frame
pub const RstStreamFrame = struct {
    header: FrameHeader,
    error_code: ErrorCode,

    pub fn init(stream_id: u31, error_code: ErrorCode) RstStreamFrame {
        return .{
            .header = FrameHeader.init(.rst_stream, 0, stream_id, 4),
            .error_code = error_code,
        };
    }

    pub fn encode(self: RstStreamFrame, writer: anytype) !void {
        try self.header.encode(writer);
        try writer.writeInt(u32, @intFromEnum(self.error_code), .big);
    }

    pub fn decode(header: FrameHeader, reader: anytype) !RstStreamFrame {
        const error_code_raw = try reader.readInt(u32, .big);
        return .{
            .header = header,
            .error_code = @enumFromInt(error_code_raw),
        };
    }
};

test "frame header encode/decode" {
    const allocator = std.testing.allocator;

    const header = FrameHeader.init(.data, FrameFlags.END_STREAM, 1, 100);

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try header.encode(buffer.writer());

    var fbs = std.io.fixedBufferStream(buffer.items);
    const decoded = try FrameHeader.decode(fbs.reader());

    try std.testing.expectEqual(header.length, decoded.length);
    try std.testing.expectEqual(header.type, decoded.type);
    try std.testing.expectEqual(header.flags, decoded.flags);
    try std.testing.expectEqual(header.stream_id, decoded.stream_id);
}

test "settings frame" {
    const allocator = std.testing.allocator;

    const settings = [_]SettingsFrame.Setting{
        .{ .parameter = .header_table_size, .value = 4096 },
        .{ .parameter = .enable_push, .value = 1 },
    };

    const frame = SettingsFrame.init(&settings, false);

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try frame.encode(buffer.writer());

    try std.testing.expect(buffer.items.len == FrameHeader.SIZE + 12);
}
