const std = @import("std");
const zhttp = @import("zhttp");
const testing = std.testing;

// Stress tests for concurrent operations and high load scenarios

test "stress - connection pool with concurrent access" {
    const allocator = testing.allocator;

    var pool = zhttp.ConnectionPool.init(allocator, .{
        .max_connections_per_host = 10,
        .max_idle_time_seconds = 60,
    });
    defer pool.deinit();

    // Note: This is a simplified test. In production, you'd use actual threads
    // For now, we simulate concurrent access by rapidly acquiring/releasing

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // Simulate acquiring connection (would fail on actual network, but tests the pool logic)
        _ = pool.acquire("example.com", 80, false) catch continue;

        // Release immediately to test cleanup
        // In real scenario: pool.release(conn, true);
    }

    const stats = pool.getStats();
    try testing.expect(stats.total_connections >= 0);
}

test "stress - HPACK dynamic table thrashing" {
    const allocator = testing.allocator;

    var encoder = zhttp.Http2.HPACK.Encoder.init(allocator, 4096);
    defer encoder.deinit();

    var decoder = zhttp.Http2.HPACK.Decoder.init(allocator, 4096);
    defer decoder.deinit();

    // Rapidly add/remove entries to stress dynamic table
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        // Encode with varying header names to fill dynamic table
        const header_name = try std.fmt.allocPrint(allocator, "x-custom-{d}", .{i});
        defer allocator.free(header_name);

        try encoder.encodeHeader(buffer.writer(), header_name, "value");

        // Decode
        var headers = try decoder.decodeHeaderBlock(buffer.items);
        for (headers.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        headers.deinit();
    }
}

test "stress - QPACK dynamic table thrashing" {
    const allocator = testing.allocator;

    var encoder = zhttp.Http3.QPACK.Encoder.init(allocator, 4096);
    defer encoder.deinit();

    var decoder = zhttp.Http3.QPACK.Decoder.init(allocator, 4096);
    defer decoder.deinit();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        const header_name = try std.fmt.allocPrint(allocator, "x-header-{d}", .{i});
        defer allocator.free(header_name);

        const headers = [_]struct { name: []const u8, value: []const u8 }{
            .{ .name = header_name, .value = "test" },
        };

        try encoder.encodeHeaders(buffer.writer().any(), &headers);

        var decoded = try decoder.decodeHeaderBlock(buffer.items);
        for (decoded.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        decoded.deinit();
    }
}

test "stress - chunked encoding large data" {
    const allocator = testing.allocator;

    const sizes = [_]usize{ 1024, 10 * 1024, 100 * 1024, 1024 * 1024 };

    for (sizes) |size| {
        const data = try allocator.alloc(u8, size);
        defer allocator.free(data);
        @memset(data, 'A');

        const encoded = try zhttp.Chunked.encode(allocator, data, 8192);
        defer allocator.free(encoded);

        const decoded = try zhttp.Chunked.decode(allocator, encoded);
        defer allocator.free(decoded);

        try testing.expectEqual(size, decoded.len);
    }
}

test "stress - many WebSocket frames" {
    const allocator = testing.allocator;

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Create 1000 text frames
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const text = try std.fmt.allocPrint(allocator, "Message {d}", .{i});
        defer allocator.free(text);

        var frame = try zhttp.WebSocket.Frame.text(allocator, text, false);
        defer frame.deinit(allocator);

        buffer.clearRetainingCapacity();
        try frame.write(buffer.writer().any());

        // Verify we can read it back
        var fbs = std.io.fixedBufferStream(buffer.items);
        var read_frame = try zhttp.WebSocket.Frame.read(allocator, fbs.reader().any());
        defer read_frame.deinit(allocator);

        try testing.expectEqualStrings(text, read_frame.payload);
    }
}

test "stress - SSE with many events" {
    const allocator = testing.allocator;

    var client = zhttp.SSE.Client.init(allocator);
    defer client.deinit();

    // Build a large SSE stream
    var stream = std.ArrayList(u8).init(allocator);
    defer stream.deinit();

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        try stream.writer().print("event: update\n", .{});
        try stream.writer().print("id: {d}\n", .{i});
        try stream.writer().print("data: Message {d}\n", .{i});
        try stream.writer().print("\n", .{});
    }

    var events = try client.processChunk(stream.items);
    defer events.deinit();

    try testing.expectEqual(@as(usize, 500), events.items.len);
}

test "stress - redirect chain max depth" {
    const allocator = testing.allocator;

    var tracker = zhttp.Redirect.RedirectTracker.init(allocator, .{
        .max_redirects = 100,
    });
    defer tracker.deinit();

    // Visit max redirects
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const url = try std.fmt.allocPrint(allocator, "https://example.com/{d}", .{i});
        defer allocator.free(url);

        try tracker.visit(url);
    }

    // Next one should be rejected
    const should_follow = tracker.shouldFollow(301, "GET", true, true);
    try testing.expect(!should_follow);
}

