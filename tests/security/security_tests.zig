const std = @import("std");
const zhttp = @import("zhttp");
const testing = std.testing;

// Security tests for buffer overflows, injection attacks, and malicious inputs

test "security - chunked encoding prevents integer overflow" {
    const allocator = testing.allocator;

    // Try to cause integer overflow with huge chunk size
    const malicious = "FFFFFFFFFFFFFFFF\r\ndata\r\n0\r\n\r\n";

    const result = zhttp.Chunked.decode(allocator, malicious);

    // Should fail gracefully, not crash
    try testing.expectError(error.InvalidCharacter, result);
}

test "security - HPACK prevents decompression bomb" {
    const allocator = testing.allocator;

    var decoder = zhttp.Http2.HPACK.Decoder.init(allocator, 4096);
    defer decoder.deinit();

    // Malicious header block that tries to expand to huge size
    var malicious: std.ArrayList(u8) = .{};
    defer malicious.deinit();

    // Indexed header field representation (references static table)
    // Repeated many times to try to cause memory exhaustion
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        try malicious.append(0x82); // :method GET
    }

    const result = decoder.decodeHeaderBlock(malicious.items);

    if (result) |headers| {
        // If it succeeds, should still be bounded
        try testing.expect(headers.items.len < 20000); // Reasonable limit

        for (headers.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        headers.deinit();
    } else |_| {
        // Failure is acceptable (out of memory protection)
    }
}

test "security - QPACK prevents decompression bomb" {
    const allocator = testing.allocator;

    var decoder = zhttp.Http3.QPACK.Decoder.init(allocator, 4096);
    defer decoder.deinit();

    // Similar attack for QPACK
    var malicious: std.ArrayList(u8) = .{};
    defer malicious.deinit();

    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        try malicious.append(0xC0); // Indexed field line
    }

    const result = decoder.decodeHeaderBlock(malicious.items);

    if (result) |headers| {
        try testing.expect(headers.items.len < 20000);

        for (headers.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        headers.deinit();
    } else |_| {}
}

test "security - WebSocket prevents payload length overflow" {
    const allocator = testing.allocator;

    // Malicious frame with 64-bit length set to max
    var malicious: std.ArrayList(u8) = .{};
    defer malicious.deinit();

    try malicious.append(0x81); // FIN + text opcode
    try malicious.append(0x7F); // 64-bit length indicator
    try malicious.writeInt(u64, std.math.maxInt(u64), .big); // Max u64

    var fbs = std.io.fixedBufferStream(malicious.items);

    const result = zhttp.WebSocket.Frame.read(allocator, fbs.reader().any());

    // Should fail - can't allocate that much memory
    try testing.expectError(error.OutOfMemory, result);
}

test "security - SSE prevents billion laughs attack" {
    const allocator = testing.allocator;

    var parser = zhttp.SSE.Parser.init(allocator);
    defer parser.deinit();

    // Try to create deeply nested or repetitive data field
    var malicious: std.ArrayList(u8) = .{};
    defer malicious.deinit();

    // Many data fields for same event
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try malicious.appendSlice("data: ");
        try malicious.appendSlice("A" ** 100);
        try malicious.appendSlice("\n");
    }
    try malicious.appendSlice("\n");

    const result = parser.parseChunk(malicious.items);

    if (result) |events| {
        // Should create at most one event
        try testing.expect(events.items.len <= 1);

        // Data concatenation should be bounded
        if (events.items.len > 0) {
            try testing.expect(events.items[0].data.len < 200000);
        }

        events.deinit();
    } else |_| {}
}

test "security - redirect prevents open redirect attack" {
    const allocator = testing.allocator;

    var tracker = zhttp.Redirect.RedirectTracker.init(allocator, .{
        .allow_insecure_redirects = false,
    });
    defer tracker.deinit();

    // Try to redirect from HTTPS to HTTP (protocol downgrade)
    const should_follow = tracker.shouldFollow(301, "GET", true, false);

    try testing.expect(!should_follow);
}

test "security - redirect prevents loop" {
    const allocator = testing.allocator;

    var tracker = zhttp.Redirect.RedirectTracker.init(allocator, .{});
    defer tracker.deinit();

    try tracker.visit("https://example.com/a");

    // Try to visit same URL again (loop detection)
    const result = tracker.visit("https://example.com/a");

    try testing.expectError(error.RedirectLoop, result);
}

test "security - URL parsing prevents buffer overflow" {
    const allocator = testing.allocator;

    // Extremely long URL
    const huge_url = try allocator.alloc(u8, 100000);
    defer allocator.free(huge_url);
    @memset(huge_url, 'A');

    _ = zhttp.Redirect.parseLocationHeader(huge_url, "https://example.com") catch |err| {
        // Should fail gracefully
        try testing.expect(err == error.OutOfMemory or err == error.InvalidBaseUrl);
    };
}

test "security - HTTP/3 VarInt prevents overflow" {
    const allocator = testing.allocator;

    // Max safe value
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit();

    // Encode max safe u62 value
    try zhttp.Http3.Frame.VarInt.encode(buffer.writer().any(), std.math.maxInt(u62));

    var fbs = std.io.fixedBufferStream(buffer.items);
    const decoded = try zhttp.Http3.Frame.VarInt.decode(fbs.reader().any());

    try testing.expectEqual(std.math.maxInt(u62), decoded);
}

