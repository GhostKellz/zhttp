const std = @import("std");
const zhttp = @import("zhttp");
const testing = std.testing;

// Fuzz testing for all parsers
// These tests throw random/malformed data at parsers to find crashes and edge cases

// Generate random bytes
fn generateRandomBytes(allocator: std.mem.Allocator, prng: *std.Random.DefaultPrng, max_size: usize) ![]u8 {
    const size = prng.random().intRangeAtMost(usize, 1, max_size);
    const data = try allocator.alloc(u8, size);
    prng.random().bytes(data);
    return data;
}

test "fuzz - chunked decoder with random input" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(12345);

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const random_data = try generateRandomBytes(allocator, &prng, 1024);
        defer allocator.free(random_data);

        // Should not crash, even on invalid input
        _ = zhttp.Chunked.decode(allocator, random_data) catch |err| {
            // Expected errors are fine
            switch (err) {
                error.UnexpectedEndOfChunk,
                error.InvalidChunkEncoding,
                error.LineTooLong,
                error.InvalidCharacter,
                error.Overflow,
                error.OutOfMemory,
                => {},
                else => return err,
            }
        };
    }
}

test "fuzz - HPACK decoder with random input" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(67890);

    var decoder = zhttp.Http2.HPACK.Decoder.init(allocator, 4096);
    defer decoder.deinit();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const random_data = try generateRandomBytes(allocator, &prng, 512);
        defer allocator.free(random_data);

        if (decoder.decodeHeaderBlock(random_data)) |headers| {
            // Clean up if decode succeeded
            for (headers.items) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            headers.deinit();
        } else |err| {
            // Expected errors
            switch (err) {
                error.InvalidIndex,
                error.InvalidLength,
                error.OutOfMemory,
                error.EndOfStream,
                => {},
                else => return err,
            }
        }
    }
}

test "fuzz - QPACK decoder with random input" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(11111);

    var decoder = zhttp.Http3.QPACK.Decoder.init(allocator, 4096);
    defer decoder.deinit();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const random_data = try generateRandomBytes(allocator, &prng, 512);
        defer allocator.free(random_data);

        if (decoder.decodeHeaderBlock(random_data)) |headers| {
            for (headers.items) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            headers.deinit();
        } else |err| {
            switch (err) {
                error.InvalidIndex,
                error.InvalidLength,
                error.OutOfMemory,
                error.EndOfStream,
                => {},
                else => return err,
            }
        }
    }
}

test "fuzz - WebSocket frame decoder with random input" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(22222);

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const random_data = try generateRandomBytes(allocator, &prng, 256);
        defer allocator.free(random_data);

        var fbs = std.io.fixedBufferStream(random_data);

        if (zhttp.WebSocket.Frame.read(allocator, fbs.reader().any())) |frame| {
            var f = frame;
            f.deinit(allocator);
        } else |err| {
            switch (err) {
                error.UnexpectedEndOfStream,
                error.EndOfStream,
                error.OutOfMemory,
                => {},
                else => return err,
            }
        }
    }
}

test "fuzz - SSE parser with random input" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(33333);

    var parser = zhttp.SSE.Parser.init(allocator);
    defer parser.deinit();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const random_data = try generateRandomBytes(allocator, &prng, 512);
        defer allocator.free(random_data);

        if (parser.parseChunk(random_data)) |events| {
            events.deinit();
        } else |err| {
            switch (err) {
                error.OutOfMemory,
                error.InvalidCharacter,
                error.Overflow,
                => {},
                else => return err,
            }
        }
    }
}

test "fuzz - brotli decoder with random input" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(44444);

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const random_data = try generateRandomBytes(allocator, &prng, 256);
        defer allocator.free(random_data);

        if (zhttp.Brotli.decompress(allocator, random_data)) |result| {
            allocator.free(result);
        } else |err| {
            switch (err) {
                error.UnexpectedEndOfStream,
                error.InvalidUncompressedBlock,
                error.CompressedBrotliNotImplemented,
                error.MetadataBlocksNotSupported,
                error.ReservedBlockType,
                error.InvalidBitCount,
                error.OutOfMemory,
                => {},
                else => return err,
            }
        }
    }
}

test "fuzz - HTTP/3 VarInt decoder with random input" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(55555);

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const random_data = try generateRandomBytes(allocator, &prng, 16);
        defer allocator.free(random_data);

        var fbs = std.io.fixedBufferStream(random_data);

        _ = zhttp.Http3.Frame.VarInt.decode(fbs.reader().any()) catch |err| {
            switch (err) {
                error.EndOfStream,
                error.OutOfMemory,
                => {},
                else => return err,
            }
        };
    }
}

