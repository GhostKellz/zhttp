const std = @import("std");
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");

/// HTTP/2 Stream States (RFC 7540 Section 5.1)
pub const StreamState = enum {
    idle,
    reserved_local,
    reserved_remote,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
};

/// HTTP/2 Stream
pub const Stream = struct {
    id: u31,
    state: StreamState,
    window_size: i32,
    headers_received: std.ArrayList(Header),
    data_buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    // Flow control
    local_window_size: i32,
    remote_window_size: i32,

    // Priority
    weight: u8,
    dependency: ?u31,
    exclusive: bool,

    pub const Header = struct {
        name: []u8,
        value: []u8,

        pub fn deinit(self: *Header, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.value);
        }
    };

    pub fn init(allocator: std.mem.Allocator, stream_id: u31, initial_window_size: i32) Stream {
        return .{
            .id = stream_id,
            .state = .idle,
            .window_size = initial_window_size,
            .headers_received = std.ArrayList(Header).init(allocator),
            .data_buffer = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
            .local_window_size = initial_window_size,
            .remote_window_size = initial_window_size,
            .weight = 16, // Default weight
            .dependency = null,
            .exclusive = false,
        };
    }

    pub fn deinit(self: *Stream) void {
        for (self.headers_received.items) |*header| {
            header.deinit(self.allocator);
        }
        self.headers_received.deinit();
        self.data_buffer.deinit();
    }

    /// Process a DATA frame
    pub fn processData(self: *Stream, data: []const u8, end_stream: bool) !void {
        if (self.state != .open and self.state != .half_closed_local) {
            return error.StreamClosed;
        }

        // Check flow control
        if (data.len > self.local_window_size) {
            return error.FlowControlError;
        }

        try self.data_buffer.appendSlice(data);
        self.local_window_size -= @intCast(data.len);

        if (end_stream) {
            self.transitionState(.half_closed_remote);
        }
    }

    /// Process HEADERS frame
    pub fn processHeaders(self: *Stream, headers: []Header, end_stream: bool, end_headers: bool) !void {
        _ = end_headers;

        if (self.state == .idle) {
            self.transitionState(.open);
        }

        try self.headers_received.appendSlice(headers);

        if (end_stream) {
            if (self.state == .open) {
                self.transitionState(.half_closed_remote);
            } else if (self.state == .half_closed_local) {
                self.transitionState(.closed);
            }
        }
    }

    /// Update flow control window
    pub fn updateWindow(self: *Stream, increment: i32) !void {
        const new_size = self.remote_window_size + increment;
        if (new_size > std.math.maxInt(i31)) {
            return error.FlowControlError;
        }
        self.remote_window_size = new_size;
    }

    /// Consume window (when sending data)
    pub fn consumeWindow(self: *Stream, amount: usize) !void {
        if (amount > self.remote_window_size) {
            return error.FlowControlError;
        }
        self.remote_window_size -= @intCast(amount);
    }

    /// Set stream priority
    pub fn setPriority(self: *Stream, weight: u8, dependency: ?u31, exclusive: bool) void {
        self.weight = weight;
        self.dependency = dependency;
        self.exclusive = exclusive;
    }

    /// Transition stream state
    fn transitionState(self: *Stream, new_state: StreamState) void {
        self.state = new_state;
    }

    /// Check if stream can send data
    pub fn canSend(self: *const Stream) bool {
        return (self.state == .open or self.state == .half_closed_remote) and
               self.remote_window_size > 0;
    }

    /// Check if stream can receive data
    pub fn canReceive(self: *const Stream) bool {
        return self.state == .open or self.state == .half_closed_local;
    }
};

