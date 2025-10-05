const std = @import("std");

/// HPACK - Header Compression for HTTP/2
/// Implements RFC 7541: https://tools.ietf.org/html/rfc7541

/// Static table entries from RFC 7541 Appendix A
pub const StaticTable = struct {
    pub const Entry = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const entries = [_]Entry{
        .{ .name = ":authority", .value = "" },
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":path", .value = "/index.html" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":status", .value = "200" },
        .{ .name = ":status", .value = "204" },
        .{ .name = ":status", .value = "206" },
        .{ .name = ":status", .value = "304" },
        .{ .name = ":status", .value = "400" },
        .{ .name = ":status", .value = "404" },
        .{ .name = ":status", .value = "500" },
        .{ .name = "accept-charset", .value = "" },
        .{ .name = "accept-encoding", .value = "gzip, deflate" },
        .{ .name = "accept-language", .value = "" },
        .{ .name = "accept-ranges", .value = "" },
        .{ .name = "accept", .value = "" },
        .{ .name = "access-control-allow-origin", .value = "" },
        .{ .name = "age", .value = "" },
        .{ .name = "allow", .value = "" },
        .{ .name = "authorization", .value = "" },
        .{ .name = "cache-control", .value = "" },
        .{ .name = "content-disposition", .value = "" },
        .{ .name = "content-encoding", .value = "" },
        .{ .name = "content-language", .value = "" },
        .{ .name = "content-length", .value = "" },
        .{ .name = "content-location", .value = "" },
        .{ .name = "content-range", .value = "" },
        .{ .name = "content-type", .value = "" },
        .{ .name = "cookie", .value = "" },
        .{ .name = "date", .value = "" },
        .{ .name = "etag", .value = "" },
        .{ .name = "expect", .value = "" },
        .{ .name = "expires", .value = "" },
        .{ .name = "from", .value = "" },
        .{ .name = "host", .value = "" },
        .{ .name = "if-match", .value = "" },
        .{ .name = "if-modified-since", .value = "" },
        .{ .name = "if-none-match", .value = "" },
        .{ .name = "if-range", .value = "" },
        .{ .name = "if-unmodified-since", .value = "" },
        .{ .name = "last-modified", .value = "" },
        .{ .name = "link", .value = "" },
        .{ .name = "location", .value = "" },
        .{ .name = "max-forwards", .value = "" },
        .{ .name = "proxy-authenticate", .value = "" },
        .{ .name = "proxy-authorization", .value = "" },
        .{ .name = "range", .value = "" },
        .{ .name = "referer", .value = "" },
        .{ .name = "refresh", .value = "" },
        .{ .name = "retry-after", .value = "" },
        .{ .name = "server", .value = "" },
        .{ .name = "set-cookie", .value = "" },
        .{ .name = "strict-transport-security", .value = "" },
        .{ .name = "transfer-encoding", .value = "" },
        .{ .name = "user-agent", .value = "" },
        .{ .name = "vary", .value = "" },
        .{ .name = "via", .value = "" },
        .{ .name = "www-authenticate", .value = "" },
    };

    pub fn get(index: usize) ?Entry {
        if (index == 0 or index > entries.len) return null;
        return entries[index - 1];
    }

    pub fn find(name: []const u8, value: []const u8) ?usize {
        for (entries, 1..) |entry, idx| {
            if (std.mem.eql(u8, entry.name, name) and std.mem.eql(u8, entry.value, value)) {
                return idx;
            }
        }
        return null;
    }

    pub fn findName(name: []const u8) ?usize {
        for (entries, 1..) |entry, idx| {
            if (std.mem.eql(u8, entry.name, name)) {
                return idx;
            }
        }
        return null;
    }
};

