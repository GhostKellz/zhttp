const std = @import("std");
const zhttp = @import("zhttp");
const testing = std.testing;

// Memory leak detection tests
// These tests use std.testing.allocator which tracks all allocations/deallocations

test "compression - no memory leaks on gzip" {
    const allocator = testing.allocator;

    const original = "Hello, World! This is a test of gzip compression." ** 10;

    const compressed = try zhttp.Compression.compressGzip(allocator, original);
    defer allocator.free(compressed);

    const decompressed = try zhttp.Compression.decompressGzip(allocator, compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualStrings(original, decompressed);
    // If there are leaks, testing.allocator will catch them on test completion
}

test "compression - no memory leaks on deflate" {
    const allocator = testing.allocator;

    const original = "Deflate compression test data." ** 20;

    const compressed = try zhttp.Compression.compressDeflate(allocator, original);
    defer allocator.free(compressed);

    const decompressed = try zhttp.Compression.decompressDeflate(allocator, compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualStrings(original, decompressed);
}

test "compression - no memory leaks on brotli" {
    const allocator = testing.allocator;

    const original = "Brotli compression test.";

    const compressed = try zhttp.Brotli.compress(allocator, original, .default);
    defer allocator.free(compressed);

    const decompressed = try zhttp.Brotli.decompress(allocator, compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualStrings(original, decompressed);
}

test "chunked encoding - no memory leaks" {
    const allocator = testing.allocator;

    const data = "A" ** 1000;

    const encoded = try zhttp.Chunked.encode(allocator, data, 256);
    defer allocator.free(encoded);

    const decoded = try zhttp.Chunked.decode(allocator, encoded);
    defer allocator.free(decoded);

    try testing.expectEqualStrings(data, decoded);
}

test "chunked decoder - no memory leaks on multiple chunks" {
    const allocator = testing.allocator;

    var decoder = zhttp.Chunked.ChunkedDecoder.init(allocator, undefined);
    defer decoder.deinit();

    // Decoder buffer should be cleaned up
}

test "HTTP/2 HPACK - no memory leaks on encoding" {
    const allocator = testing.allocator;

    var encoder = zhttp.Http2.HPACK.Encoder.init(allocator, 4096);
    defer encoder.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try encoder.encodeHeader(&aw.writer, ":method", "GET");
    try encoder.encodeHeader(&aw.writer, ":path", "/");
}

test "HTTP/2 HPACK - no memory leaks on decoding" {
    const allocator = testing.allocator;

    var encoder = zhttp.Http2.HPACK.Encoder.init(allocator, 4096);
    defer encoder.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try encoder.encodeHeader(&aw.writer, ":method", "GET");

    var decoder = zhttp.Http2.HPACK.Decoder.init(allocator, 4096);
    defer decoder.deinit();

    var headers = try decoder.decodeHeaderBlock(aw.writer.buffered());
    defer {
        for (headers.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        headers.deinit(allocator);
    }
}

test "HTTP/2 stream - no memory leaks" {
    const allocator = testing.allocator;

    var stream = zhttp.Http2.Stream.Stream.init(allocator, 1, 65535);
    defer stream.deinit();

    // Add some data
    const data = "test data";
    try stream.processData(data, false);
}

test "HTTP/2 connection - no memory leaks" {
    const allocator = testing.allocator;

    var conn = try zhttp.Http2.Stream.Connection.init(allocator, true);
    defer conn.deinit();

    const stream1 = try conn.createStream();
    _ = stream1;

    const stream2 = try conn.createStream();
    _ = stream2;
}

test "HTTP/3 QPACK - no memory leaks on encoding" {
    const allocator = testing.allocator;

    var encoder = zhttp.Http3.QPACK.Encoder.init(allocator, 4096, 0);
    defer encoder.deinit();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try zhttp.Http3.QPACK.encodeHeader(&aw.writer, ":method", "GET");
    try zhttp.Http3.QPACK.encodeHeader(&aw.writer, ":path", "/");
}

test "HTTP/3 QPACK - no memory leaks on decoding" {
    const allocator = testing.allocator;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try zhttp.Http3.QPACK.encodeHeader(&aw.writer, ":method", "GET");

    var decoder = zhttp.Http3.QPACK.Decoder.init(allocator, 4096, 0);
    defer decoder.deinit();

    const header = try zhttp.Http3.QPACK.decodeHeader(aw.writer.buffered());
    defer {
        allocator.free(header.name);
        allocator.free(header.value);
    }
}

test "SSE parser - no memory leaks" {
    const allocator = testing.allocator;

    var parser = zhttp.SSE.Parser.init(allocator);
    defer parser.deinit();

    _ = try parser.parseLine("event: test");
    _ = try parser.parseLine("data: hello");
    _ = try parser.parseLine("");
}

test "SSE client - no memory leaks" {
    const allocator = testing.allocator;

    var client = zhttp.SSE.Client.init(allocator);
    defer client.deinit();

    const chunk = "event: update\nid: 1\ndata: test\n\n";
    var events = try client.processChunk(chunk);
    defer events.deinit();
}

test "WebSocket frame - no memory leaks" {
    const allocator = testing.allocator;

    var frame = try zhttp.WebSocket.Frame.text(allocator, "Hello", false);
    defer frame.deinit(allocator);
}

test "WebSocket upgrade - no memory leaks" {
    const allocator = testing.allocator;

    const key = try zhttp.WebSocket.Upgrade.generateKey(allocator);
    defer allocator.free(key);

    const accept = try zhttp.WebSocket.Upgrade.generateAcceptKey(allocator, key);
    defer allocator.free(accept);

    var headers = try zhttp.WebSocket.Upgrade.createUpgradeHeaders(allocator, "example.com", "/ws", key);
    defer headers.deinit();
}

test "redirect tracker - no memory leaks" {
    const allocator = testing.allocator;

    var tracker = zhttp.Redirect.RedirectTracker.init(allocator, .{});
    defer tracker.deinit();

    try tracker.visit("https://example.com/1");
    try tracker.visit("https://example.com/2");
    try tracker.visit("https://example.com/3");
}

test "multipart builder - no memory leaks" {
    const allocator = testing.allocator;

    var builder = try zhttp.BodyStream.MultipartBuilder.init(allocator);
    defer builder.deinit();

    try builder.addField("name", "John");
    try builder.addField("email", "john@example.com");
}

test "0-RTT manager - no memory leaks" {
    const allocator = testing.allocator;

    var manager = zhttp.Http3.ZeroRTT.ZeroRTTManager.init(allocator, .{});
    defer manager.deinit();

    try manager.storeTicket("example.com", "ticket123", 16384);

    const ticket = manager.getTicket("example.com");
    try testing.expect(ticket != null);
}

test "0-RTT request - no memory leaks" {
    const allocator = testing.allocator;

    var request = zhttp.Http3.ZeroRTT.ZeroRTTRequest.init(allocator, "GET", "/");
    defer request.deinit();

    try request.addHeader("accept", "application/json");
}

test "connection pool - no memory leaks on create/destroy" {
    const allocator = testing.allocator;

    var pool = zhttp.ConnectionPool.init(allocator, .{});
    defer pool.deinit();

    // Pool should clean up all connections
}

test "brotli decompressor - no memory leaks" {
    const allocator = testing.allocator;

    var decompressor = try zhttp.Brotli.Decompressor.init(allocator, .@"4KB");
    defer decompressor.deinit();
}

// Stress test - allocate/deallocate many times
test "stress - chunked encoding cycles" {
    const allocator = testing.allocator;

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const data = "test data";
        const encoded = try zhttp.Chunked.encode(allocator, data, 3);
        defer allocator.free(encoded);

        const decoded = try zhttp.Chunked.decode(allocator, encoded);
        defer allocator.free(decoded);
    }
}

// Stress test - HPACK encoding cycles
test "stress - HPACK encoding cycles" {
    const allocator = testing.allocator;

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var encoder = zhttp.Http2.HPACK.Encoder.init(allocator, 4096);
        defer encoder.deinit();

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        try encoder.encodeHeader(&aw.writer, ":method", "GET");
        try encoder.encodeHeader(&aw.writer, ":path", "/api/test");
    }
}