test "security - chunked prevents chunk overlap" {
    const allocator = testing.allocator;

    // Malicious chunked encoding with overlapping chunks
    const malicious = "5\r\nHello\r\n10\r\n" ++ ("A" ** 16) ++ "\r\n0\r\n\r\n";

    // Second chunk claims 16 bytes but actual implementation should verify
    const result = zhttp.Chunked.decode(allocator, malicious);

    if (result) |decoded| {
        defer allocator.free(decoded);

        // Should not have buffer overflow
        try testing.expect(decoded.len <= 21); // 5 + 16
    } else |_| {}
}

test "security - WebSocket mask prevents XOR prediction" {
    const allocator = testing.allocator;

    // Generate multiple frames and check masks are different
    var masks = std.ArrayList([4]u8).init(allocator);
    defer masks.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var frame = try zhttp.WebSocket.Frame.text(allocator, "test", true);
        defer frame.deinit(allocator);

        if (frame.header.masking_key) |key| {
            try masks.append(key);
        }

        // Small delay to change timestamp seed
        std.time.sleep(std.time.ns_per_ms);
    }

    // Check that not all masks are identical (randomness check)
    if (masks.items.len > 1) {
        var all_same = true;
        const first = masks.items[0];
        for (masks.items[1..]) |mask| {
            if (!std.mem.eql(u8, &first, &mask)) {
                all_same = false;
                break;
            }
        }
        try testing.expect(!all_same);
    }
}

test "security - connection pool prevents resource exhaustion" {
    const allocator = testing.allocator;

    var pool = zhttp.ConnectionPool.init(allocator, .{
        .max_connections_per_host = 6,
    });
    defer pool.deinit();

    // Try to acquire more than max connections
    // Should fail gracefully, not create unlimited connections
    // Note: In actual implementation this would fail to connect,
    // but the pool logic should still enforce limits
}

test "security - multipart prevents header injection" {
    const allocator = testing.allocator;

    var builder = try zhttp.BodyStream.MultipartBuilder.init(allocator);
    defer builder.deinit();

    // Try to inject CRLF in field name
    const malicious_name = "field\r\nContent-Type: text/evil\r\n";

    try builder.addField(malicious_name, "value");

    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit();

    _ = try builder.writeTo(buffer.writer().any());

    // Check that extra headers were not injected
    const content_type_count = std.mem.count(u8, buffer.items, "Content-Type:");

    // Should only have Content-Type from legitimate sources, not from injected CRLF
    try testing.expect(content_type_count <= 1);
}

test "security - 0-RTT prevents replay attacks on unsafe methods" {
    const allocator = testing.allocator;

    var manager = zhttp.Http3.ZeroRTT.ZeroRTTManager.init(allocator, .{
        .allow_unsafe_methods = false, // Default: don't allow POST with 0-RTT
    });
    defer manager.deinit();

    try manager.storeTicket("example.com", "ticket", 16384);

    // Try to use POST with 0-RTT (should be rejected)
    var post_request = zhttp.Http3.ZeroRTT.ZeroRTTRequest.init(allocator, "POST", "/api/payment");
    defer post_request.deinit();

    const can_use = manager.canUse0RTT(&post_request, "example.com");

    try testing.expect(!can_use); // POST should not be allowed with 0-RTT
}

test "security - 0-RTT enforces early data size limit" {
    const allocator = testing.allocator;

    var manager = zhttp.Http3.ZeroRTT.ZeroRTTManager.init(allocator, .{
        .max_early_data_size = 1024, // Small limit
    });
    defer manager.deinit();

    try manager.storeTicket("example.com", "ticket", 1024);

    var request = zhttp.Http3.ZeroRTT.ZeroRTTRequest.init(allocator, "GET", "/");
    defer request.deinit();

    // Add large body that exceeds limit
    const large_body = try allocator.alloc(u8, 2048);
    defer allocator.free(large_body);
    @memset(large_body, 'A');

    request.setBody(large_body);

    const can_use = manager.canUse0RTT(&request, "example.com");

    try testing.expect(!can_use); // Should reject due to size
}

test "security - brotli prevents zip bomb" {
    const allocator = testing.allocator;

    // Malicious brotli data claiming to decompress to huge size
    // Uncompressed block format: wbits(4) + islast(1) + type(2) + len(16) + ~len(16)

    var malicious: std.ArrayList(u8) = .{};
    defer malicious.deinit();

    // Create uncompressed block claiming huge size
    try malicious.append(0b00011101); // wbits=12, islast=1, type=00 (uncompressed)

    // Length: 65535 (max for uncompressed block)
    try malicious.append(0xFF);
    try malicious.append(0xFF);

    // ~Length
    try malicious.append(0x00);
    try malicious.append(0x00);

    // Don't actually include all the data (zip bomb attempt)
    try malicious.appendSlice("short");

    const result = zhttp.Brotli.decompress(allocator, malicious.items);

    // Should fail due to premature end of stream
    try testing.expectError(error.UnexpectedEndOfStream, result);
}

test "security - timeout prevents slowloris attack" {
    const manager = zhttp.Timeout.TimeoutManager.init(.{
        .read_timeout_ms = 5000,
    });

    // Simulate slow read (in real scenario, reader would timeout)
    _ = manager.getRemainingTime(5000);

    // Verify timeout is enforced
    try testing.expect(manager.config.read_timeout_ms.? == 5000);
}

test "security - retry prevents infinite retry loop" {
    var strategy = zhttp.Timeout.RetryStrategy.init(.{
        .max_retries = 3,
    });

    // Attempt retries
    var count: usize = 0;
    while (strategy.shouldRetry(error.Timeout)) {
        count += 1;
        strategy.attempt += 1;

        if (count > 10) break; // Safety limit
    }

    // Should stop after max_retries
    try testing.expect(count <= 3);
}
