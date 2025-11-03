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
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    // Create a fixed reader from compressed data
    var reader = std.Io.Reader.fixed(compressed);

    // Decompress using flate with gzip container
    var window_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&reader, .gzip, &window_buffer);

    // Read decompressed data
    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try decompressor.reader.readSliceShort(&buffer);
        if (bytes_read == 0) break;
        try result.appendSlice(allocator, buffer[0..bytes_read]);
    }

    return result.toOwnedSlice(allocator);
}

/// Compress data using gzip
pub fn compressGzip(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // Create a compressor that writes to our Allocating writer
    var compress_buffer: [4096]u8 = undefined;
    var compressor = std.compress.flate.Compress.init(&aw.writer, &compress_buffer, .{
        .container = .gzip,
    });

    // Write all data
    try compressor.writer.writeAll(data);
    try compressor.end();

    return try aw.toOwnedSlice();
}

/// Decompress data using deflate
pub fn decompressDeflate(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    // Create a fixed reader from compressed data
    var reader = std.Io.Reader.fixed(compressed);

    // Decompress using flate with zlib container
    var window_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&reader, .zlib, &window_buffer);

    // Read decompressed data
    var buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try decompressor.reader.readSliceShort(&buffer);
        if (bytes_read == 0) break;
        try result.appendSlice(allocator, buffer[0..bytes_read]);
    }

    return result.toOwnedSlice(allocator);
}

/// Compress data using deflate
pub fn compressDeflate(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    // Create a compressor that writes to our Allocating writer
    var compress_buffer: [4096]u8 = undefined;
    var compressor = std.compress.flate.Compress.init(&aw.writer, &compress_buffer, .{
        .container = .zlib,
    });

    // Write all data
    try compressor.writer.writeAll(data);
    try compressor.end();

    return try aw.toOwnedSlice();
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
