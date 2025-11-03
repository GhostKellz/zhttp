const std = @import("std");

/// HTTP/3 0-RTT (Zero Round Trip Time) support
/// Allows sending application data in the first flight of packets
/// RFC 9114 Section 3.4

/// 0-RTT session ticket
pub const SessionTicket = struct {
    ticket: []const u8,
    timestamp: i64,
    server_name: []const u8,
    max_early_data_size: u32,

    pub fn init(allocator: std.mem.Allocator, ticket: []const u8, server_name: []const u8, max_early_data_size: u32) !SessionTicket {
        return .{
            .ticket = try allocator.dupe(u8, ticket),
            .timestamp = std.time.timestamp(),
            .server_name = try allocator.dupe(u8, server_name),
            .max_early_data_size = max_early_data_size,
        };
    }

    pub fn deinit(self: *SessionTicket, allocator: std.mem.Allocator) void {
        allocator.free(self.ticket);
        allocator.free(self.server_name);
    }

    /// Check if ticket is still valid (not expired)
    pub fn isValid(self: *const SessionTicket, max_age_seconds: i64) bool {
        const age = std.time.timestamp() - self.timestamp;
        return age < max_age_seconds;
    }
};

/// 0-RTT session cache
pub const SessionCache = struct {
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(SessionTicket),
    max_age_seconds: i64,

    pub fn init(allocator: std.mem.Allocator, max_age_seconds: i64) SessionCache {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(SessionTicket).init(allocator),
            .max_age_seconds = max_age_seconds,
        };
    }

    pub fn deinit(self: *SessionCache) void {
        var iter = self.sessions.valueIterator();
        while (iter.next()) |ticket| {
            var t = ticket.*;
            t.deinit(self.allocator);
        }
        self.sessions.deinit();
    }

    /// Store a session ticket
    pub fn put(self: *SessionCache, server_name: []const u8, ticket: SessionTicket) !void {
        const key = try self.allocator.dupe(u8, server_name);
        try self.sessions.put(key, ticket);
    }

    /// Retrieve a session ticket
    pub fn get(self: *SessionCache, server_name: []const u8) ?SessionTicket {
        const ticket = self.sessions.get(server_name) orelse return null;

        if (!ticket.isValid(self.max_age_seconds)) {
            // Ticket expired
            return null;
        }

        return ticket;
    }

    /// Remove a session ticket
    pub fn remove(self: *SessionCache, server_name: []const u8) void {
        if (self.sessions.fetchRemove(server_name)) |kv| {
            self.allocator.free(kv.key);
            var ticket = kv.value;
            ticket.deinit(self.allocator);
        }
    }

    /// Clean up expired sessions
    pub fn cleanup(self: *SessionCache) void {
        var to_remove: std.ArrayList([]const u8) = .{};
        defer to_remove.deinit(self.allocator);

        var iter = self.sessions.iterator();
        while (iter.next()) |entry| {
            if (!entry.value_ptr.isValid(self.max_age_seconds)) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            self.remove(key);
        }
    }
};

/// 0-RTT request builder
pub const ZeroRTTRequest = struct {
    headers: std.ArrayList(struct { name: []const u8, value: []const u8 }),
    body: ?[]const u8,
    method: []const u8,
    path: []const u8,

    pub fn init(allocator: std.mem.Allocator, method: []const u8, path: []const u8) ZeroRTTRequest {
        _ = allocator;
        return .{
            .headers = .{},
            .body = null,
            .method = method,
            .path = path,
        };
    }

    pub fn deinit(self: *ZeroRTTRequest, allocator: std.mem.Allocator) void {
        self.headers.deinit(allocator);
    }

    pub fn addHeader(self: *ZeroRTTRequest, allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
        try self.headers.append(allocator, .{ .name = name, .value = value });
    }

    pub fn setBody(self: *ZeroRTTRequest, body: []const u8) void {
        self.body = body;
    }

    /// Check if this request is safe for 0-RTT
    /// Only idempotent methods should be used with 0-RTT
    pub fn isSafeFor0RTT(self: *const ZeroRTTRequest) bool {
        // RFC 9114: Only safe methods (GET, HEAD, PUT, DELETE) should use 0-RTT
        // POST is NOT safe due to replay attack concerns
        return std.mem.eql(u8, self.method, "GET") or
            std.mem.eql(u8, self.method, "HEAD") or
            std.mem.eql(u8, self.method, "OPTIONS");
    }

    /// Estimate size of early data
    pub fn estimateSize(self: *const ZeroRTTRequest) usize {
        var size: usize = 0;

        // Method + path
        size += self.method.len + self.path.len + 2;

        // Headers (approximate)
        for (self.headers.items) |header| {
            size += header.name.len + header.value.len + 4;
        }

        // Body
        if (self.body) |body| {
            size += body.len;
        }

        return size;
    }
};

