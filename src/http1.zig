const std = @import("std");
const Method = @import("method.zig").Method;
const Header = @import("header.zig");
const Body = @import("body.zig").Body;
const BodyReader = @import("body.zig").BodyReader;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

/// HTTP/1.1 message parser and serializer
pub const Http1 = struct {
    
    /// Serialize HTTP request to writer
    pub fn writeRequest(writer: anytype, request: Request, url_components: @import("request.zig").UrlComponents) !void {
        // Write request line
        const request_line = try url_components.buildRequestLine(std.heap.page_allocator);
        defer std.heap.page_allocator.free(request_line);
        
        var mutable_writer = writer;
        try mutable_writer.interface.print("{s} {s} HTTP/1.1\r\n", .{ request.method.toString(), request_line });
        
        // Ensure Host header is set
        if (!request.headers.has(Header.common.HOST)) {
            if (url_components.port == 80 or url_components.port == 443) {
                try mutable_writer.interface.print("Host: {s}\r\n", .{url_components.host});
            } else {
                try mutable_writer.interface.print("Host: {s}:{d}\r\n", .{ url_components.host, url_components.port });
            }
        }
        
        // Write headers
        for (request.headers.items()) |header| {
            try mutable_writer.interface.print("{s}: {s}\r\n", .{ header.name, header.value });
        }
        
        // Set Content-Length if we have a body with known length
        if (!request.body.isEmpty() and !request.headers.has(Header.common.CONTENT_LENGTH)) {
            if (request.body.contentLength()) |length| {
                try mutable_writer.interface.print("Content-Length: {d}\r\n", .{length});
            }
        }
        
        // End headers
        try mutable_writer.interface.writeAll("\r\n");
        
        // Write body if present
        if (!request.body.isEmpty()) {
            var body_reader = BodyReader.init(std.heap.page_allocator, request.body);
            defer body_reader.deinit();
            
            var buffer: [8192]u8 = undefined;
            while (true) {
                const bytes_read = try body_reader.read(&buffer);
                if (bytes_read == 0) break;
                try mutable_writer.interface.writeAll(buffer[0..bytes_read]);
            }
        }
    }
    
    /// Parse HTTP response status line
    pub fn parseStatusLine(line: []const u8) !StatusLine {
        // Format: HTTP/1.1 200 OK
        var parts = std.mem.splitSequence(u8, line, " ");
        
        const version_str = parts.next() orelse return error.InvalidStatusLine;
        const status_str = parts.next() orelse return error.InvalidStatusLine;
        const reason = parts.rest();
        
        const version = Response.HttpVersion.fromString(version_str) orelse return error.InvalidStatusLine;
        const status = std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidStatusLine;
        
        return StatusLine{
            .version = version,
            .status = status,
            .reason = reason,
        };
    }
    
    /// Parse a single header line
    pub fn parseHeaderLine(line: []const u8) !Header.Header {
        const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        
        const name = std.mem.trim(u8, line[0..colon_pos], " \t");
        const value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
        
        if (name.len == 0) return error.InvalidHeader;
        
        return Header.Header.init(name, value);
    }
    
    /// Parse headers from lines
    pub fn parseHeaders(allocator: std.mem.Allocator, lines: []const []const u8) !Header.HeaderMap {
        var headers = Header.HeaderMap.init(allocator);
        
        for (lines) |line| {
            if (line.len == 0) break; // Empty line marks end of headers
            
            const header = try parseHeaderLine(line);
            try headers.append(header.name, header.value);
        }
        
        return headers;
    }
    
    /// Check if response uses chunked encoding
    pub fn isChunkedEncoding(headers: Header.HeaderMap) bool {
        const transfer_encoding = headers.get(Header.common.TRANSFER_ENCODING) orelse return false;
        return std.ascii.eqlIgnoreCase(transfer_encoding, "chunked");
    }
    
    /// Get content length from headers
    pub fn getContentLength(headers: Header.HeaderMap) ?u64 {
        const content_length = headers.get(Header.common.CONTENT_LENGTH) orelse return null;
        return std.fmt.parseInt(u64, content_length, 10) catch null;
    }
    
    /// Check if connection should be kept alive
    pub fn shouldKeepAlive(version: Response.HttpVersion, headers: Header.HeaderMap) bool {
        const connection = headers.get(Header.common.CONNECTION);
        
        return switch (version) {
            .http_1_0 => {
                // HTTP/1.0 defaults to close, needs explicit keep-alive
                if (connection) |conn| {
                    return std.ascii.eqlIgnoreCase(conn, "keep-alive");
                }
                return false;
            },
            .http_1_1 => {
                // HTTP/1.1 defaults to keep-alive, needs explicit close
                if (connection) |conn| {
                    return !std.ascii.eqlIgnoreCase(conn, "close");
                }
                return true;
            },
            else => false, // HTTP/2+ don't use Connection header
        };
    }
};

