const std = @import("std");

/// Request body streaming support
/// Allows sending large request bodies without loading everything into memory

/// Body stream interface
pub const BodyStream = struct {
    reader: std.io.AnyReader,
    content_length: ?usize, // null for chunked encoding

    pub fn init(reader: std.io.AnyReader, content_length: ?usize) BodyStream {
        return .{
            .reader = reader,
            .content_length = content_length,
        };
    }

    /// Read data from the stream
    pub fn read(self: *BodyStream, buffer: []u8) !usize {
        return try self.reader.read(buffer);
    }

    /// Write stream to a writer (with optional chunked encoding)
    pub fn writeTo(self: *BodyStream, writer: std.io.AnyWriter, use_chunked: bool) !usize {
        var total_written: usize = 0;
        var buffer: [8192]u8 = undefined;

        if (use_chunked) {
            // Use chunked transfer encoding
            const chunked = @import("chunked.zig");
            var encoder = chunked.ChunkedEncoder.init(writer);

            while (true) {
                const n = try self.reader.read(&buffer);
                if (n == 0) break;

                try encoder.writeChunk(buffer[0..n]);
                total_written += n;
            }

            try encoder.finish(null);
        } else {
            // Regular streaming
            while (true) {
                const n = try self.reader.read(&buffer);
                if (n == 0) break;

                try writer.writeAll(buffer[0..n]);
                total_written += n;
            }
        }

        return total_written;
    }

    /// Create from a file
    pub fn fromFile(file: std.fs.File) BodyStream {
        const size = file.getEndPos() catch null;
        return .{
            .reader = file.reader().any(),
            .content_length = size,
        };
    }

    /// Create from a slice
    pub fn fromSlice(data: []const u8) BodyStream {
        var fbs = std.io.fixedBufferStream(data);
        return .{
            .reader = fbs.reader().any(),
            .content_length = data.len,
        };
    }
};

/// Multipart form data builder for file uploads
pub const MultipartBuilder = struct {
    allocator: std.mem.Allocator,
    boundary: []const u8,
    parts: std.ArrayList(Part),

    const Part = struct {
        name: []const u8,
        content_type: ?[]const u8,
        filename: ?[]const u8,
        data: union(enum) {
            slice: []const u8,
            file: std.fs.File,
            reader: std.io.AnyReader,
        },
    };

    pub fn init(allocator: std.mem.Allocator) !MultipartBuilder {
        // Generate random boundary
        var prng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp()));
        const random = prng.random();

        var boundary_buf: [32]u8 = undefined;
        for (&boundary_buf) |*b| {
            b.* = "0123456789abcdef"[random.intRangeAtMost(usize, 0, 15)];
        }

        const boundary = try std.fmt.allocPrint(allocator, "----zhttp{s}", .{boundary_buf});

        return .{
            .allocator = allocator,
            .boundary = boundary,
            .parts = std.ArrayList(Part).init(allocator),
        };
    }

    pub fn deinit(self: *MultipartBuilder) void {
        self.allocator.free(self.boundary);
        self.parts.deinit();
    }

    /// Add a text field
    pub fn addField(self: *MultipartBuilder, name: []const u8, value: []const u8) !void {
        try self.parts.append(.{
            .name = name,
            .content_type = null,
            .filename = null,
            .data = .{ .slice = value },
        });
    }

    /// Add a file
    pub fn addFile(self: *MultipartBuilder, field_name: []const u8, filename: []const u8, content_type: []const u8, file: std.fs.File) !void {
        try self.parts.append(.{
            .name = field_name,
            .content_type = content_type,
            .filename = filename,
            .data = .{ .file = file },
        });
    }

    /// Get content type header value
    pub fn getContentType(self: *const MultipartBuilder) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "multipart/form-data; boundary={s}", .{self.boundary});
    }

    /// Write multipart data to writer
    pub fn writeTo(self: *MultipartBuilder, writer: std.io.AnyWriter) !usize {
        var total_written: usize = 0;

        for (self.parts.items) |part| {
            // Write boundary
            const boundary_line = try std.fmt.allocPrint(self.allocator, "--{s}\r\n", .{self.boundary});
            defer self.allocator.free(boundary_line);
            try writer.writeAll(boundary_line);
            total_written += boundary_line.len;

            // Write Content-Disposition header
            if (part.filename) |filename| {
                const disposition = try std.fmt.allocPrint(
                    self.allocator,
                    "Content-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\n",
                    .{ part.name, filename },
                );
                defer self.allocator.free(disposition);
                try writer.writeAll(disposition);
                total_written += disposition.len;
            } else {
                const disposition = try std.fmt.allocPrint(
                    self.allocator,
                    "Content-Disposition: form-data; name=\"{s}\"\r\n",
                    .{part.name},
                );
                defer self.allocator.free(disposition);
                try writer.writeAll(disposition);
                total_written += disposition.len;
            }

            // Write Content-Type header if present
            if (part.content_type) |ct| {
                const ct_header = try std.fmt.allocPrint(self.allocator, "Content-Type: {s}\r\n", .{ct});
                defer self.allocator.free(ct_header);
                try writer.writeAll(ct_header);
                total_written += ct_header.len;
            }

            // Empty line between headers and body
            try writer.writeAll("\r\n");
            total_written += 2;

            // Write part data
            switch (part.data) {
                .slice => |data| {
                    try writer.writeAll(data);
                    total_written += data.len;
                },
                .file => |file| {
                    var buffer: [8192]u8 = undefined;
                    while (true) {
                        const n = try file.read(&buffer);
                        if (n == 0) break;
                        try writer.writeAll(buffer[0..n]);
                        total_written += n;
                    }
                },
                .reader => |*r| {
                    var buffer: [8192]u8 = undefined;
                    while (true) {
                        const n = try r.read(&buffer);
                        if (n == 0) break;
                        try writer.writeAll(buffer[0..n]);
                        total_written += n;
                    }
                },
            }

            // CRLF after part data
            try writer.writeAll("\r\n");
            total_written += 2;
        }

        // Write final boundary
        const final_boundary = try std.fmt.allocPrint(self.allocator, "--{s}--\r\n", .{self.boundary});
        defer self.allocator.free(final_boundary);
        try writer.writeAll(final_boundary);
        total_written += final_boundary.len;

        return total_written;
    }

    /// Build into a BodyStream
    pub fn build(self: *MultipartBuilder, allocator: std.mem.Allocator) !BodyStream {
        var buffer = std.ArrayList(u8).init(allocator);
        _ = try self.writeTo(buffer.writer().any());

        const data = try buffer.toOwnedSlice();
        var fbs = try allocator.create(std.io.FixedBufferStream([]const u8));
        fbs.* = std.io.fixedBufferStream(data);

        return .{
            .reader = fbs.reader().any(),
            .content_length = data.len,
        };
    }
};

test "body stream from slice" {
    const data = "Hello, World!";
    var stream = BodyStream.fromSlice(data);

    var buffer: [100]u8 = undefined;
    const n = try stream.read(&buffer);

    try std.testing.expectEqual(@as(usize, 13), n);
    try std.testing.expectEqualStrings(data, buffer[0..n]);
}

test "multipart builder" {
    const allocator = std.testing.allocator;

    var builder = try MultipartBuilder.init(allocator);
    defer builder.deinit();

    try builder.addField("name", "John Doe");
    try builder.addField("email", "john@example.com");

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    _ = try builder.writeTo(buffer.writer().any());

    // Check that boundary is present
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, builder.boundary) != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "name=\"name\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "John Doe") != null);
}
