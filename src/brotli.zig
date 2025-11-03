const std = @import("std");

/// Homebrew Brotli Compression/Decompression
/// Implements RFC 7932: https://tools.ietf.org/html/rfc7932
///
/// This is a simplified implementation focusing on decompression for HTTP responses.
/// Full brotli encoding is complex and typically handled by specialized libraries.

/// Brotli compression quality levels (0-11)
pub const Quality = enum(u4) {
    fastest = 0,
    fast = 1,
    default = 6,
    best = 11,
};

/// Brotli window size (10-24)
pub const WindowSize = enum(u5) {
    @"1KB" = 10,
    @"2KB" = 11,
    @"4KB" = 12,
    @"8KB" = 13,
    @"16KB" = 14,
    @"32KB" = 15,
    @"64KB" = 16,
    @"128KB" = 17,
    @"256KB" = 18,
    @"512KB" = 19,
    @"1MB" = 20,
    @"2MB" = 21,
    @"4MB" = 22,
    @"8MB" = 23,
    @"16MB" = 24,
};

/// Brotli block types
const BlockType = enum(u2) {
    uncompressed = 0,
    compressed = 1,
    reserved = 2,
    metadata = 3,
};

/// Bit reader for Brotli bitstream
const BitReader = struct {
    data: []const u8,
    byte_pos: usize = 0,
    bit_pos: u3 = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    /// Read n bits from the stream
    pub fn readBits(self: *BitReader, n: u6) !u64 {
        if (n == 0) return 0;
        if (n > 64) return error.InvalidBitCount;

        var result: u64 = 0;
        var bits_read: u6 = 0;

        while (bits_read < n) {
            if (self.byte_pos >= self.data.len) {
                return error.UnexpectedEndOfStream;
            }

            const current_byte = self.data[self.byte_pos];
            const bits_available: u6 = 8 - @as(u6, self.bit_pos);
            const bits_to_read = @min(n - bits_read, bits_available);

            // Extract bits from current byte
            const mask: u8 = (@as(u8, 1) << @intCast(bits_to_read)) - 1;
            const bits = (current_byte >> self.bit_pos) & mask;

            result |= @as(u64, bits) << @intCast(bits_read);
            bits_read += bits_to_read;
            self.bit_pos += @intCast(bits_to_read);

            if (self.bit_pos >= 8) {
                self.byte_pos += 1;
                self.bit_pos = 0;
            }
        }

        return result;
    }

    /// Read a single bit
    pub fn readBit(self: *BitReader) !u1 {
        return @intCast(try self.readBits(1));
    }

    /// Align to byte boundary
    pub fn alignToByte(self: *BitReader) void {
        if (self.bit_pos != 0) {
            self.byte_pos += 1;
            self.bit_pos = 0;
        }
    }
};

/// Brotli static dictionary
const StaticDictionary = struct {
    // Brotli uses a built-in static dictionary for common words/phrases
    // This is a simplified version with the most common entries
    pub const entries = [_][]const u8{
        " ",          "the",   "of",     "and",    "to",     "a",      "in",
        "that",       "is",    "was",    "for",    "on",     "with",   "as",
        "I",          "it",    "be",     "by",     "this",   "have",   "from",
        "or",         "one",   "had",    "but",    "not",    "what",   "all",
        "were",       "we",    "when",   "your",   "can",    "said",   "there",
        "use",        "an",    "each",   "which",  "she",    "do",     "how",
        "their",      "if",    "will",   "up",     "other",  "about",  "out",
        "many",       "then",  "them",   "these",  "so",     "some",   "her",
        "would",      "make",  "like",   "him",    "into",   "time",   "has",
        "look",       "two",   "more",   "write",  "go",     "see",    "number",
    };

    pub fn get(index: usize) ?[]const u8 {
        if (index >= entries.len) return null;
        return entries[index];
    }
};