/// HTTP/2 Connection with stream management
pub const Connection = struct {
    allocator: std.mem.Allocator,
    streams: std.AutoHashMap(u31, *Stream),
    next_stream_id: u31,
    settings: Settings,
    encoder: hpack.Encoder,
    decoder: hpack.Decoder,

    // Flow control
    local_window_size: i32,
    remote_window_size: i32,

    pub const Settings = struct {
        header_table_size: u32 = 4096,
        enable_push: bool = true,
        max_concurrent_streams: u32 = 100,
        initial_window_size: i32 = 65535,
        max_frame_size: u32 = 16384,
        max_header_list_size: u32 = std.math.maxInt(u32),
    };

    pub fn init(allocator: std.mem.Allocator, is_client: bool) !Connection {
        return .{
            .allocator = allocator,
            .streams = std.AutoHashMap(u31, *Stream).init(allocator),
            .next_stream_id = if (is_client) 1 else 2, // Clients use odd, servers use even
            .settings = Settings{},
            .encoder = hpack.Encoder.init(allocator, 4096),
            .decoder = hpack.Decoder.init(allocator, 4096),
            .local_window_size = 65535,
            .remote_window_size = 65535,
        };
    }

    pub fn deinit(self: *Connection) void {
        var iter = self.streams.valueIterator();
        while (iter.next()) |stream_ptr| {
            stream_ptr.*.deinit();
            self.allocator.destroy(stream_ptr.*);
        }
        self.streams.deinit();
        self.encoder.deinit();
        self.decoder.deinit();
    }

    /// Create a new stream
    pub fn createStream(self: *Connection) !*Stream {
        const stream_id = self.next_stream_id;
        self.next_stream_id += 2; // Skip one ID (client odd, server even)

        const stream = try self.allocator.create(Stream);
        stream.* = Stream.init(self.allocator, stream_id, self.settings.initial_window_size);

        try self.streams.put(stream_id, stream);
        return stream;
    }

    /// Get stream by ID
    pub fn getStream(self: *Connection, stream_id: u31) ?*Stream {
        return self.streams.get(stream_id);
    }

    /// Close stream
    pub fn closeStream(self: *Connection, stream_id: u31) void {
        if (self.streams.fetchRemove(stream_id)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);
        }
    }

    /// Process received frame
    pub fn processFrame(self: *Connection, frame_header: frame.FrameHeader, reader: anytype) !void {
        switch (frame_header.type) {
            .data => {
                const stream_obj = self.getStream(frame_header.stream_id) orelse return error.StreamNotFound;

                // Read data
                const data = try self.allocator.alloc(u8, frame_header.length);
                defer self.allocator.free(data);
                _ = try reader.readAll(data);

                const end_stream = (frame_header.flags & frame.FrameFlags.END_STREAM) != 0;
                try stream_obj.processData(data, end_stream);

                // Update connection window
                self.local_window_size -= @intCast(data.len);
            },

            .headers => {
                var stream_obj = self.getStream(frame_header.stream_id);
                if (stream_obj == null) {
                    // Create new stream for incoming request
                    const new_stream = try self.allocator.create(Stream);
                    new_stream.* = Stream.init(self.allocator, frame_header.stream_id, self.settings.initial_window_size);
                    try self.streams.put(frame_header.stream_id, new_stream);
                    stream_obj = new_stream;
                }

                // Decode HPACK headers
                const header_data = try self.allocator.alloc(u8, frame_header.length);
                defer self.allocator.free(header_data);
                _ = try reader.readAll(header_data);

                var decoded_headers = try self.decoder.decodeHeaderBlock(header_data);
                defer {
                    for (decoded_headers.items) |header| {
                        self.allocator.free(header.name);
                        self.allocator.free(header.value);
                    }
                    decoded_headers.deinit();
                }

                // Convert to Stream.Header
                var headers = try self.allocator.alloc(Stream.Header, decoded_headers.items.len);
                defer self.allocator.free(headers);

                for (decoded_headers.items, 0..) |h, i| {
                    headers[i] = .{
                        .name = try self.allocator.dupe(u8, h.name),
                        .value = try self.allocator.dupe(u8, h.value),
                    };
                }

                const end_stream = (frame_header.flags & frame.FrameFlags.END_STREAM) != 0;
                const end_headers = (frame_header.flags & frame.FrameFlags.END_HEADERS) != 0;
                try stream_obj.?.processHeaders(headers, end_stream, end_headers);
            },

            .settings => {
                const settings_frame = try frame.SettingsFrame.decode(self.allocator, frame_header, reader);
                defer self.allocator.free(settings_frame.settings);

                if ((frame_header.flags & frame.FrameFlags.ACK) == 0) {
                    // Apply settings
                    for (settings_frame.settings) |setting| {
                        try self.applySetting(setting.parameter, setting.value);
                    }
                }
            },

            .window_update => {
                const wu_frame = try frame.WindowUpdateFrame.decode(frame_header, reader);
                if (frame_header.stream_id == 0) {
                    // Connection-level window update
                    try self.updateConnectionWindow(@intCast(wu_frame.window_size_increment));
                } else {
                    // Stream-level window update
                    const stream_obj = self.getStream(frame_header.stream_id) orelse return error.StreamNotFound;
                    try stream_obj.updateWindow(@intCast(wu_frame.window_size_increment));
                }
            },

            .ping => {
                const ping_frame = try frame.PingFrame.decode(frame_header, reader);
                _ = ping_frame;
                // TODO: Respond to ping if not ACK
            },

            .goaway => {
                // Connection is closing
                // TODO: Handle GOAWAY
            },

            .rst_stream => {
                const rst_frame = try frame.RstStreamFrame.decode(frame_header, reader);
                _ = rst_frame;
                // Close the stream
                self.closeStream(frame_header.stream_id);
            },

            else => {
                // Unknown frame type - ignore
                _ = try reader.skipBytes(frame_header.length, .{});
            },
        }
    }

    fn applySetting(self: *Connection, parameter: frame.SettingsParameter, value: u32) !void {
        switch (parameter) {
            .header_table_size => {
                self.settings.header_table_size = value;
                self.encoder.dynamic_table.setMaxSize(value);
                self.decoder.dynamic_table.setMaxSize(value);
            },
            .enable_push => {
                self.settings.enable_push = (value != 0);
            },
            .max_concurrent_streams => {
                self.settings.max_concurrent_streams = value;
            },
            .initial_window_size => {
                if (value > std.math.maxInt(i31)) {
                    return error.FlowControlError;
                }
                self.settings.initial_window_size = @intCast(value);
            },
            .max_frame_size => {
                if (value < 16384 or value > 16777215) {
                    return error.ProtocolError;
                }
                self.settings.max_frame_size = value;
            },
            .max_header_list_size => {
                self.settings.max_header_list_size = value;
            },
        }
    }

    fn updateConnectionWindow(self: *Connection, increment: i32) !void {
        const new_size = self.remote_window_size + increment;
        if (new_size > std.math.maxInt(i31)) {
            return error.FlowControlError;
        }
        self.remote_window_size = new_size;
    }

    /// Send WINDOW_UPDATE frame
    pub fn sendWindowUpdate(self: *Connection, writer: anytype, stream_id: u31, increment: u31) !void {
        _ = self;
        const wu_frame = frame.WindowUpdateFrame.init(stream_id, increment);
        try wu_frame.encode(writer);
    }

    /// Send SETTINGS frame
    pub fn sendSettings(self: *Connection, writer: anytype, ack: bool) !void {
        if (ack) {
            const settings_frame = frame.SettingsFrame.init(&[_]frame.SettingsFrame.Setting{}, true);
            try settings_frame.encode(writer);
        } else {
            const settings = [_]frame.SettingsFrame.Setting{
                .{ .parameter = .header_table_size, .value = self.settings.header_table_size },
                .{ .parameter = .enable_push, .value = if (self.settings.enable_push) 1 else 0 },
                .{ .parameter = .max_concurrent_streams, .value = self.settings.max_concurrent_streams },
                .{ .parameter = .initial_window_size, .value = @intCast(self.settings.initial_window_size) },
                .{ .parameter = .max_frame_size, .value = self.settings.max_frame_size },
            };
            const settings_frame = frame.SettingsFrame.init(&settings, false);
            try settings_frame.encode(writer);
        }
    }
};

test "stream creation and state" {
    const allocator = std.testing.allocator;
    var stream = Stream.init(allocator, 1, 65535);
    defer stream.deinit();

    try std.testing.expect(stream.state == .idle);
    try std.testing.expect(stream.id == 1);
    try std.testing.expect(stream.remote_window_size == 65535);
}

test "connection stream management" {
    const allocator = std.testing.allocator;
    var conn = try Connection.init(allocator, true);
    defer conn.deinit();

    const stream1 = try conn.createStream();
    try std.testing.expect(stream1.id == 1);

    const stream2 = try conn.createStream();
    try std.testing.expect(stream2.id == 3);

    const retrieved = conn.getStream(1);
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.id == 1);
}
