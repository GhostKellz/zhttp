const std = @import("std");

/// QPACK - QPACK: Header Compression for HTTP/3
/// Implements RFC 9204: https://www.rfc-editor.org/rfc/rfc9204.html

/// QPACK Static Table (RFC 9204 Appendix A)
pub const StaticTable = struct {
    pub const Entry = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const entries = [_]Entry{
        .{ .name = ":authority", .value = "" },
        .{ .name = ":path", .value = "/" },
        .{ .name = "age", .value = "0" },
        .{ .name = "content-disposition", .value = "" },
        .{ .name = "content-length", .value = "0" },
        .{ .name = "cookie", .value = "" },
        .{ .name = "date", .value = "" },
        .{ .name = "etag", .value = "" },
        .{ .name = "if-modified-since", .value = "" },
        .{ .name = "if-none-match", .value = "" },
        .{ .name = "last-modified", .value = "" },
        .{ .name = "link", .value = "" },
        .{ .name = "location", .value = "" },
        .{ .name = "referer", .value = "" },
        .{ .name = "set-cookie", .value = "" },
        .{ .name = ":method", .value = "CONNECT" },
        .{ .name = ":method", .value = "DELETE" },
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":method", .value = "HEAD" },
        .{ .name = ":method", .value = "OPTIONS" },
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":method", .value = "PUT" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":status", .value = "103" },
        .{ .name = ":status", .value = "200" },
        .{ .name = ":status", .value = "304" },
        .{ .name = ":status", .value = "404" },
        .{ .name = ":status", .value = "503" },
        .{ .name = "accept", .value = "*/*" },
        .{ .name = "accept", .value = "application/dns-message" },
        .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
        .{ .name = "accept-ranges", .value = "bytes" },
        .{ .name = "access-control-allow-headers", .value = "cache-control" },
        .{ .name = "access-control-allow-headers", .value = "content-type" },
        .{ .name = "access-control-allow-origin", .value = "*" },
        .{ .name = "cache-control", .value = "max-age=0" },
        .{ .name = "cache-control", .value = "max-age=2592000" },
        .{ .name = "cache-control", .value = "max-age=604800" },
        .{ .name = "cache-control", .value = "no-cache" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "cache-control", .value = "public, max-age=31536000" },
        .{ .name = "content-encoding", .value = "br" },
        .{ .name = "content-encoding", .value = "gzip" },
        .{ .name = "content-type", .value = "application/dns-message" },
        .{ .name = "content-type", .value = "application/javascript" },
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "content-type", .value = "image/gif" },
        .{ .name = "content-type", .value = "image/jpeg" },
        .{ .name = "content-type", .value = "image/png" },
        .{ .name = "content-type", .value = "text/css" },
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "content-type", .value = "text/plain;charset=utf-8" },
        .{ .name = "range", .value = "bytes=0-" },
        .{ .name = "strict-transport-security", .value = "max-age=31536000" },
        .{ .name = "strict-transport-security", .value = "max-age=31536000; includesubdomains" },
        .{ .name = "strict-transport-security", .value = "max-age=31536000; includesubdomains; preload" },
        .{ .name = "vary", .value = "accept-encoding" },
        .{ .name = "vary", .value = "origin" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "x-xss-protection", .value = "1; mode=block" },
        .{ .name = ":status", .value = "100" },
        .{ .name = ":status", .value = "204" },
        .{ .name = ":status", .value = "206" },
        .{ .name = ":status", .value = "302" },
        .{ .name = ":status", .value = "400" },
        .{ .name = ":status", .value = "403" },
        .{ .name = ":status", .value = "421" },
        .{ .name = ":status", .value = "425" },
        .{ .name = ":status", .value = "500" },
        .{ .name = "accept-language", .value = "" },
        .{ .name = "access-control-allow-credentials", .value = "FALSE" },
        .{ .name = "access-control-allow-credentials", .value = "TRUE" },
        .{ .name = "access-control-allow-headers", .value = "*" },
        .{ .name = "access-control-allow-methods", .value = "get" },
        .{ .name = "access-control-allow-methods", .value = "get, post, options" },
        .{ .name = "access-control-allow-methods", .value = "options" },
        .{ .name = "access-control-expose-headers", .value = "content-length" },
        .{ .name = "access-control-request-headers", .value = "content-type" },
        .{ .name = "access-control-request-method", .value = "get" },
        .{ .name = "access-control-request-method", .value = "post" },
        .{ .name = "alt-svc", .value = "clear" },
        .{ .name = "authorization", .value = "" },
        .{ .name = "content-security-policy", .value = "script-src 'none'; object-src 'none'; base-uri 'none'" },
        .{ .name = "early-data", .value = "1" },
        .{ .name = "expect-ct", .value = "" },
        .{ .name = "forwarded", .value = "" },
        .{ .name = "if-range", .value = "" },
        .{ .name = "origin", .value = "" },
        .{ .name = "purpose", .value = "prefetch" },
        .{ .name = "server", .value = "" },
        .{ .name = "timing-allow-origin", .value = "*" },
        .{ .name = "upgrade-insecure-requests", .value = "1" },
        .{ .name = "user-agent", .value = "" },
        .{ .name = "x-forwarded-for", .value = "" },
        .{ .name = "x-frame-options", .value = "deny" },
        .{ .name = "x-frame-options", .value = "sameorigin" },
    };

    pub fn get(index: usize) ?Entry {
        if (index >= entries.len) return null;
        return entries[index];
    }

    pub fn find(name: []const u8, value: []const u8) ?usize {
        for (entries, 0..) |entry, idx| {
            if (std.mem.eql(u8, entry.name, name) and std.mem.eql(u8, entry.value, value)) {
                return idx;
            }
        }
        return null;
    }

    pub fn findName(name: []const u8) ?usize {
        for (entries, 0..) |entry, idx| {
            if (std.mem.eql(u8, entry.name, name)) {
                return idx;
            }
        }
        return null;
    }
};

