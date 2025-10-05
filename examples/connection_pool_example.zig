const std = @import("std");
const zhttp = @import("zhttp");

/// Example demonstrating connection pooling with keep-alive
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a connection pool
    var pool = zhttp.ConnectionPool.init(allocator, .{
        .max_connections_per_host = 6,
        .max_idle_time_seconds = 90,
        .max_connection_lifetime = 600,
        .enable_keep_alive = true,
    });
    defer pool.deinit();

    std.debug.print("Connection Pool Example\n", .{});
    std.debug.print("======================\n\n", .{});

    // Make multiple requests reusing connections
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        std.debug.print("Request #{}\n", .{i + 1});

        // Acquire connection from pool
        var conn = pool.acquire("httpbin.org", 80, false) catch |err| {
            std.debug.print("Failed to acquire connection: {}\n", .{err});
            continue;
        };

        std.debug.print("  Connection ID: {}\n", .{conn.id});
        std.debug.print("  Use count: {}\n", .{conn.use_count});
        std.debug.print("  State: {}\n", .{conn.state});

        // Simulate using the connection
        std.time.sleep(100 * std.time.ns_per_ms);

        // Release connection back to pool (with keep-alive)
        pool.release(conn, true);

        std.debug.print("  Released back to pool\n\n", .{});
    }

    // Get pool statistics
    const stats = pool.getStats();
    std.debug.print("Pool Statistics:\n", .{});
    std.debug.print("  Total connections: {}\n", .{stats.total_connections});
    std.debug.print("  Idle connections: {}\n", .{stats.idle_connections});
    std.debug.print("  Active connections: {}\n", .{stats.active_connections});
}