/// 0-RTT Configuration
pub const ZeroRTTConfig = struct {
    enabled: bool = true,
    max_early_data_size: u32 = 16384, // 16KB default
    allow_unsafe_methods: bool = false, // Allow POST etc with 0-RTT (DANGEROUS!)
    session_ticket_lifetime: i64 = 86400, // 24 hours
};

/// 0-RTT Manager
pub const ZeroRTTManager = struct {
    allocator: std.mem.Allocator,
    config: ZeroRTTConfig,
    session_cache: SessionCache,

    pub fn init(allocator: std.mem.Allocator, config: ZeroRTTConfig) ZeroRTTManager {
        return .{
            .allocator = allocator,
            .config = config,
            .session_cache = SessionCache.init(allocator, config.session_ticket_lifetime),
        };
    }

    pub fn deinit(self: *ZeroRTTManager) void {
        self.session_cache.deinit();
    }

    /// Check if 0-RTT can be used for this request
    pub fn canUse0RTT(self: *const ZeroRTTManager, request: *const ZeroRTTRequest, server_name: []const u8) bool {
        if (!self.config.enabled) return false;

        // Check if we have a valid session ticket
        const ticket = self.session_cache.get(server_name) orelse return false;

        // Check request safety
        if (!request.isSafeFor0RTT() and !self.config.allow_unsafe_methods) {
            return false;
        }

        // Check early data size limit
        if (request.estimateSize() > ticket.max_early_data_size) {
            return false;
        }

        return true;
    }

    /// Store session ticket after handshake
    pub fn storeTicket(self: *ZeroRTTManager, server_name: []const u8, ticket_data: []const u8, max_early_data: u32) !void {
        const ticket = try SessionTicket.init(self.allocator, ticket_data, server_name, max_early_data);
        try self.session_cache.put(server_name, ticket);
    }

    /// Get session ticket for server
    pub fn getTicket(self: *ZeroRTTManager, server_name: []const u8) ?SessionTicket {
        return self.session_cache.get(server_name);
    }

    /// Cleanup expired tickets
    pub fn cleanup(self: *ZeroRTTManager) void {
        self.session_cache.cleanup();
    }
};

test "session ticket validity" {
    const allocator = std.testing.allocator;

    var ticket = try SessionTicket.init(allocator, "ticket_data", "example.com", 16384);
    defer ticket.deinit(allocator);

    try std.testing.expect(ticket.isValid(86400));

    // Simulate old ticket
    ticket.timestamp = std.time.timestamp() - 100000;
    try std.testing.expect(!ticket.isValid(86400));
}

test "0rtt request safety" {
    const allocator = std.testing.allocator;

    var req_get = ZeroRTTRequest.init(allocator, "GET", "/api/data");
    defer req_get.deinit(allocator);
    try std.testing.expect(req_get.isSafeFor0RTT());

    var req_post = ZeroRTTRequest.init(allocator, "POST", "/api/data");
    defer req_post.deinit(allocator);
    try std.testing.expect(!req_post.isSafeFor0RTT());
}

test "0rtt manager" {
    const allocator = std.testing.allocator;

    var manager = ZeroRTTManager.init(allocator, .{});
    defer manager.deinit();

    // Store a ticket
    try manager.storeTicket("example.com", "ticket123", 16384);

    // Retrieve it
    const ticket = manager.getTicket("example.com");
    try std.testing.expect(ticket != null);
    try std.testing.expectEqual(@as(u32, 16384), ticket.?.max_early_data_size);
}