/// QPACK Dynamic Table
pub const DynamicTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),
    size: usize,
    max_size: usize,
    insert_count: u64,

    pub const Entry = struct {
        name: []u8,
        value: []u8,

        pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.value);
        }

        pub fn size(self: Entry) usize {
            return self.name.len + self.value.len + 32;
        }
    };

    pub fn init(allocator: std.mem.Allocator, max_size: usize) DynamicTable {
        return .{
            .allocator = allocator,
            .entries = .{},
            .size = 0,
            .max_size = max_size,
            .insert_count = 0,
        };
    }

    pub fn deinit(self: *DynamicTable) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn insert(self: *DynamicTable, name: []const u8, value: []const u8) !void {
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

        try self.entries.insert(self.allocator, 0, new_entry);
        self.size += entry_size;
        self.insert_count += 1;
    }

    pub fn get(self: *const DynamicTable, index: usize) ?Entry {
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index];
    }

    pub fn setMaxSize(self: *DynamicTable, new_max: usize) void {
        self.max_size = new_max;
        while (self.size > self.max_size and self.entries.items.len > 0) {
            var old = self.entries.pop();
            self.size -= old.size();
            old.deinit(self.allocator);
        }
    }
};

/// QPACK Encoder
pub const Encoder = struct {
    allocator: std.mem.Allocator,
    dynamic_table: DynamicTable,
    max_blocked_streams: usize,

    pub fn init(allocator: std.mem.Allocator, table_size: usize, max_blocked: usize) Encoder {
        return .{
            .allocator = allocator,
            .dynamic_table = DynamicTable.init(allocator, table_size),
            .max_blocked_streams = max_blocked,
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.dynamic_table.deinit();
    }

    /// Encode header field list
    pub fn encodeHeaders(self: *Encoder, writer: anytype, headers: []const struct { name: []const u8, value: []const u8 }) !void {
        // Required Insert Count (0 for now - simplified)
        try self.encodeInteger(writer, 0, 8);

        // Base (0 for now - simplified)
        try writer.writeByte(0);

        for (headers) |header| {
            try self.encodeHeader(writer, header.name, header.value);
        }
    }

    fn encodeHeader(self: *Encoder, writer: anytype, name: []const u8, value: []const u8) !void {
        // Try static table first
        if (StaticTable.find(name, value)) |index| {
            // Indexed field line with static table
            try self.encodeInteger(writer, index + 1, 6);
            try writer.writeByte(0xC0); // 11xxxxxx pattern
            return;
        }

        // Literal with name reference (static table)
        if (StaticTable.findName(name)) |index| {
            try writer.writeByte(0x50); // 01010000 - literal with name ref
            try self.encodeInteger(writer, index, 4);
            try self.encodeString(writer, value);
            return;
        }

        // Literal without name reference
        try writer.writeByte(0x20); // 00100000 - literal
        try self.encodeString(writer, name);
        try self.encodeString(writer, value);
    }

    fn encodeInteger(self: *Encoder, writer: anytype, value: usize, prefix: u8) !void {
        _ = self;
        const max_prefix_value: usize = (@as(usize, 1) << @intCast(prefix)) - 1;

        if (value < max_prefix_value) {
            try writer.writeByte(@intCast(value));
        } else {
            try writer.writeByte(@intCast(max_prefix_value));
            var remaining = value - max_prefix_value;
            while (remaining >= 128) {
                try writer.writeByte(@intCast((remaining & 0x7F) | 0x80));
                remaining >>= 7;
            }
            try writer.writeByte(@intCast(remaining));
        }
    }

    fn encodeString(self: *Encoder, writer: anytype, str: []const u8) !void {
        // Length prefix (no Huffman for now)
        try self.encodeInteger(writer, str.len, 7);
        try writer.writeAll(str);
    }
};

/// QPACK Decoder
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

    /// Decode header block
    pub fn decodeHeaders(self: *Decoder, data: []const u8) !std.ArrayList(struct { name: []u8, value: []u8 }) {
        var headers: std.ArrayList(struct { name: []u8, value: []u8 }) = .{};
        var pos: usize = 0;

        // Skip Required Insert Count and Base
        _ = try self.decodeInteger(data, &pos, 8);
        if (pos < data.len) {
            pos += 1; // Skip base
        }

        while (pos < data.len) {
            const byte = data[pos];

            if (byte & 0xC0 == 0xC0) {
                // Indexed field line
                const index = try self.decodeInteger(data, &pos, 6);
                const entry = try self.getTableEntry(index);
                try headers.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, entry.name),
                    .value = try self.allocator.dupe(u8, entry.value),
                });
            } else if (byte & 0x50 == 0x50) {
                // Literal with name reference
                pos += 1;
                const name_index = try self.decodeInteger(data, &pos, 4);
                const entry = try self.getTableEntry(name_index);
                const value = try self.decodeString(data, &pos);
                try headers.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, entry.name),
                    .value = value,
                });
            } else {
                // Literal without name reference
                pos += 1;
                const name = try self.decodeString(data, &pos);
                const value = try self.decodeString(data, &pos);
                try headers.append(self.allocator, .{ .name = name, .value = value });
            }
        }

        return headers;
    }

    fn getTableEntry(self: *Decoder, index: usize) !struct { name: []const u8, value: []const u8 } {
        if (index < StaticTable.entries.len) {
            const entry = StaticTable.get(index) orelse return error.InvalidIndex;
            return .{ .name = entry.name, .value = entry.value };
        } else {
            const dynamic_index = index - StaticTable.entries.len;
            const entry = self.dynamic_table.get(dynamic_index) orelse return error.InvalidIndex;
            return .{ .name = entry.name, .value = entry.value };
        }
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
        const length = try self.decodeInteger(data, pos, 7);

        if (pos.* + length > data.len) {
            return error.InvalidLength;
        }

        const string_data = data[pos.* .. pos.* + length];
        pos.* += length;

        return try self.allocator.dupe(u8, string_data);
    }
};

test "qpack static table" {
    const entry = StaticTable.get(17).?;
    try std.testing.expectEqualStrings(":method", entry.name);
    try std.testing.expectEqualStrings("GET", entry.value);
}

test "qpack encoder basic" {
    const allocator = std.testing.allocator;
    var encoder = Encoder.init(allocator, 4096, 100);
    defer encoder.deinit();

    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);

    const headers = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/" },
    };

    try encoder.encodeHeaders(buffer.writer(allocator), &headers);
    try std.testing.expect(buffer.items.len > 0);
}
