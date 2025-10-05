const std = @import("std");
const zhttp = @import("zhttp");

/// Performance benchmarks for zhttp components
/// Run with: zig build bench

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== zhttp Performance Benchmarks ===\n\n", .{});

    try benchmarkCompression(allocator);
    try benchmarkChunked(allocator);
    try benchmarkHPACK(allocator);
    try benchmarkQPACK(allocator);
    try benchmarkWebSocket(allocator);
    try benchmarkSSE(allocator);
    try benchmarkRedirect(allocator);
}

fn benchmarkCompression(allocator: std.mem.Allocator) !void {
    std.debug.print("Compression Benchmarks\n", .{});
    std.debug.print("----------------------\n", .{});

    const data = "The quick brown fox jumps over the lazy dog. " ** 100;
    const sizes = [_]usize{ 100, 1024, 10 * 1024, 100 * 1024 };

    for (sizes) |size| {
        const test_data = data[0..@min(size, data.len)];

        // Gzip
        {
            var timer = try std.time.Timer.start();
            const compressed = try zhttp.Compression.compressGzip(allocator, test_data);
            const compress_time = timer.read();

            timer.reset();
            const decompressed = try zhttp.Compression.decompressGzip(allocator, compressed);
            const decompress_time = timer.read();

            allocator.free(compressed);
            allocator.free(decompressed);

            const ratio = @as(f64, @floatFromInt(compressed.len)) / @as(f64, @floatFromInt(test_data.len)) * 100.0;

            std.debug.print("  Gzip ({} bytes):\n", .{size});
            std.debug.print("    Compress:   {d:.2}ms ({d:.1}%)\n", .{
                @as(f64, @floatFromInt(compress_time)) / std.time.ns_per_ms,
                ratio,
            });
            std.debug.print("    Decompress: {d:.2}ms\n", .{
                @as(f64, @floatFromInt(decompress_time)) / std.time.ns_per_ms,
            });
        }

        // Brotli
        {
            var timer = try std.time.Timer.start();
            const compressed = try zhttp.Brotli.compress(allocator, test_data, .default);
            const compress_time = timer.read();

            timer.reset();
            const decompressed = try zhttp.Brotli.decompress(allocator, compressed);
            const decompress_time = timer.read();

            allocator.free(compressed);
            allocator.free(decompressed);

            std.debug.print("    Brotli:     {d:.2}ms / {d:.2}ms\n\n", .{
                @as(f64, @floatFromInt(compress_time)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(decompress_time)) / std.time.ns_per_ms,
            });
        }
    }
}

fn benchmarkChunked(allocator: std.mem.Allocator) !void {
    std.debug.print("Chunked Transfer Encoding\n", .{});
    std.debug.print("-------------------------\n", .{});

    const sizes = [_]usize{ 1024, 10 * 1024, 100 * 1024 };
    const chunk_sizes = [_]usize{ 256, 1024, 8192 };

    for (sizes) |size| {
        const data = try allocator.alloc(u8, size);
        defer allocator.free(data);
        @memset(data, 'A');

        for (chunk_sizes) |chunk_size| {
            var timer = try std.time.Timer.start();
            const encoded = try zhttp.Chunked.encode(allocator, data, chunk_size);
            const encode_time = timer.read();

            timer.reset();
            const decoded = try zhttp.Chunked.decode(allocator, encoded);
            const decode_time = timer.read();

            allocator.free(encoded);
            allocator.free(decoded);

            std.debug.print("  {} bytes, {} chunk: {d:.2}ms / {d:.2}ms\n", .{
                size,
                chunk_size,
                @as(f64, @floatFromInt(encode_time)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(decode_time)) / std.time.ns_per_ms,
            });
        }
    }
    std.debug.print("\n", .{});
}

