const std = @import("std");
const Header = @import("header.zig");
const Body = @import("body.zig");

/// HTTP response
pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16,
    reason: []const u8,
    reason_owned: bool, // Track if reason string is owned
    version: HttpVersion,
    headers: Header.HeaderMap,
    body_reader: Body.BodyReader,
    
    pub const HttpVersion = enum {
        http_1_0,
        http_1_1,
        http_2_0,
        http_3_0,
        
        pub fn toString(self: HttpVersion) []const u8 {
            return switch (self) {
                .http_1_0 => "HTTP/1.0",
                .http_1_1 => "HTTP/1.1",
                .http_2_0 => "HTTP/2.0",
                .http_3_0 => "HTTP/3.0",
            };
        }
        
        pub fn fromString(str: []const u8) ?HttpVersion {
            if (std.mem.eql(u8, str, "HTTP/1.0")) return .http_1_0;
            if (std.mem.eql(u8, str, "HTTP/1.1")) return .http_1_1;
            if (std.mem.eql(u8, str, "HTTP/2.0") or std.mem.eql(u8, str, "HTTP/2")) return .http_2_0;
            if (std.mem.eql(u8, str, "HTTP/3.0") or std.mem.eql(u8, str, "HTTP/3")) return .http_3_0;
            return null;
        }
    };
    
    pub fn init(allocator: std.mem.Allocator, status: u16, reason: []const u8, version: HttpVersion) Response {
        return Response{
            .allocator = allocator,
            .status = status,
            .reason = reason,
            .reason_owned = false, // reason is not owned by default
            .version = version,
            .headers = Header.HeaderMap.init(allocator),
            .body_reader = Body.BodyReader.init(allocator, Body.Body.empty()),
        };
    }
    
    pub fn deinit(self: *Response) void {
        // Free owned reason string
        if (self.reason_owned) {
            self.allocator.free(self.reason);
        }
        self.headers.deinit();
        self.body_reader.deinit();
    }
    
    /// Set response body
    pub fn setBody(self: *Response, body: Body.Body) void {
        self.body_reader.deinit();
        self.body_reader = Body.BodyReader.init(self.allocator, body);
    }
    
    /// Add header
    pub fn addHeader(self: *Response, name: []const u8, value: []const u8) !void {
        try self.headers.append(name, value);
    }
    
    /// Set an owned reason string (takes ownership of the memory)
    pub fn setOwnedReason(self: *Response, reason: []const u8) void {
        if (self.reason_owned) {
            self.allocator.free(self.reason);
        }
        self.reason = reason;
        self.reason_owned = true;
    }
    
    /// Check if status indicates success (2xx)
    pub fn isSuccess(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }
    
    /// Check if status indicates redirection (3xx)
    pub fn isRedirect(self: Response) bool {
        return self.status >= 300 and self.status < 400;
    }
    
    /// Check if status indicates client error (4xx)
    pub fn isClientError(self: Response) bool {
        return self.status >= 400 and self.status < 500;
    }
    
    /// Check if status indicates server error (5xx)
    pub fn isServerError(self: Response) bool {
        return self.status >= 500 and self.status < 600;
    }
    
    /// Check if status indicates error (4xx or 5xx)
    pub fn isError(self: Response) bool {
        return self.isClientError() or self.isServerError();
    }
    
    /// Get Content-Length header value
    pub fn contentLength(self: Response) ?u64 {
        const content_length = self.headers.get(Header.common.CONTENT_LENGTH) orelse return null;
        return std.fmt.parseInt(u64, content_length, 10) catch null;
    }
    
    /// Get Content-Type header value
    pub fn contentType(self: Response) ?[]const u8 {
        return self.headers.get(Header.common.CONTENT_TYPE);
    }
    
    /// Read all response body as bytes
    pub fn readAll(self: *Response, max_size: usize) ![]u8 {
        return self.body_reader.readAll(max_size);
    }
    
    /// Read response body as text string
    pub fn text(self: *Response, max_size: usize) ![]u8 {
        return self.readAll(max_size);
    }
    
    /// Parse response body as JSON
    pub fn json(self: *Response, comptime T: type, max_size: usize) !T {
        const body_text = try self.readAll(max_size);
        defer self.body_reader.allocator.free(body_text);
        
        return std.json.parseFromSlice(T, self.body_reader.allocator, body_text, .{});
    }
    
    /// Get redirect location
    pub fn location(self: Response) ?[]const u8 {
        if (!self.isRedirect()) return null;
        return self.headers.get(Header.common.LOCATION);
    }
    
    /// Get status text for common status codes
    pub fn getStatusText(status: u16) []const u8 {
        return switch (status) {
            // 1xx Informational
            100 => "Continue",
            101 => "Switching Protocols",
            102 => "Processing",
            103 => "Early Hints",
            
            // 2xx Success
            200 => "OK",
            201 => "Created",
            202 => "Accepted",
            203 => "Non-Authoritative Information",
            204 => "No Content",
            205 => "Reset Content",
            206 => "Partial Content",
            
            // 3xx Redirection
            300 => "Multiple Choices",
            301 => "Moved Permanently",
            302 => "Found",
            303 => "See Other",
            304 => "Not Modified",
            307 => "Temporary Redirect",
            308 => "Permanent Redirect",
            
            // 4xx Client Error
            400 => "Bad Request",
            401 => "Unauthorized",
            402 => "Payment Required",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            406 => "Not Acceptable",
            408 => "Request Timeout",
            409 => "Conflict",
            410 => "Gone",
            411 => "Length Required",
            412 => "Precondition Failed",
            413 => "Payload Too Large",
            414 => "URI Too Long",
            415 => "Unsupported Media Type",
            416 => "Range Not Satisfiable",
            417 => "Expectation Failed",
            418 => "I'm a teapot",
            422 => "Unprocessable Entity",
            429 => "Too Many Requests",
            
            // 5xx Server Error
            500 => "Internal Server Error",
            501 => "Not Implemented",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            504 => "Gateway Timeout",
            505 => "HTTP Version Not Supported",
            
            else => "Unknown",
        };
    }
};

