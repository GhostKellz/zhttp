const std = @import("std");
const zhttp = @import("zhttp");

/// Example demonstrating chunked transfer encoding
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Chunked Transfer Encoding Example\n", .{});
    std.debug.print("=================================\n\n", .{});

    const original_data = "This is a test of chunked transfer encoding. " **
        "The data will be split into multiple chunks for transmission. " **
        "This is useful when the content length is not known in advance.";

    std.debug.print("Original data ({} bytes):\n{s}\n\n", .{ original_data.len, original_data });

    // Encode with chunked transfer encoding
    const chunk_size = 50; // 50 bytes per chunk
    const encoded = try zhttp.Chunked.encode(allocator, original_data, chunk_size);
    defer allocator.free(encoded);

    std.debug.print("Encoded with chunk size {} ({} bytes):\n", .{ chunk_size, encoded.len });
    std.debug.print("{s}\n\n", .{encoded});

    // Decode chunked data
    const decoded = try zhttp.Chunked.decode(allocator, encoded);
    defer allocator.free(decoded);

    std.debug.print("Decoded ({} bytes):\n{s}\n\n", .{ decoded.len, decoded });

    // Verify round-trip
    if (std.mem.eql(u8, original_data, decoded)) {
        std.debug.print("✓ Round-trip successful!\n", .{});
    } else {
        std.debug.print("✗ Round-trip failed!\n", .{});
    }

    // Example with streaming
    std.debug.print("\nStreaming example:\n", .{});
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    var encoder = zhttp.Chunked.ChunkedEncoder.init(buffer.writer().any());

    // Send data in chunks
    try encoder.writeChunk("First ");
    try encoder.writeChunk("chunk, ");
    try encoder.writeChunk("second ");
    try encoder.writeChunk("chunk, ");
    try encoder.writeChunk("and final chunk!");

    // Finish with optional trailers
    const trailers = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "X-Checksum", .value = "abc123" },
        .{ .name = "X-Total-Chunks", .value = "5" },
    };
    try encoder.finish(&trailers);

    std.debug.print("Streamed output:\n{s}\n", .{buffer.items});
}