/// Dynamic table for HPACK
pub const DynamicTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    size: usize,
    max_size: usize,

    pub const Entry = struct {
        name: []u8,
        value: []u8,

        pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.value);
        }

        pub fn size(self: Entry) usize {
            return self.name.len + self.value.len + 32; // RFC 7541: +32 bytes overhead
        }
    };

    pub fn init(allocator: std.mem.Allocator, max_size: usize) DynamicTable {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(Entry).init(allocator),
            .size = 0,
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *DynamicTable) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    pub fn add(self: *DynamicTable, name: []const u8, value: []const u8) !void {
        const new_entry = Entry{
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
        };
        const entry_size = new_entry.size();

        // Evict entries if needed
        while (self.size + entry_size > self.max_size and self.entries.items.len > 0) {
            var old = self.entries.pop();
            self.size -= old.size();
            old.deinit(self.allocator);
        }

        // Add new entry at the beginning
        try self.entries.insert(0, new_entry);
        self.size += entry_size;
    }

    pub fn get(self: *DynamicTable, index: usize) ?Entry {
        if (index == 0 or index > self.entries.items.len) return null;
        return self.entries.items[index - 1];
    }

    pub fn setMaxSize(self: *DynamicTable, new_max: usize) void {
        self.max_size = new_max;
        // Evict entries if new max is smaller
        while (self.size > self.max_size and self.entries.items.len > 0) {
            var old = self.entries.pop();
            self.size -= old.size();
            old.deinit(self.allocator);
        }
    }
};

/// HPACK Encoder
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    dynamic_table: DynamicTable,

    pub fn init(allocator: std.mem.Allocator, table_size: usize) Encoder {
        return .{
            .allocator = allocator,
            .dynamic_table = DynamicTable.init(allocator, table_size),
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.dynamic_table.deinit();
    }

    /// Encode a header field
    pub fn encodeHeader(self: *Encoder, writer: anytype, name: []const u8, value: []const u8) !void {
        // Try to find in static table
        if (StaticTable.find(name, value)) |index| {
            // Indexed header field (full match)
            try self.encodeInteger(writer, 7, 0b10000000, index);
            return;
        }

        // Try to find name in static table
        if (StaticTable.findName(name)) |index| {
            // Literal with incremental indexing - indexed name
            try self.encodeInteger(writer, 6, 0b01000000, index);
            try self.encodeString(writer, value, false);
            try self.dynamic_table.add(name, value);
            return;
        }

        // Literal with incremental indexing - new name
        try writer.writeByte(0b01000000);
        try self.encodeString(writer, name, false);
        try self.encodeString(writer, value, false);
        try self.dynamic_table.add(name, value);
    }

    /// Encode an integer with prefix
    fn encodeInteger(self: *Encoder, writer: anytype, prefix: u8, mask: u8, value: usize) !void {
        _ = self;
        const max_prefix_value: usize = (@as(usize, 1) << @intCast(prefix)) - 1;

        if (value < max_prefix_value) {
            try writer.writeByte(@intCast(mask | value));
        } else {
            try writer.writeByte(@intCast(mask | max_prefix_value));
            var remaining = value - max_prefix_value;
            while (remaining >= 128) {
                try writer.writeByte(@intCast((remaining & 0x7F) | 0x80));
                remaining >>= 7;
            }
            try writer.writeByte(@intCast(remaining));
        }
    }

    /// Encode a string (with optional Huffman coding)
    fn encodeString(self: *Encoder, writer: anytype, str: []const u8, huffman: bool) !void {
        if (huffman) {
            // TODO: Implement Huffman encoding
            try self.encodeInteger(writer, 7, 0b10000000, str.len);
        } else {
            try self.encodeInteger(writer, 7, 0b00000000, str.len);
        }
        try writer.writeAll(str);
    }
};

