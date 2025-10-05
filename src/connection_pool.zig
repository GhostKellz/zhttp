const std = @import("std");
const net = std.net;

/// Connection pooling with keep-alive support
/// Implements connection reuse per RFC 7230 Section 6.3

/// Connection state
pub const ConnectionState = enum {
    idle,
    active,
    closing,
    closed,
};

/// Pooled connection
pub const PooledConnection = struct {
    stream: net.Stream,
    host: []const u8,
    port: u16,
    state: ConnectionState,
    last_used: i64, // Timestamp
    use_count: usize,
    is_tls: bool,

    pub fn init(allocator: std.mem.Allocator, stream: net.Stream, host: []const u8, port: u16, is_tls: bool) !PooledConnection {
        return .{
            .stream = stream,
            .host = try allocator.dupe(u8, host),
            .port = port,
            .state = .idle,
            .last_used = std.time.timestamp(),
            .use_count = 0,
            .is_tls = is_tls,
        };
    }

    pub fn deinit(self: *PooledConnection, allocator: std.mem.Allocator) void {
        self.stream.close();
        allocator.free(self.host);
    }

    pub fn isStale(self: *const PooledConnection, max_idle_seconds: i64) bool {
        const now = std.time.timestamp();
        return (now - self.last_used) > max_idle_seconds;
    }

    pub fn markUsed(self: *PooledConnection) void {
        self.last_used = std.time.timestamp();
        self.use_count += 1;
        self.state = .active;
    }

    pub fn markIdle(self: *PooledConnection) void {
        self.last_used = std.time.timestamp();
        self.state = .idle;
    }
};

/// Connection pool configuration
pub const PoolConfig = struct {
    max_connections_per_host: usize = 6, // RFC 7230 recommends max 6
    max_idle_time_seconds: i64 = 90, // 90 seconds default
    max_connection_lifetime: i64 = 600, // 10 minutes
    enable_keep_alive: bool = true,
};

/// Connection pool
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    connections: std.ArrayList(*PooledConnection),
    config: PoolConfig,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) ConnectionPool {
        return .{
            .allocator = allocator,
            .connections = std.ArrayList(*PooledConnection).init(allocator),
            .config = config,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |conn| {
            conn.deinit(self.allocator);
            self.allocator.destroy(conn);
        }
        self.connections.deinit();
    }

    /// Get a connection from the pool or create a new one
    pub fn acquire(self: *ConnectionPool, host: []const u8, port: u16, is_tls: bool) !*PooledConnection {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up stale connections first
        try self.cleanupStaleConnections();

        // Try to find an existing idle connection
        for (self.connections.items) |conn| {
            if (conn.state == .idle and
                std.mem.eql(u8, conn.host, host) and
                conn.port == port and
                conn.is_tls == is_tls and
                !conn.isStale(self.config.max_idle_time_seconds))
            {
                conn.markUsed();
                return conn;
            }
        }

        // Check if we've hit the connection limit for this host
        const host_connections = try self.countConnectionsForHost(host, port);
        if (host_connections >= self.config.max_connections_per_host) {
            return error.TooManyConnectionsForHost;
        }

        // Create a new connection
        return try self.createConnection(host, port, is_tls);
    }

    /// Release a connection back to the pool
    pub fn release(self: *ConnectionPool, conn: *PooledConnection, keep_alive: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!keep_alive or !self.config.enable_keep_alive) {
            // Close and remove the connection
            self.removeConnection(conn);
            return;
        }

        // Mark as idle for reuse
        conn.markIdle();
    }

    /// Create a new connection
    fn createConnection(self: *ConnectionPool, host: []const u8, port: u16, is_tls: bool) !*PooledConnection {
        // Connect to the host
        const stream = try net.tcpConnectToHost(self.allocator, host, port);
        errdefer stream.close();

        // TODO: Handle TLS handshake if is_tls is true
        // For now, we just create a plain TCP connection

        const conn = try self.allocator.create(PooledConnection);
        errdefer self.allocator.destroy(conn);

        conn.* = try PooledConnection.init(self.allocator, stream, host, port, is_tls);
        conn.markUsed();

        try self.connections.append(conn);
        return conn;
    }

    /// Remove a connection from the pool
    fn removeConnection(self: *ConnectionPool, conn: *PooledConnection) void {
        for (self.connections.items, 0..) |c, i| {
            if (c == conn) {
                _ = self.connections.swapRemove(i);
                conn.deinit(self.allocator);
                self.allocator.destroy(conn);
                return;
            }
        }
    }

    /// Clean up stale connections
    fn cleanupStaleConnections(self: *ConnectionPool) !void {
        var i: usize = 0;
        while (i < self.connections.items.len) {
            const conn = self.connections.items[i];
            if (conn.state == .idle and conn.isStale(self.config.max_idle_time_seconds)) {
                const removed = self.connections.swapRemove(i);
                removed.deinit(self.allocator);
                self.allocator.destroy(removed);
            } else {
                i += 1;
            }
        }
    }

    /// Count connections for a specific host
    fn countConnectionsForHost(self: *ConnectionPool, host: []const u8, port: u16) !usize {
        var count: usize = 0;
        for (self.connections.items) |conn| {
            if (std.mem.eql(u8, conn.host, host) and conn.port == port and conn.state != .closed) {
                count += 1;
            }
        }
        return count;
    }

    /// Get pool statistics
    pub fn getStats(self: *ConnectionPool) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stats = PoolStats{
            .total_connections = self.connections.items.len,
            .idle_connections = 0,
            .active_connections = 0,
        };

        for (self.connections.items) |conn| {
            switch (conn.state) {
                .idle => stats.idle_connections += 1,
                .active => stats.active_connections += 1,
                else => {},
            }
        }

        return stats;
    }
};

/// Pool statistics
pub const PoolStats = struct {
    total_connections: usize,
    idle_connections: usize,
    active_connections: usize,
};

test "connection pool basic" {
    const allocator = std.testing.allocator;

    var pool = ConnectionPool.init(allocator, .{});
    defer pool.deinit();

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.total_connections);
}

test "pooled connection staleness" {
    const allocator = std.testing.allocator;

    var stream = try net.tcpConnectToHost(allocator, "localhost", 80);
    defer stream.close();

    var conn = try PooledConnection.init(allocator, stream, "localhost", 80, false);
    defer conn.deinit(allocator);

    // Shouldn't be stale immediately
    try std.testing.expect(!conn.isStale(90));

    // Simulate old timestamp
    conn.last_used = std.time.timestamp() - 100;
    try std.testing.expect(conn.isStale(90));
}