test "fuzz - redirect URL parsing with malformed URLs" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(66666);

    const malformed_urls = [_][]const u8{
        "",
        "/",
        "//",
        "///",
        "http:",
        "http:/",
        "http://",
        "://example.com",
        "ht!@#$%^&*()",
        "http://[invalid",
        "http://example.com:99999",
        "http://example.com:-1",
        "\x00\x01\x02",
        "a" ** 10000,
    };

    for (malformed_urls) |url| {
        _ = zhttp.Redirect.parseLocationHeader(url, "https://example.com") catch |err| {
            switch (err) {
                error.InvalidBaseUrl,
                error.OutOfMemory,
                => {},
                else => return err,
            }
        };
    }

    // Random URLs
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const random_data = try generateRandomBytes(allocator, &prng, 128);
        defer allocator.free(random_data);

        _ = zhttp.Redirect.parseLocationHeader(random_data, "https://example.com") catch |err| {
            switch (err) {
                error.InvalidBaseUrl,
                error.OutOfMemory,
                => {},
                else => return err,
            }
        };
    }
}

// Fuzz with structured but malformed data
test "fuzz - chunked with malformed chunk sizes" {
    const allocator = testing.allocator;

    const malformed_chunks = [_][]const u8{
        "FFFFFFFFFFFFFFFF\r\ndata\r\n0\r\n\r\n", // Huge chunk size
        "-1\r\ndata\r\n0\r\n\r\n", // Negative
        "ZZZ\r\ndata\r\n0\r\n\r\n", // Invalid hex
        "5\r\nAB\r\n0\r\n\r\n", // Size mismatch
        "5\r\nHello", // Missing terminator
        "0\r\n", // Incomplete
    };

    for (malformed_chunks) |chunk| {
        _ = zhttp.Chunked.decode(allocator, chunk) catch |err| {
            switch (err) {
                error.UnexpectedEndOfChunk,
                error.InvalidChunkEncoding,
                error.LineTooLong,
                error.InvalidCharacter,
                error.Overflow,
                => {},
                else => return err,
            }
        };
    }
}

// Fuzz WebSocket with malformed frames
test "fuzz - WebSocket with malformed frames" {
    const allocator = testing.allocator;

    const malformed_frames = [_][]const u8{
        &[_]u8{0xFF}, // Invalid opcode
        &[_]u8{ 0x81, 0xFF }, // Reserved bits set
        &[_]u8{ 0x81, 0x00 }, // Zero payload with mask bit
        &[_]u8{ 0x81, 0x7E }, // Extended length incomplete
        &[_]u8{ 0x81, 0x7F }, // 64-bit length incomplete
        &[_]u8{ 0x88, 0x01, 0x00 }, // Close frame with 1 byte (needs 2 for code)
    };

    for (malformed_frames) |data| {
        var fbs = std.io.fixedBufferStream(data);

        _ = zhttp.WebSocket.Frame.read(allocator, fbs.reader().any()) catch |err| {
            switch (err) {
                error.EndOfStream,
                error.UnexpectedEndOfStream,
                error.OutOfMemory,
                => {},
                else => return err,
            }
        };
    }
}

// Edge case: Empty inputs
test "fuzz - empty inputs" {
    const allocator = testing.allocator;
    const empty: []const u8 = &[_]u8{};

    // Chunked
    _ = zhttp.Chunked.decode(allocator, empty) catch {};

    // HPACK
    var hpack_decoder = zhttp.Http2.HPACK.Decoder.init(allocator, 4096);
    defer hpack_decoder.deinit();
    _ = hpack_decoder.decodeHeaderBlock(empty) catch {};

    // QPACK
    var qpack_decoder = zhttp.Http3.QPACK.Decoder.init(allocator, 4096);
    defer qpack_decoder.deinit();
    _ = qpack_decoder.decodeHeaderBlock(empty) catch {};

    // SSE
    var sse_parser = zhttp.SSE.Parser.init(allocator);
    defer sse_parser.deinit();
    if (sse_parser.parseChunk(empty)) |events| {
        events.deinit();
    } else |_| {}

    // Brotli
    _ = zhttp.Brotli.decompress(allocator, empty) catch {};
}

// Edge case: Very large inputs
test "fuzz - very large inputs" {
    const allocator = testing.allocator;

    // Large chunked data
    const large_data = try allocator.alloc(u8, 1024 * 1024); // 1MB
    defer allocator.free(large_data);
    @memset(large_data, 'A');

    const encoded = try zhttp.Chunked.encode(allocator, large_data, 8192);
    defer allocator.free(encoded);

    const decoded = try zhttp.Chunked.decode(allocator, encoded);
    defer allocator.free(decoded);

    try testing.expectEqualSlices(u8, large_data, decoded);
}

// Boundary conditions
test "fuzz - boundary conditions for integers" {
    const allocator = testing.allocator;

    // VarInt edge cases
    var buffer: std.ArrayList(u8) = .{};
    defer buffer.deinit(allocator);

    const boundary_values = [_]u64{
        0,
        63, // Max 1-byte
        64, // Min 2-byte
        16383, // Max 2-byte
        16384, // Min 4-byte
        1073741823, // Max 4-byte
        1073741824, // Min 8-byte
        std.math.maxInt(u62), // Max valid
    };

    for (boundary_values) |value| {
        buffer.clearRetainingCapacity();
        try zhttp.Http3.Frame.VarInt.encode(buffer.writer().any(), value);

        var fbs = std.io.fixedBufferStream(buffer.items);
        const decoded = try zhttp.Http3.Frame.VarInt.decode(fbs.reader().any());

        try testing.expectEqual(value, decoded);
    }
}
