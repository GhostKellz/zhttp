const std = @import("std");

/// HTTP header representation
pub const Header = struct {
    name: []const u8,
    value: []const u8,
    
    pub fn init(name: []const u8, value: []const u8) Header {
        return Header{
            .name = name,
            .value = value,
        };
    }
    
    /// Check if header name matches (case-insensitive)
    pub fn nameEquals(self: Header, name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name, name);
    }
    
    /// Validate header name according to RFC 7230
    pub fn isValidName(name: []const u8) bool {
        if (name.len == 0) return false;
        
        for (name) |c| {
            if (!isTokenChar(c)) return false;
        }
        return true;
    }
    
    /// Validate header value according to RFC 7230
    pub fn isValidValue(value: []const u8) bool {
        for (value) |c| {
            // Allow visible VCHAR plus SP/HTAB, but no other control chars
            if (c < 0x20 and c != 0x09) return false; // No control chars except tab
            if (c == 0x7F) return false; // DEL
        }
        return true;
    }
};

/// Collection of HTTP headers with case-insensitive lookup
pub const HeaderMap = struct {
    allocator: std.mem.Allocator,
    headers: std.ArrayList(Header),
    
    pub fn init(allocator: std.mem.Allocator) HeaderMap {
        return HeaderMap{
            .allocator = allocator,
            .headers = std.ArrayList(Header){},
        };
    }
    
    pub fn deinit(self: *HeaderMap) void {
        // Note: We don't own the header name/value strings, 
        // they should be managed by the caller
        self.headers.deinit(self.allocator);
    }
    
    /// Add a header (doesn't check for duplicates)
    pub fn append(self: *HeaderMap, name: []const u8, value: []const u8) !void {
        if (!Header.isValidName(name)) return error.InvalidHeader;
        if (!Header.isValidValue(value)) return error.InvalidHeader;
        
        try self.headers.append(self.allocator, Header.init(name, value));
    }
    
    /// Set a header, replacing any existing header with same name
    pub fn set(self: *HeaderMap, name: []const u8, value: []const u8) !void {
        if (!Header.isValidName(name)) return error.InvalidHeader;
        if (!Header.isValidValue(value)) return error.InvalidHeader;
        
        // Remove existing headers with same name
        var i: usize = 0;
        while (i < self.headers.items.len) {
            if (self.headers.items[i].nameEquals(name)) {
                _ = self.headers.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        
        try self.headers.append(self.allocator, Header.init(name, value));
    }
    
    /// Get first header value with given name (case-insensitive)
    pub fn get(self: HeaderMap, name: []const u8) ?[]const u8 {
        for (self.headers.items) |header| {
            if (header.nameEquals(name)) {
                return header.value;
            }
        }
        return null;
    }
    
    /// Get all header values with given name
    pub fn getAll(self: HeaderMap, name: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
        var values = std.ArrayList([]const u8){};
        defer values.deinit(allocator);
        
        for (self.headers.items) |header| {
            if (header.nameEquals(name)) {
                try values.append(allocator, header.value);
            }
        }
        
        return values.toOwnedSlice(allocator);
    }
    
    /// Check if header exists
    pub fn has(self: HeaderMap, name: []const u8) bool {
        return self.get(name) != null;
    }
    
    /// Remove all headers with given name
    pub fn remove(self: *HeaderMap, name: []const u8) void {
        var i: usize = 0;
        while (i < self.headers.items.len) {
            if (self.headers.items[i].nameEquals(name)) {
                _ = self.headers.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
    
    /// Get all headers
    pub fn items(self: HeaderMap) []Header {
        return self.headers.items;
    }
    
    /// Count of headers
    pub fn count(self: HeaderMap) usize {
        return self.headers.items.len;
    }
};

/// Check if character is valid in HTTP token
fn isTokenChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9',
        '!', '#', '$', '%', '&', '\'', '*',
        '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// Common HTTP header names
pub const common = struct {
    pub const ACCEPT = "Accept";
    pub const ACCEPT_ENCODING = "Accept-Encoding";
    pub const ACCEPT_LANGUAGE = "Accept-Language";
    pub const AUTHORIZATION = "Authorization";
    pub const CACHE_CONTROL = "Cache-Control";
    pub const CONNECTION = "Connection";
    pub const CONTENT_ENCODING = "Content-Encoding";
    pub const CONTENT_LENGTH = "Content-Length";
    pub const CONTENT_TYPE = "Content-Type";
    pub const COOKIE = "Cookie";
    pub const DATE = "Date";
    pub const HOST = "Host";
    pub const LOCATION = "Location";
    pub const SET_COOKIE = "Set-Cookie";
    pub const TRANSFER_ENCODING = "Transfer-Encoding";
    pub const USER_AGENT = "User-Agent";
    pub const WWW_AUTHENTICATE = "WWW-Authenticate";
};

test "header validation" {
    try std.testing.expect(Header.isValidName("Content-Type"));
    try std.testing.expect(!Header.isValidName(""));
    try std.testing.expect(!Header.isValidName("Con tent-Type")); // space not allowed
    
    try std.testing.expect(Header.isValidValue("application/json"));
    try std.testing.expect(Header.isValidValue("text/html; charset=utf-8"));
    try std.testing.expect(!Header.isValidValue("test\x01value")); // control char
}

test "header map basic operations" {
    var map = HeaderMap.init(std.testing.allocator);
    defer map.deinit();
    
    try map.append("Content-Type", "application/json");
    try map.append("Authorization", "Bearer token");
    
    try std.testing.expect(map.has("content-type")); // case insensitive
    try std.testing.expectEqualStrings("application/json", map.get("Content-Type").?);
    try std.testing.expect(map.get("nonexistent") == null);
    
    try map.set("Content-Type", "text/html"); // replace
    try std.testing.expectEqualStrings("text/html", map.get("Content-Type").?);
}

test "header map multiple values" {
    var map = HeaderMap.init(std.testing.allocator);
    defer map.deinit();
    
    try map.append("Accept", "text/html");
    try map.append("Accept", "application/json");
    
    const values = try map.getAll("Accept", std.testing.allocator);
    defer std.testing.allocator.free(values);
    
    try std.testing.expect(values.len == 2);
    try std.testing.expectEqualStrings("text/html", values[0]);
    try std.testing.expectEqualStrings("application/json", values[1]);
}