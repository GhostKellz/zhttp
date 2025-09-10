const std = @import("std");

/// Request/Response body variants
pub const Body = union(enum) {
    /// No body
    none: void,
    /// Static bytes
    bytes: []const u8,
    /// Reader interface for streaming
    reader: *std.Io.Reader,
    /// File path for file uploads/downloads
    file: []const u8,
    /// Multipart form data (streaming)
    multipart: MultipartBody,
    
    /// Get content length if known
    pub fn contentLength(self: Body) ?u64 {
        return switch (self) {
            .none => 0,
            .bytes => |bytes| bytes.len,
            .file => |_| null, // Would need to stat the file
            .reader, .multipart => null, // Unknown length for streams
        };
    }
    
    /// Check if body is empty
    pub fn isEmpty(self: Body) bool {
        return switch (self) {
            .none => true,
            .bytes => |bytes| bytes.len == 0,
            else => false,
        };
    }
    
    /// Create body from string
    pub fn fromString(str: []const u8) Body {
        return Body{ .bytes = str };
    }
    
    /// Create body from file path
    pub fn fromFile(path: []const u8) Body {
        return Body{ .file = path };
    }
    
    /// Create body from reader
    pub fn fromReader(reader: *std.Io.Reader) Body {
        return Body{ .reader = reader };
    }
    
    /// Create empty body
    pub fn empty() Body {
        return Body{ .none = {} };
    }
};

/// Multipart form data builder
pub const MultipartBody = struct {
    allocator: std.mem.Allocator,
    boundary: []const u8,
    parts: std.ArrayList(Part),
    
    pub const Part = struct {
        name: []const u8,
        content: Body,
        content_type: ?[]const u8 = null,
        filename: ?[]const u8 = null,
        headers: ?std.ArrayList(std.meta.Tuple(&.{ []const u8, []const u8 })) = null,
    };
    
    pub fn init(allocator: std.mem.Allocator) MultipartBody {
        // Generate random boundary
        var boundary_buf: [32]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp()));
        const boundary = std.fmt.bufPrint(&boundary_buf, "----zhttp{d}", .{prng.random().int(u64)}) catch unreachable;
        
        return MultipartBody{
            .allocator = allocator,
            .boundary = allocator.dupe(u8, boundary) catch unreachable,
            .parts = std.ArrayList(Part){},
        };
    }
    
    pub fn deinit(self: *MultipartBody) void {
        self.allocator.free(self.boundary);
        for (self.parts.items) |*part| {
            if (part.headers) |*headers| {
                headers.deinit(self.allocator);
            }
        }
        self.parts.deinit(self.allocator);
    }
    
    /// Add a form field
    pub fn addField(self: *MultipartBody, name: []const u8, value: []const u8) !void {
        try self.parts.append(self.allocator, Part{
            .name = name,
            .content = Body.fromString(value),
        });
    }
    
    /// Add a file part
    pub fn addFile(self: *MultipartBody, name: []const u8, filename: []const u8, content: Body, content_type: ?[]const u8) !void {
        try self.parts.append(self.allocator, Part{
            .name = name,
            .content = content,
            .content_type = content_type,
            .filename = filename,
        });
    }
    
    /// Get the Content-Type header value
    pub fn contentType(self: MultipartBody, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{self.boundary});
    }
};