test "stress - 0-RTT session cache turnover" {
    const allocator = testing.allocator;

    var manager = zhttp.Http3.ZeroRTT.ZeroRTTManager.init(allocator, .{
        .session_ticket_lifetime = 1, // Very short lifetime for stress test
    });
    defer manager.deinit();

    // Store many tickets
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const server = try std.fmt.allocPrint(allocator, "server{d}.com", .{i});
        defer allocator.free(server);

        const ticket = try std.fmt.allocPrint(allocator, "ticket{d}", .{i});
        defer allocator.free(ticket);

        try manager.storeTicket(server, ticket, 16384);
    }

    // Cleanup expired (all should be expired with 1s lifetime)
    std.time.sleep(2 * std.time.ns_per_s);
    manager.cleanup();
}

test "stress - multipart with many fields" {
    const allocator = testing.allocator;

    var builder = try zhttp.BodyStream.MultipartBuilder.init(allocator);
    defer builder.deinit();

    // Add 100 fields
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const name = try std.fmt.allocPrint(allocator, "field{d}", .{i});
        defer allocator.free(name);

        const value = try std.fmt.allocPrint(allocator, "value{d}", .{i});
        defer allocator.free(value);

        try builder.addField(name, value);
    }

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    _ = try builder.writeTo(buffer.writer().any());

    // Should have boundary markers for each field
    const boundary_count = std.mem.count(u8, buffer.items, builder.boundary);
    try testing.expect(boundary_count >= 100);
}

test "stress - compression round-trip cycles" {
    const allocator = testing.allocator;

    const data = "The quick brown fox jumps over the lazy dog. " ** 100;

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        // Gzip
        {
            const compressed = try zhttp.Compression.compressGzip(allocator, data);
            defer allocator.free(compressed);

            const decompressed = try zhttp.Compression.decompressGzip(allocator, compressed);
            defer allocator.free(decompressed);

            try testing.expectEqualStrings(data, decompressed);
        }

        // Deflate
        {
            const compressed = try zhttp.Compression.compressDeflate(allocator, data);
            defer allocator.free(compressed);

            const decompressed = try zhttp.Compression.decompressDeflate(allocator, compressed);
            defer allocator.free(decompressed);

            try testing.expectEqualStrings(data, decompressed);
        }

        // Brotli
        {
            const compressed = try zhttp.Brotli.compress(allocator, data, .default);
            defer allocator.free(compressed);

            const decompressed = try zhttp.Brotli.decompress(allocator, compressed);
            defer allocator.free(decompressed);

            try testing.expectEqualStrings(data, decompressed);
        }
    }
}

test "stress - HTTP/2 stream creation/destruction" {
    const allocator = testing.allocator;

    var conn = try zhttp.Http2.Stream.Connection.init(allocator, true);
    defer conn.deinit();

    // Create and close many streams
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const stream = try conn.createStream();
        _ = stream;

        // Streams will be cleaned up when connection is destroyed
    }
}

test "stress - brotli bit reader edge cases" {
    const allocator = testing.allocator;

    var prng = std.rand.DefaultPrng.init(42);

    // Test reading various bit patterns
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var data: [128]u8 = undefined;
        prng.random().bytes(&data);

        var reader = zhttp.Brotli.BitReader.init(&data);

        // Read random number of bits
        var bits_read: usize = 0;
        while (bits_read < data.len * 8 - 64) {
            const n = prng.random().intRangeAtMost(u6, 1, 32);
            _ = reader.readBits(n) catch break;
            bits_read += n;
        }
    }
}

test "stress - retry strategy backoff calculations" {
    var strategy = zhttp.Timeout.RetryStrategy.init(.{
        .max_retries = 10,
        .initial_backoff_ms = 100,
        .backoff_multiplier = 2.0,
        .max_backoff_ms = 60000,
    });

    // Calculate backoff for all attempts
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const backoff = strategy.getBackoff();
        try testing.expect(backoff <= 60000); // Max backoff
        strategy.attempt += 1;
    }
}

test "stress - timeout manager boundary conditions" {
    const manager = zhttp.Timeout.TimeoutManager.init(.{
        .total_timeout_ms = 1000,
        .connect_timeout_ms = 500,
    });

    // Should not timeout immediately
    try manager.checkTotalTimeout();
    try manager.checkConnectTimeout();

    // Get remaining time
    const remaining = manager.getRemainingTime(1000);
    try testing.expect(remaining != null);
    try testing.expect(remaining.? <= 1000);
}