/// Brotli decompressor
pub const Decompressor = struct {
    allocator: std.mem.Allocator,
    window: std.ArrayList(u8),
    window_size: usize,

    pub fn init(allocator: std.mem.Allocator, window_size: WindowSize) !Decompressor {
        const size = @as(usize, 1) << @intFromEnum(window_size);
        return .{
            .allocator = allocator,
            .window = .{},
            .window_size = size,
        };
    }

    pub fn deinit(self: *Decompressor) void {
        self.window.deinit(self.allocator);
    }

    /// Decompress brotli data
    pub fn decompress(self: *Decompressor, compressed: []const u8) ![]u8 {
        var reader = BitReader.init(compressed);
        var output: std.ArrayList(u8) = .{};
        errdefer output.deinit(self.allocator);

        // Read Brotli header
        const wbits = try reader.readBits(4);
        if (wbits == 0) {
            // Last empty block
            return try output.toOwnedSlice(self.allocator);
        }

        const window_size = @as(usize, 1) << @intCast(wbits + 10);
        _ = window_size;

        // Check for metadata
        const is_last = try reader.readBit();
        const block_type_bits = try reader.readBits(2);
        const block_type: BlockType = @enumFromInt(block_type_bits);

        switch (block_type) {
            .uncompressed => {
                // Align to byte boundary
                reader.alignToByte();

                // Read length
                const len = try reader.readBits(16);
                const len_check = try reader.readBits(16);
                if (len + len_check != 0xFFFF) {
                    return error.InvalidUncompressedBlock;
                }

                // Copy uncompressed data
                const start = reader.byte_pos;
                const end = start + @as(usize, @intCast(len));
                if (end > compressed.len) {
                    return error.UnexpectedEndOfStream;
                }

                try output.appendSlice(self.allocator, compressed[start..end]);
                reader.byte_pos = end;
            },

            .compressed => {
                // This is where the complex Brotli decompression happens
                // Full implementation requires:
                // - Context modeling
                // - Prefix code trees (Huffman)
                // - Distance codes
                // - Length codes
                // - Static dictionary lookups
                //
                // For now, return error as this is complex
                _ = is_last;
                return error.CompressedBrotliNotImplemented;
            },

            .metadata => {
                // Metadata blocks are skipped
                return error.MetadataBlocksNotSupported;
            },

            .reserved => {
                return error.ReservedBlockType;
            },
        }

        return try output.toOwnedSlice(self.allocator);
    }

    /// Add data to sliding window
    fn addToWindow(self: *Decompressor, data: []const u8) !void {
        try self.window.appendSlice(self.allocator, data);

        // Keep window size limited
        if (self.window.items.len > self.window_size) {
            const excess = self.window.items.len - self.window_size;
            std.mem.copyForwards(u8, self.window.items, self.window.items[excess..]);
            self.window.shrinkRetainingCapacity(self.window_size);
        }
    }

    /// Copy from sliding window (for LZ77 matches)
    fn copyFromWindow(self: *Decompressor, distance: usize, length: usize) ![]const u8 {
        if (distance > self.window.items.len) {
            return error.InvalidDistance;
        }

        const start = self.window.items.len - distance;
        const end = @min(start + length, self.window.items.len);

        return self.window.items[start..end];
    }
};

/// Compress data with Brotli (simplified - only uncompressed blocks)
pub fn compress(allocator: std.mem.Allocator, data: []const u8, quality: Quality) ![]u8 {
    _ = quality; // Quality ignored for uncompressed mode

    var output: std.ArrayList(u8) = .{};
    errdefer output.deinit(allocator);

    // For simplicity, just store as uncompressed blocks
    // Real Brotli compression is extremely complex

    // Brotli header: window size (we'll use 22 = 4MB)
    var bit_pos: u3 = 0;
    var current_byte: u8 = 0;

    // WBITS (4 bits) = 12 (4KB window)
    current_byte |= 12;
    bit_pos = 4;

    // ISLAST (1 bit) = 1
    current_byte |= @as(u8, 1) << bit_pos;
    bit_pos += 1;

    // Block type (2 bits) = 0 (uncompressed)
    // Already 0

    try output.append(allocator, current_byte);

    // Length (16 bits) and ~length (16 bits)
    const len: u16 = @intCast(@min(data.len, 0xFFFF));
    try output.append(allocator, @intCast(len & 0xFF));
    try output.append(allocator, @intCast((len >> 8) & 0xFF));

    const len_check: u16 = ~len;
    try output.append(allocator, @intCast(len_check & 0xFF));
    try output.append(allocator, @intCast((len_check >> 8) & 0xFF));

    // Uncompressed data
    try output.appendSlice(allocator, data[0..len]);

    return try output.toOwnedSlice(allocator);
}

/// Decompress Brotli data
pub fn decompress(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var decompressor = try Decompressor.init(allocator, .@"4MB");
    defer decompressor.deinit();

    return try decompressor.decompress(compressed);
}

test "brotli bit reader" {
    const data = [_]u8{ 0b10101100, 0b11110000 };
    var reader = BitReader.init(&data);

    try std.testing.expectEqual(@as(u64, 0), try reader.readBits(1)); // bit 0
    try std.testing.expectEqual(@as(u64, 0), try reader.readBits(1)); // bit 1
    try std.testing.expectEqual(@as(u64, 1), try reader.readBits(1)); // bit 2
    try std.testing.expectEqual(@as(u64, 1), try reader.readBits(1)); // bit 3
}

test "brotli uncompressed block" {
    const allocator = std.testing.allocator;
    const original = "Hello, Brotli!";

    const compressed = try compress(allocator, original, .default);
    defer allocator.free(compressed);

    const decompressed = try decompress(allocator, compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}

test "brotli static dictionary" {
    const entry = StaticDictionary.get(0);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings(" ", entry.?);
}