fn benchmarkHPACK(allocator: std.mem.Allocator) !void {
    std.debug.print("HTTP/2 HPACK Compression\n", .{});
    std.debug.print("------------------------\n", .{});

    const header_counts = [_]usize{ 5, 10, 20, 50 };

    for (header_counts) |count| {
        var encoder = zhttp.Http2.HPACK.Encoder.init(allocator, 4096);
        defer encoder.deinit();

        var decoder = zhttp.Http2.HPACK.Decoder.init(allocator, 4096);
        defer decoder.deinit();

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        var timer = try std.time.Timer.start();

        var i: usize = 0;
        while (i < count) : (i += 1) {
            try encoder.encodeHeader(buffer.writer(), ":method", "GET");
        }

        const encode_time = timer.read();

        timer.reset();
        var headers = try decoder.decodeHeaderBlock(buffer.items);
        const decode_time = timer.read();

        for (headers.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        headers.deinit();

        std.debug.print("  {} headers: {d:.2}ms / {d:.2}ms\n", .{
            count,
            @as(f64, @floatFromInt(encode_time)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(decode_time)) / std.time.ns_per_ms,
        });
    }
    std.debug.print("\n", .{});
}

fn benchmarkQPACK(allocator: std.mem.Allocator) !void {
    std.debug.print("HTTP/3 QPACK Compression\n", .{});
    std.debug.print("------------------------\n", .{});

    const header_counts = [_]usize{ 5, 10, 20, 50 };

    for (header_counts) |count| {
        var encoder = zhttp.Http3.QPACK.Encoder.init(allocator, 4096);
        defer encoder.deinit();

        var decoder = zhttp.Http3.QPACK.Decoder.init(allocator, 4096);
        defer decoder.deinit();

        var headers_array = std.ArrayList(struct { name: []const u8, value: []const u8 }).init(allocator);
        defer headers_array.deinit();

        var i: usize = 0;
        while (i < count) : (i += 1) {
            try headers_array.append(.{ .name = ":method", .value = "GET" });
        }

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        var timer = try std.time.Timer.start();
        try encoder.encodeHeaders(buffer.writer().any(), headers_array.items);
        const encode_time = timer.read();

        timer.reset();
        var decoded = try decoder.decodeHeaderBlock(buffer.items);
        const decode_time = timer.read();

        for (decoded.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        decoded.deinit();

        std.debug.print("  {} headers: {d:.2}ms / {d:.2}ms\n", .{
            count,
            @as(f64, @floatFromInt(encode_time)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(decode_time)) / std.time.ns_per_ms,
        });
    }
    std.debug.print("\n", .{});
}

fn benchmarkWebSocket(allocator: std.mem.Allocator) !void {
    std.debug.print("WebSocket Frame Processing\n", .{});
    std.debug.print("---------------------------\n", .{});

    const sizes = [_]usize{ 125, 1024, 10 * 1024, 64 * 1024 };

    for (sizes) |size| {
        const data = try allocator.alloc(u8, size);
        defer allocator.free(data);
        @memset(data, 'A');

        var timer = try std.time.Timer.start();
        var frame = try zhttp.WebSocket.Frame.binary(allocator, data, true);
        const create_time = timer.read();

        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        timer.reset();
        try frame.write(buffer.writer().any());
        const write_time = timer.read();

        frame.deinit(allocator);

        var fbs = std.io.fixedBufferStream(buffer.items);

        timer.reset();
        var read_frame = try zhttp.WebSocket.Frame.read(allocator, fbs.reader().any());
        const read_time = timer.read();

        read_frame.deinit(allocator);

        std.debug.print("  {} bytes: create={d:.2}ms write={d:.2}ms read={d:.2}ms\n", .{
            size,
            @as(f64, @floatFromInt(create_time)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(write_time)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(read_time)) / std.time.ns_per_ms,
        });
    }
    std.debug.print("\n", .{});
}

fn benchmarkSSE(allocator: std.mem.Allocator) !void {
    std.debug.print("Server-Sent Events Parsing\n", .{});
    std.debug.print("--------------------------\n", .{});

    const event_counts = [_]usize{ 10, 100, 1000 };

    for (event_counts) |count| {
        var stream = std.ArrayList(u8).init(allocator);
        defer stream.deinit();

        // Generate SSE stream
        var i: usize = 0;
        while (i < count) : (i += 1) {
            try stream.writer().print("event: update\n", .{});
            try stream.writer().print("id: {}\n", .{i});
            try stream.writer().print("data: Message {}\n", .{i});
            try stream.writer().print("\n", .{});
        }

        var client = zhttp.SSE.Client.init(allocator);
        defer client.deinit();

        var timer = try std.time.Timer.start();
        var events = try client.processChunk(stream.items);
        const parse_time = timer.read();

        events.deinit();

        std.debug.print("  {} events: {d:.2}ms ({d:.0} events/sec)\n", .{
            count,
            @as(f64, @floatFromInt(parse_time)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(parse_time)) / std.time.ns_per_s),
        });
    }
    std.debug.print("\n", .{});
}

fn benchmarkRedirect(allocator: std.mem.Allocator) !void {
    std.debug.print("Redirect Tracking\n", .{});
    std.debug.print("-----------------\n", .{});

    const redirect_counts = [_]usize{ 5, 10, 20, 50 };

    for (redirect_counts) |count| {
        var tracker = zhttp.Redirect.RedirectTracker.init(allocator, .{});
        defer tracker.deinit();

        var timer = try std.time.Timer.start();

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const url = try std.fmt.allocPrint(allocator, "https://example.com/{}", .{i});
            defer allocator.free(url);

            try tracker.visit(url);
        }

        const track_time = timer.read();

        std.debug.print("  {} redirects: {d:.2}ms\n", .{
            count,
            @as(f64, @floatFromInt(track_time)) / std.time.ns_per_ms,
        });
    }
    std.debug.print("\n", .{});
}