/// HPACK Decoder
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    dynamic_table: DynamicTable,

    pub fn init(allocator: std.mem.Allocator, table_size: usize) Decoder {
        return .{
            .allocator = allocator,
            .dynamic_table = DynamicTable.init(allocator, table_size),
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.dynamic_table.deinit();
    }

    /// Decode a header block
    pub fn decodeHeaderBlock(self: *Decoder, data: []const u8) !std.ArrayList(struct { name: []u8, value: []u8 }) {
        var headers = std.ArrayList(struct { name: []u8, value: []u8 }).init(self.allocator);
        var pos: usize = 0;

        while (pos < data.len) {
            const byte = data[pos];

            if (byte & 0b10000000 != 0) {
                // Indexed header field
                const index = try self.decodeInteger(data, &pos, 7);
                const entry = try self.getTableEntry(index);
                try headers.append(.{
                    .name = try self.allocator.dupe(u8, entry.name),
                    .value = try self.allocator.dupe(u8, entry.value),
                });
            } else if (byte & 0b01000000 != 0) {
                // Literal with incremental indexing
                pos += 1;
                const header = try self.decodeLiteralHeader(data, &pos, true);
                try headers.append(header);
            } else if (byte & 0b00100000 != 0) {
                // Dynamic table size update
                const new_size = try self.decodeInteger(data, &pos, 5);
                self.dynamic_table.setMaxSize(new_size);
            } else {
                // Literal without indexing or never indexed
                pos += 1;
                const header = try self.decodeLiteralHeader(data, &pos, false);
                try headers.append(header);
            }
        }

        return headers;
    }

    fn getTableEntry(self: *Decoder, index: usize) !struct { name: []const u8, value: []const u8 } {
        const static_size = StaticTable.entries.len;
        if (index <= static_size) {
            const entry = StaticTable.get(index) orelse return error.InvalidIndex;
            return .{ .name = entry.name, .value = entry.value };
        } else {
            const dynamic_index = index - static_size;
            const entry = self.dynamic_table.get(dynamic_index) orelse return error.InvalidIndex;
            return .{ .name = entry.name, .value = entry.value };
        }
    }

    fn decodeLiteralHeader(self: *Decoder, data: []const u8, pos: *usize, add_to_table: bool) !struct { name: []u8, value: []u8 } {
        var name: []u8 = undefined;
        var value: []u8 = undefined;

        _ = data[pos.* - 1]; // first_byte - reserved for future use
        const name_index = try self.decodeInteger(data, pos, 6);

        if (name_index == 0) {
            // New name
            name = try self.decodeString(data, pos);
        } else {
            // Indexed name
            const entry = try self.getTableEntry(name_index);
            name = try self.allocator.dupe(u8, entry.name);
        }

        value = try self.decodeString(data, pos);

        if (add_to_table) {
            try self.dynamic_table.add(name, value);
        }

        return .{ .name = name, .value = value };
    }

    fn decodeInteger(self: *Decoder, data: []const u8, pos: *usize, prefix: u8) !usize {
        _ = self;
        const max_prefix_value: usize = (@as(usize, 1) << @intCast(prefix)) - 1;
        const mask: u8 = @intCast(max_prefix_value);

        var value: usize = data[pos.*] & mask;
        pos.* += 1;

        if (value < max_prefix_value) {
            return value;
        }

        var m: usize = 0;
        while (pos.* < data.len) {
            const byte = data[pos.*];
            pos.* += 1;

            value += (byte & 0x7F) << @intCast(m);
            m += 7;

            if (byte & 0x80 == 0) {
                break;
            }
        }

        return value;
    }

    fn decodeString(self: *Decoder, data: []const u8, pos: *usize) ![]u8 {
        const first_byte = data[pos.*];
        const huffman = (first_byte & 0x80) != 0;
        const length = try self.decodeInteger(data, pos, 7);

        if (pos.* + length > data.len) {
            return error.InvalidLength;
        }

        const string_data = data[pos.* .. pos.* + length];
        pos.* += length;

        if (huffman) {
            // TODO: Implement Huffman decoding
            return try self.allocator.dupe(u8, string_data);
        } else {
            return try self.allocator.dupe(u8, string_data);
        }
    }
};

test "static table lookup" {
    const entry = StaticTable.get(2).?;
    try std.testing.expectEqualStrings(":method", entry.name);
    try std.testing.expectEqualStrings("GET", entry.value);
}

test "hpack encoder basic" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator, 4096);
    defer encoder.deinit();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try encoder.encodeHeader(buffer.writer(), ":method", "GET");
    try std.testing.expect(buffer.items.len > 0);
}