/// Body reader that handles different body types
pub const BodyReader = struct {
    allocator: std.mem.Allocator,
    body: Body,
    state: union(enum) {
        uninitialized: void,
        bytes: struct {
            data: []const u8,
            pos: usize,
        },
        file: struct {
            file: std.fs.File,
        },
        reader: *std.Io.Reader,
        finished: void,
    },
    
    pub fn init(allocator: std.mem.Allocator, body: Body) BodyReader {
        return BodyReader{
            .allocator = allocator,
            .body = body,
            .state = .uninitialized,
        };
    }
    
    pub fn deinit(self: *BodyReader) void {
        switch (self.state) {
            .file => |*file_state| file_state.file.close(),
            else => {},
        }
    }
    
    /// Read data from the body
    pub fn read(self: *BodyReader, buffer: []u8) !usize {
        switch (self.state) {
            .uninitialized => {
                // Initialize based on body type
                switch (self.body) {
                    .none => {
                        self.state = .finished;
                        return 0;
                    },
                    .bytes => |bytes| {
                        self.state = .{ .bytes = .{ .data = bytes, .pos = 0 } };
                        return self.read(buffer);
                    },
                    .file => |path| {
                        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
                            error.FileNotFound => return error.FileNotFound,
                            else => return error.SystemResources,
                        };
                        self.state = .{ .file = .{ .file = file } };
                        return self.read(buffer);
                    },
                    .reader => |reader| {
                        self.state = .{ .reader = reader };
                        return self.read(buffer);
                    },
                    .multipart => {
                        // TODO: Implement multipart streaming
                        return error.UnsupportedFeature;
                    },
                }
            },
            .bytes => |*bytes_state| {
                const remaining = bytes_state.data[bytes_state.pos..];
                const to_copy = @min(buffer.len, remaining.len);
                @memcpy(buffer[0..to_copy], remaining[0..to_copy]);
                bytes_state.pos += to_copy;
                if (bytes_state.pos >= bytes_state.data.len) {
                    self.state = .finished;
                }
                return to_copy;
            },
            .file => |*file_state| {
                const bytes_read = file_state.file.read(buffer) catch |err| switch (err) {
                    else => return error.SystemResources,
                };
                if (bytes_read == 0) {
                    self.state = .finished;
                }
                return bytes_read;
            },
            .reader => |reader| {
                const bytes_read = reader.readSliceShort(buffer) catch |err| switch (err) {
                    else => return error.SystemResources,
                };
                if (bytes_read == 0) {
                    self.state = .finished;
                }
                return bytes_read;
            },
            .finished => return 0,
        }
    }
    
    /// Read all data into a buffer
    pub fn readAll(self: *BodyReader, max_size: usize) ![]u8 {
        var result: std.ArrayList(u8) = .{};
        defer result.deinit(self.allocator);
        
        var buffer: [8192]u8 = undefined;
        while (result.items.len < max_size) {
            const bytes_read = try self.read(buffer[0..@min(buffer.len, max_size - result.items.len)]);
            if (bytes_read == 0) break;
            try result.appendSlice(self.allocator, buffer[0..bytes_read]);
        }
        
        if (result.items.len >= max_size) {
            return error.BodyTooLarge;
        }
        
        return try result.toOwnedSlice(self.allocator);
    }
};

test "body types" {
    const empty = Body.empty();
    try std.testing.expect(empty.isEmpty());
    try std.testing.expect(empty.contentLength() == 0);
    
    const text = Body.fromString("hello world");
    try std.testing.expect(!text.isEmpty());
    try std.testing.expect(text.contentLength() == 11);
}

test "body reader with bytes" {
    const body = Body.fromString("hello world");
    var reader = BodyReader.init(std.testing.allocator, body);
    defer reader.deinit();
    
    var buffer: [5]u8 = undefined;
    const n1 = try reader.read(&buffer);
    try std.testing.expect(n1 == 5);
    try std.testing.expectEqualStrings("hello", buffer[0..n1]);
    
    const n2 = try reader.read(&buffer);
    try std.testing.expect(n2 == 5);
    try std.testing.expectEqualStrings(" worl", buffer[0..n2]);
    
    const n3 = try reader.read(&buffer);
    try std.testing.expect(n3 == 1);
    try std.testing.expectEqualStrings("d", buffer[0..n3]);
    
    const n4 = try reader.read(&buffer);
    try std.testing.expect(n4 == 0); // EOF
}

test "multipart body" {
    var multipart = MultipartBody.init(std.testing.allocator);
    defer multipart.deinit();
    
    try multipart.addField("name", "John Doe");
    try multipart.addField("email", "john@example.com");
    
    try std.testing.expect(multipart.parts.items.len == 2);
    try std.testing.expectEqualStrings("name", multipart.parts.items[0].name);
    
    const content_type = try multipart.contentType(std.testing.allocator);
    defer std.testing.allocator.free(content_type);
    try std.testing.expect(std.mem.startsWith(u8, content_type, "multipart/form-data; boundary="));
}