/// Parsed status line components
pub const StatusLine = struct {
    version: Response.HttpVersion,
    status: u16,
    reason: []const u8,
};

/// Chunked encoding reader - generic over reader type
pub fn ChunkedReader(comptime ReaderType: type) type {
    return struct {
        reader: ReaderType,
        state: State,
        chunk_size: u64,
        chunk_remaining: u64,
        finished: bool,
        
        const State = enum {
            reading_size,
            reading_chunk,
            reading_chunk_trailer,
            reading_trailers,
            finished,
        };
        
        const Self = @This();
        
        pub fn init(reader: ReaderType) Self {
            return Self{
                .reader = reader,
                .state = .reading_size,
                .chunk_size = 0,
                .chunk_remaining = 0,
                .finished = false,
            };
        }
        
        /// Read data from chunked stream
        pub fn read(self: *Self, buffer: []u8) !usize {
        if (self.finished) return 0;
        
        var total_read: usize = 0;
        
        while (total_read < buffer.len and !self.finished) {
            switch (self.state) {
                .reading_size => {
                    // Read chunk size line
                    var line_buffer: [32]u8 = undefined;
                    const line = try self.readLine(&line_buffer);
                    
                    // Parse hex chunk size
                    const semicolon_pos = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
                    const size_str = line[0..semicolon_pos];
                    
                    self.chunk_size = std.fmt.parseInt(u64, size_str, 16) catch return error.ChunkedEncodingError;
                    self.chunk_remaining = self.chunk_size;
                    
                    if (self.chunk_size == 0) {
                        self.state = .reading_trailers;
                    } else {
                        self.state = .reading_chunk;
                    }
                },
                .reading_chunk => {
                    const to_read = @min(buffer.len - total_read, self.chunk_remaining);
                    const bytes_read = try self.reader.reader().*.readSliceShort(buffer[total_read .. total_read + to_read]);

                    if (bytes_read == 0) return error.UnexpectedEndOfFile;

                    total_read += bytes_read;
                    self.chunk_remaining -= bytes_read;

                    if (self.chunk_remaining == 0) {
                        self.state = .reading_chunk_trailer;
                    }
                },
                .reading_chunk_trailer => {
                    // Read CRLF after chunk data
                    var trailer: [2]u8 = undefined;
                    const bytes_read = try self.reader.reader().*.readSliceShort(&trailer);
                    if (bytes_read != 2 or trailer[0] != '\r' or trailer[1] != '\n') {
                        return error.ChunkedEncodingError;
                    }
                    self.state = .reading_size;
                },
                .reading_trailers => {
                    // Read trailer headers (if any)
                    var line_buffer: [1024]u8 = undefined;
                    while (true) {
                        const line = try self.readLine(&line_buffer);
                        if (line.len == 0) break; // Empty line ends trailers
                        // TODO: Store trailer headers if needed
                    }
                    self.state = .finished;
                    self.finished = true;
                },
                .finished => break,
            }
        }
        
        return total_read;
    }
    
        /// Read a line ending with CRLF
        fn readLine(self: *Self, buffer: []u8) ![]const u8 {
        var pos: usize = 0;
        while (pos < buffer.len - 1) {
            var byte_buf: [1]u8 = undefined;
            const bytes_read = try self.reader.reader().*.readSliceShort(&byte_buf);
            if (bytes_read == 0) return error.UnexpectedEndOfFile;
            
            const byte = byte_buf[0];
            if (byte == '\r') {
                const next_bytes = try self.reader.reader().*.readSliceShort(&byte_buf);
                if (next_bytes == 0) return error.UnexpectedEndOfFile;
                const next_byte = byte_buf[0];
                if (next_byte == '\n') {
                    return buffer[0..pos];
                } else {
                    buffer[pos] = byte;
                    pos += 1;
                    if (pos >= buffer.len - 1) break;
                    buffer[pos] = next_byte;
                    pos += 1;
                }
            } else {
                buffer[pos] = byte;
                pos += 1;
            }
        }
        return error.HeadersTooLarge;
        }
    };
}

