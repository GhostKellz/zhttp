const std = @import("std");
const brotli = @import("brotli.zig");

/// Compression algorithms supported by zhttp
pub const CompressionAlgorithm = enum {
    none,
    gzip,
    deflate,
    brotli,

    pub fn fromContentEncoding(encoding: []const u8) CompressionAlgorithm {
        if (std.mem.eql(u8, encoding, "gzip")) return .gzip;
        if (std.mem.eql(u8, encoding, "deflate")) return .deflate;
        if (std.mem.eql(u8, encoding, "br")) return .brotli;
        return .none;
    }

    pub fn toContentEncoding(self: CompressionAlgorithm) []const u8 {
        return switch (self) {
            .none => "",
            .gzip => "gzip",
            .deflate => "deflate",
            .brotli => "br",
        };
    }
};

/// Decompress data using gzip/deflate
pub fn decompressGzip(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    // Create a fixed buffer stream from compressed data
    var fbs = std.io.fixedBufferStream(compressed);

    // Decompress using zlib (which handles both gzip and deflate)
    var decompressor = try std.compress.gzip.decompressor(fbs.reader());

    // Read decompressed data
    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try decompressor.read(&buffer);
        if (bytes_read == 0) break;
        try result.appendSlice(buffer[0..bytes_read]);
    }

    return result.toOwnedSlice();
}

/// Compress data using gzip
pub fn compressGzip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    // Create a compressor that writes to our ArrayList
    var compressor = try std.compress.gzip.compressor(result.writer(), .{});

    // Write all data
    try compressor.write(data);
    try compressor.finish();

    return result.toOwnedSlice();
}

/// Decompress data using deflate
pub fn decompressDeflate(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    // Create a fixed buffer stream from compressed data
    var fbs = std.io.fixedBufferStream(compressed);

    // Decompress using deflate
    var decompressor = try std.compress.zlib.decompressor(fbs.reader());

    // Read decompressed data
    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try decompressor.read(&buffer);
        if (bytes_read == 0) break;
        try result.appendSlice(buffer[0..bytes_read]);
    }

    return result.toOwnedSlice();
}

/// Compress data using deflate
pub fn compressDeflate(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    // Create a compressor that writes to our ArrayList
    var compressor = try std.compress.zlib.compressor(result.writer(), .{});

    // Write all data
    try compressor.write(data);
    try compressor.finish();

    return result.toOwnedSlice();
}

/// Decompress data using brotli (homebrew implementation)
pub fn decompressBrotli(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    return try brotli.decompress(allocator, compressed);
}

/// Compress data using brotli (homebrew implementation - uncompressed blocks only)
pub fn compressBrotli(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    return try brotli.compress(allocator, data, .default);
}

/// Decompress data based on the compression algorithm
pub fn decompress(allocator: std.mem.Allocator, algorithm: CompressionAlgorithm, compressed: []const u8) ![]u8 {
    return switch (algorithm) {
        .none => try allocator.dupe(u8, compressed),
        .gzip => try decompressGzip(allocator, compressed),
        .deflate => try decompressDeflate(allocator, compressed),
        .brotli => try decompressBrotli(allocator, compressed),
    };
}

/// Compress data based on the compression algorithm
pub fn compress(allocator: std.mem.Allocator, algorithm: CompressionAlgorithm, data: []const u8) ![]u8 {
    return switch (algorithm) {
        .none => try allocator.dupe(u8, data),
        .gzip => try compressGzip(allocator, data),
        .deflate => try compressDeflate(allocator, data),
        .brotli => try compressBrotli(allocator, data),
    };
}

test "gzip compression/decompression" {
    const allocator = std.testing.allocator;
    const original = "Hello, World! This is a test of gzip compression.";

    const compressed = try compressGzip(allocator, original);
    defer allocator.free(compressed);

    const decompressed = try decompressGzip(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}

test "deflate compression/decompression" {
    const allocator = std.testing.allocator;
    const original = "Hello, World! This is a test of deflate compression.";

    const compressed = try compressDeflate(allocator, original);
    defer allocator.free(compressed);

    const decompressed = try decompressDeflate(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}

test "compression algorithm from content-encoding" {
    try std.testing.expect(CompressionAlgorithm.fromContentEncoding("gzip") == .gzip);
    try std.testing.expect(CompressionAlgorithm.fromContentEncoding("deflate") == .deflate);
    try std.testing.expect(CompressionAlgorithm.fromContentEncoding("br") == .brotli);
    try std.testing.expect(CompressionAlgorithm.fromContentEncoding("unknown") == .none);
}
