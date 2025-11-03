const std = @import("std");

/// Server-Sent Events (SSE) support
/// Implements the Server-Sent Events specification
/// https://html.spec.whatwg.org/multipage/server-sent-events.html

/// SSE Event
pub const Event = struct {
    event_type: ?[]const u8,
    data: []const u8,
    id: ?[]const u8,
    retry: ?u64,

    pub fn init(data: []const u8) Event {
        return .{
            .event_type = null,
            .data = data,
            .id = null,
            .retry = null,
        };
    }

    /// Format event as SSE message
    pub fn format(self: Event, writer: anytype) !void {
        if (self.event_type) |event_type| {
            try writer.print("event: {s}\n", .{event_type});
        }

        if (self.id) |id| {
            try writer.print("id: {s}\n", .{id});
        }

        if (self.retry) |retry| {
            try writer.print("retry: {d}\n", .{retry});
        }

        // Data can be multi-line
        var lines = std.mem.split(u8, self.data, "\n");
        while (lines.next()) |line| {
            try writer.print("data: {s}\n", .{line});
        }

        // End with blank line
        try writer.writeAll("\n");
    }
};

/// SSE Event Builder
pub const EventBuilder = struct {
    event_type: ?[]const u8 = null,
    data: ?[]const u8 = null,
    id: ?[]const u8 = null,
    retry: ?u64 = null,

    pub fn init() EventBuilder {
        return .{};
    }

    pub fn setType(self: *EventBuilder, event_type: []const u8) *EventBuilder {
        self.event_type = event_type;
        return self;
    }

    pub fn setData(self: *EventBuilder, data: []const u8) *EventBuilder {
        self.data = data;
        return self;
    }

    pub fn setId(self: *EventBuilder, id: []const u8) *EventBuilder {
        self.id = id;
        return self;
    }

    pub fn setRetry(self: *EventBuilder, retry_ms: u64) *EventBuilder {
        self.retry = retry_ms;
        return self;
    }

    pub fn build(self: EventBuilder) Event {
        return .{
            .event_type = self.event_type,
            .data = self.data orelse "",
            .id = self.id,
            .retry = self.retry,
        };
    }
};

/// SSE Parser for reading events from a stream
pub const Parser = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    current_event: EventBuilder,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{
            .allocator = allocator,
            .buffer = .{},
            .current_event = EventBuilder.init(),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.buffer.deinit(self.allocator);
    }

    /// Parse a line of SSE data
    pub fn parseLine(self: *Parser, line: []const u8) !?Event {
        // Ignore comments
        if (line.len > 0 and line[0] == ':') {
            return null;
        }

        // Empty line = dispatch event
        if (line.len == 0) {
            const event = self.current_event.build();
            self.current_event = EventBuilder.init();
            return event;
        }

        // Parse field
        const colon_pos = std.mem.indexOfScalar(u8, line, ':');
        if (colon_pos == null) {
            // Field with no value
            const field = line;
            if (std.mem.eql(u8, field, "data")) {
                _ = self.current_event.setData("");
            }
            return null;
        }

        const field = line[0..colon_pos.?];
        var value = line[colon_pos.? + 1 ..];

        // Strip leading space from value
        if (value.len > 0 and value[0] == ' ') {
            value = value[1..];
        }

        if (std.mem.eql(u8, field, "event")) {
            _ = self.current_event.setType(value);
        } else if (std.mem.eql(u8, field, "data")) {
            // Accumulate data lines
            if (self.current_event.data) |existing| {
                const new_data = try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ existing, value });
                _ = self.current_event.setData(new_data);
            } else {
                _ = self.current_event.setData(value);
            }
        } else if (std.mem.eql(u8, field, "id")) {
            _ = self.current_event.setId(value);
        } else if (std.mem.eql(u8, field, "retry")) {
            const retry = std.fmt.parseInt(u64, value, 10) catch return null;
            _ = self.current_event.setRetry(retry);
        }

        return null;
    }

    /// Parse chunk of data and return any complete events
    pub fn parseChunk(self: *Parser, chunk: []const u8) !std.ArrayList(Event) {
        var events: std.ArrayList(Event) = .{};

        try self.buffer.appendSlice(self.allocator, chunk);

        // Process complete lines
        while (std.mem.indexOf(u8, self.buffer.items, "\n")) |newline_pos| {
            const line = self.buffer.items[0..newline_pos];

            // Remove \r if present (CRLF)
            const clean_line = if (line.len > 0 and line[line.len - 1] == '\r')
                line[0 .. line.len - 1]
            else
                line;

            if (try self.parseLine(clean_line)) |event| {
                try events.append(self.allocator, event);
            }

            // Remove processed line from buffer
            try self.buffer.replaceRange(self.allocator, 0, newline_pos + 1, &[_]u8{});
        }

        return events;
    }
};

/// SSE Client for consuming Server-Sent Events
pub const Client = struct {
    allocator: std.mem.Allocator,
    parser: Parser,
    last_event_id: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) Client {
        return .{
            .allocator = allocator,
            .parser = Parser.init(allocator),
            .last_event_id = null,
        };
    }

    pub fn deinit(self: *Client) void {
        self.parser.deinit();
        if (self.last_event_id) |id| {
            self.allocator.free(id);
        }
    }

    /// Process incoming data chunk
    pub fn processChunk(self: *Client, chunk: []const u8) !std.ArrayList(Event) {
        const events = try self.parser.parseChunk(chunk);

        // Update last event ID
        for (events.items) |event| {
            if (event.id) |id| {
                if (self.last_event_id) |old_id| {
                    self.allocator.free(old_id);
                }
                self.last_event_id = try self.allocator.dupe(u8, id);
            }
        }

        return events;
    }

    /// Get the Last-Event-ID header value for reconnection
    pub fn getLastEventId(self: *const Client) ?[]const u8 {
        return self.last_event_id;
    }
};

test "sse event formatting" {
    const allocator = std.testing.allocator;

    var event = Event.init("Hello, World!");
    event.event_type = "message";
    event.id = "42";

    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);

    try event.format(buffer.writer(allocator));

    const expected = "event: message\nid: 42\ndata: Hello, World!\n\n";
    try std.testing.expectEqualStrings(expected, buffer.items);
}

test "sse event builder" {
    var builder = EventBuilder.init();
    const event = builder
        .setType("update")
        .setData("New data")
        .setId("123")
        .setRetry(5000)
        .build();

    try std.testing.expectEqualStrings("update", event.event_type.?);
    try std.testing.expectEqualStrings("New data", event.data);
    try std.testing.expectEqualStrings("123", event.id.?);
    try std.testing.expectEqual(@as(u64, 5000), event.retry.?);
}

test "sse parser" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator);
    defer parser.deinit();

    // Parse a complete event
    _ = try parser.parseLine("event: message");
    _ = try parser.parseLine("data: Hello");
    const event = try parser.parseLine("");

    try std.testing.expect(event != null);
    try std.testing.expectEqualStrings("message", event.?.event_type.?);
    try std.testing.expectEqualStrings("Hello", event.?.data);
}

test "sse client" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator);
    defer client.deinit();

    const chunk = "event: update\nid: 1\ndata: First event\n\n";
    var events = try client.processChunk(chunk);
    defer events.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("update", events.items[0].event_type.?);
    try std.testing.expectEqualStrings("First event", events.items[0].data);
    try std.testing.expectEqualStrings("1", client.getLastEventId().?);
}