test "status line parsing" {
    const line = "HTTP/1.1 200 OK";
    const status = try Http1.parseStatusLine(line);
    
    try std.testing.expect(status.version == .http_1_1);
    try std.testing.expect(status.status == 200);
    try std.testing.expectEqualStrings("OK", status.reason);
}

test "header line parsing" {
    const line = "Content-Type: application/json";
    const header = try Http1.parseHeaderLine(line);
    
    try std.testing.expectEqualStrings("Content-Type", header.name);
    try std.testing.expectEqualStrings("application/json", header.value);
    
    // Test with extra whitespace
    const line2 = "  Authorization  :   Bearer token123   ";
    const header2 = try Http1.parseHeaderLine(line2);
    
    try std.testing.expectEqualStrings("Authorization", header2.name);
    try std.testing.expectEqualStrings("Bearer token123", header2.value);
}

test "keep alive detection" {
    var headers = Header.HeaderMap.init(std.testing.allocator);
    defer headers.deinit();
    
    // HTTP/1.1 defaults to keep-alive
    try std.testing.expect(Http1.shouldKeepAlive(.http_1_1, headers));
    
    try headers.set(Header.common.CONNECTION, "close");
    try std.testing.expect(!Http1.shouldKeepAlive(.http_1_1, headers));
    
    // HTTP/1.0 defaults to close
    headers.remove(Header.common.CONNECTION);
    try std.testing.expect(!Http1.shouldKeepAlive(.http_1_0, headers));
    
    try headers.set(Header.common.CONNECTION, "keep-alive");
    try std.testing.expect(Http1.shouldKeepAlive(.http_1_0, headers));
}

test "chunked encoding detection" {
    var headers = Header.HeaderMap.init(std.testing.allocator);
    defer headers.deinit();
    
    try std.testing.expect(!Http1.isChunkedEncoding(headers));
    
    try headers.set(Header.common.TRANSFER_ENCODING, "chunked");
    try std.testing.expect(Http1.isChunkedEncoding(headers));
    
    try headers.set(Header.common.TRANSFER_ENCODING, "CHUNKED");
    try std.testing.expect(Http1.isChunkedEncoding(headers));
}

test "content length parsing" {
    var headers = Header.HeaderMap.init(std.testing.allocator);
    defer headers.deinit();
    
    try std.testing.expect(Http1.getContentLength(headers) == null);
    
    try headers.set(Header.common.CONTENT_LENGTH, "1234");
    try std.testing.expect(Http1.getContentLength(headers) == 1234);
    
    try headers.set(Header.common.CONTENT_LENGTH, "invalid");
    try std.testing.expect(Http1.getContentLength(headers) == null);
}