/// Response builder for testing and internal use
pub const ResponseBuilder = struct {
    allocator: std.mem.Allocator,
    response: Response,
    
    pub fn init(allocator: std.mem.Allocator, status: u16) ResponseBuilder {
        const reason_phrase = Response.getStatusText(status);
        return ResponseBuilder{
            .allocator = allocator,
            .response = Response.init(allocator, status, reason_phrase, .http_1_1),
        };
    }
    
    pub fn deinit(self: *ResponseBuilder) void {
        self.response.deinit();
    }
    
    /// Set HTTP version
    pub fn version(self: *ResponseBuilder, v: Response.HttpVersion) *ResponseBuilder {
        self.response.version = v;
        return self;
    }
    
    /// Set reason phrase (copies the string)
    pub fn reason(self: *ResponseBuilder, r: []const u8) *ResponseBuilder {
        // Create owned copy of reason string
        const owned_reason = self.allocator.dupe(u8, r) catch return self;
        self.response.setOwnedReason(owned_reason);
        return self;
    }
    
    /// Add header
    pub fn header(self: *ResponseBuilder, name: []const u8, value: []const u8) *ResponseBuilder {
        self.response.addHeader(name, value) catch {}; // Ignore errors in builder
        return self;
    }
    
    /// Set body
    pub fn body(self: *ResponseBuilder, b: Body.Body) *ResponseBuilder {
        self.response.setBody(b);
        return self;
    }
    
    /// Build the final response
    pub fn build(self: ResponseBuilder) Response {
        return self.response;
    }
};

test "response status checks" {
    var resp = Response.init(std.testing.allocator, 200, "OK", .http_1_1);
    defer resp.deinit();
    
    try std.testing.expect(resp.isSuccess());
    try std.testing.expect(!resp.isRedirect());
    try std.testing.expect(!resp.isError());
    
    resp.status = 404;
    try std.testing.expect(!resp.isSuccess());
    try std.testing.expect(resp.isClientError());
    try std.testing.expect(resp.isError());
    
    resp.status = 301;
    try std.testing.expect(!resp.isSuccess());
    try std.testing.expect(resp.isRedirect());
    try std.testing.expect(!resp.isError());
}

test "response helpers" {
    var resp = Response.init(std.testing.allocator, 200, "OK", .http_1_1);
    defer resp.deinit();
    
    try resp.addHeader(Header.common.CONTENT_TYPE, "application/json");
    try resp.addHeader(Header.common.CONTENT_LENGTH, "100");
    
    try std.testing.expectEqualStrings("application/json", resp.contentType().?);
    try std.testing.expect(resp.contentLength() == 100);
}

test "http version parsing" {
    try std.testing.expect(Response.HttpVersion.fromString("HTTP/1.1") == .http_1_1);
    try std.testing.expect(Response.HttpVersion.fromString("HTTP/2") == .http_2_0);
    try std.testing.expect(Response.HttpVersion.fromString("HTTP/3.0") == .http_3_0);
    try std.testing.expect(Response.HttpVersion.fromString("INVALID") == null);
}

test "status text" {
    try std.testing.expectEqualStrings("OK", Response.getStatusText(200));
    try std.testing.expectEqualStrings("Not Found", Response.getStatusText(404));
    try std.testing.expectEqualStrings("Internal Server Error", Response.getStatusText(500));
    try std.testing.expectEqualStrings("Unknown", Response.getStatusText(999));
}

test "response builder" {
    var builder = ResponseBuilder.init(std.testing.allocator, 201);
    defer builder.deinit();
    
    _ = builder
        .header(Header.common.CONTENT_TYPE, "application/json")
        .header(Header.common.CONTENT_LENGTH, "50")
        .body(Body.Body.fromString("{\"created\": true}"));
        
    const resp = builder.build();
    try std.testing.expect(resp.status == 201);
    try std.testing.expectEqualStrings("Created", resp.reason);
    try std.testing.expect(resp.isSuccess());
    try std.testing.expectEqualStrings("application/json", resp.contentType().?);
}