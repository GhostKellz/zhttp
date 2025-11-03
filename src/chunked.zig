const std = @import("std");

/// Chunked Transfer Encoding (RFC 7230 Section 4.1)
/// Used for HTTP/1.1 when content length is not known in advance

/// Chunked encoder for writing data in chunks
pub const ChunkedEncoder = struct {
    writer: *std.Io.Writer,

    pub fn init(writer: *std.Io.Writer) ChunkedEncoder {
        return .{ .writer = writer };
    }

    /// Write a chunk of data
    pub fn writeChunk(self: *ChunkedEncoder, data: []const u8) !void {
        if (data.len == 0) return;

        // Write chunk size in hex followed by CRLF
        try self.writer.print("{x}\r\n", .{data.len});

        // Write chunk data followed by CRLF
        try self.writer.writeAll(data);
        try self.writer.writeAll("\r\n");
    }

    /// Write the final chunk (zero-length) and optional trailers
    pub fn finish(self: *ChunkedEncoder, trailers: ?[]const struct { name: []const u8, value: []const u8 }) !void {
        // Write zero-length chunk
        try self.writer.writeAll("0\r\n");

        // Write trailers if provided
        if (trailers) |trailer_list| {
            for (trailer_list) |trailer| {
                try self.writer.print("{s}: {s}\r\n", .{ trailer.name, trailer.value });
            }
        }

        // Final CRLF
        try self.writer.writeAll("\r\n");
    }
};

/// Chunked decoder for reading chunked data
pub const ChunkedDecoder = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    buffer: std.ArrayList(u8),
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader) ChunkedDecoder {
        return .{
            .allocator = allocator,
            .reader = reader,
            .buffer = .{},
        };
    }

    pub fn deinit(self: *ChunkedDecoder) void {
        self.buffer.deinit(self.allocator);
    }

    /// Read all chunked data into a buffer
    pub fn readAll(self: *ChunkedDecoder) ![]u8 {
        var result: std.ArrayList(u8) = .{};
        errdefer result.deinit(self.allocator);

        while (try self.readChunk()) |chunk| {
            try result.appendSlice(self.allocator, chunk);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    /// Read the next chunk
    pub fn readChunk(self: *ChunkedDecoder) !?[]const u8 {
        if (self.finished) return null;

        // Read chunk size line (hex number followed by optional chunk extensions)
        var size_line_buf: [256]u8 = undefined;
        const size_line = try self.readLine(&size_line_buf);

        // Parse chunk size (ignore extensions after semicolon)
        const semicolon = std.mem.indexOfScalar(u8, size_line, ';');
        const size_str = if (semicolon) |pos| size_line[0..pos] else size_line;

        const chunk_size = try std.fmt.parseInt(usize, std.mem.trim(u8, size_str, " \t"), 16);

        // If chunk size is 0, we've reached the end
        if (chunk_size == 0) {
            // Read trailers (if any) until we hit a blank line
            while (true) {
                var trailer_buf: [256]u8 = undefined;
                const trailer = try self.readLine(&trailer_buf);
                if (trailer.len == 0) break; // Blank line indicates end
                // TODO: Store trailers if needed
            }
            self.finished = true;
            return null;
        }

        // Read chunk data
        self.buffer.clearRetainingCapacity();
        try self.buffer.ensureTotalCapacity(self.allocator, chunk_size);

        var temp_buf: [4096]u8 = undefined;
        var bytes_read: usize = 0;
        while (bytes_read < chunk_size) {
            const to_read = @min(chunk_size - bytes_read, temp_buf.len);
            const n = try self.reader.readSliceShort(temp_buf[0..to_read]);
            if (n == 0) return error.UnexpectedEndOfChunk;
            try self.buffer.appendSlice(self.allocator, temp_buf[0..n]);
            bytes_read += n;
        }

        // Read trailing CRLF after chunk data
        var crlf_buf: [2]u8 = undefined;
        try self.reader.readSliceAll(&crlf_buf);
        if (!std.mem.eql(u8, &crlf_buf, "\r\n")) {
            return error.InvalidChunkEncoding;
        }

        return self.buffer.items;
    }

    /// Read a line (up to CRLF or LF)
    fn readLine(self: *ChunkedDecoder, buf: []u8) ![]const u8 {
        var pos: usize = 0;
        while (pos < buf.len) {
            const byte = try self.reader.takeByte();
            if (byte == '\n') {
                // Handle both LF and CRLF
                if (pos > 0 and buf[pos - 1] == '\r') {
                    return buf[0 .. pos - 1];
                }
                return buf[0..pos];
            }
            buf[pos] = byte;
            pos += 1;
        }
        return error.LineTooLong;
    }
};

/// Encode data with chunked transfer encoding
pub fn encode(allocator: std.mem.Allocator, data: []const u8, chunk_size: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var encoder = ChunkedEncoder.init(&aw.writer);

    var offset: usize = 0;
    while (offset < data.len) {
        const remaining = data.len - offset;
        const size = @min(remaining, chunk_size);
        try encoder.writeChunk(data[offset .. offset + size]);
        offset += size;
    }

    try encoder.finish(null);

    return try aw.toOwnedSlice();
}

/// Decode chunked transfer encoded data
pub fn decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var reader = std.Io.Reader.fixed(encoded);
    var decoder = ChunkedDecoder.init(allocator, &reader);
    defer decoder.deinit();

    return try decoder.readAll();
}

test "chunked encoding simple" {
    const allocator = std.testing.allocator;
    const data = "Hello, World!";

    const encoded = try encode(allocator, data, 5);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(data, decoded);
}

test "chunked encoding large" {
    const allocator = std.testing.allocator;
    const data = "A" ** 1000;

    const encoded = try encode(allocator, data, 256);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(data, decoded);
}

test "chunked decoder single chunk" {
    const allocator = std.testing.allocator;

    const encoded = "5\r\nHello\r\n0\r\n\r\n";
    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings("Hello", decoded);
}

test "chunked decoder multiple chunks" {
    const allocator = std.testing.allocator;

    const encoded = "5\r\nHello\r\n7\r\n, World\r\n1\r\n!\r\n0\r\n\r\n";
    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings("Hello, World!", decoded);
}
