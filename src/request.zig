const std = @import("std");
const Method = @import("method.zig").Method;
const Header = @import("header.zig");
const Body = @import("body.zig").Body;

/// HTTP request
pub const Request = struct {
    method: Method,
    url: []const u8,
    headers: Header.HeaderMap,
    body: Body,
    timeout: ?u64 = null, // milliseconds
    
    pub fn init(allocator: std.mem.Allocator, method: Method, url: []const u8) Request {
        return Request{
            .method = method,
            .url = url,
            .headers = Header.HeaderMap.init(allocator),
            .body = Body.empty(),
        };
    }
    
    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }
    
    /// Set request body
    pub fn setBody(self: *Request, body: Body) void {
        self.body = body;
    }
    
    /// Add header
    pub fn addHeader(self: *Request, name: []const u8, value: []const u8) !void {
        try self.headers.append(name, value);
    }
    
    /// Set header (replace existing)
    pub fn setHeader(self: *Request, name: []const u8, value: []const u8) !void {
        try self.headers.set(name, value);
    }
    
    /// Set timeout in milliseconds
    pub fn setTimeout(self: *Request, timeout_ms: u64) void {
        self.timeout = timeout_ms;
    }
    
    /// Parse URL into components for connection
    pub fn parseUrl(self: Request, allocator: std.mem.Allocator) !UrlComponents {
        return UrlComponents.parse(allocator, self.url);
    }
};

/// URL components parsed from request URL
pub const UrlComponents = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,
    query: ?[]const u8,
    fragment: ?[]const u8,
    
    pub fn parse(allocator: std.mem.Allocator, url: []const u8) !UrlComponents {
        _ = allocator; // May need for string duplication later
        
        // Basic URL parsing - this is simplified
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
            return error.InvalidUrl;
        }
        
        const is_https = std.mem.startsWith(u8, url, "https://");
        const scheme = if (is_https) "https" else "http";
        const default_port: u16 = if (is_https) 443 else 80;
        
        const after_scheme = url[(if (is_https) 8 else 7)..]; // Skip "https://" or "http://"
        
        // Find path separator
        const path_start = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
        const host_and_port = after_scheme[0..path_start];
        const path_and_query = if (path_start < after_scheme.len) after_scheme[path_start..] else "/";
        
        // Parse host and port
        var host: []const u8 = undefined;
        var port: u16 = default_port;
        
        if (std.mem.lastIndexOfScalar(u8, host_and_port, ':')) |colon_pos| {
            host = host_and_port[0..colon_pos];
            const port_str = host_and_port[colon_pos + 1 ..];
            port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidUrl;
        } else {
            host = host_and_port;
        }
        
        if (host.len == 0) return error.InvalidUrl;
        
        // Parse path and query
        var path: []const u8 = path_and_query;
        var query: ?[]const u8 = null;
        
        if (std.mem.indexOfScalar(u8, path_and_query, '?')) |query_start| {
            path = path_and_query[0..query_start];
            query = path_and_query[query_start + 1 ..];
        }
        
        // Handle fragment (though not used in HTTP requests)
        var fragment: ?[]const u8 = null;
        if (query) |q| {
            if (std.mem.indexOfScalar(u8, q, '#')) |frag_start| {
                fragment = q[frag_start + 1 ..];
                query = q[0..frag_start];
            }
        } else if (std.mem.indexOfScalar(u8, path, '#')) |frag_start| {
            fragment = path[frag_start + 1 ..];
            path = path[0..frag_start];
        }
        
        return UrlComponents{
            .scheme = scheme,
            .host = host,
            .port = port,
            .path = if (path.len == 0) "/" else path,
            .query = query,
            .fragment = fragment,
        };
    }
    
    /// Check if URL uses secure scheme
    pub fn isSecure(self: UrlComponents) bool {
        return std.mem.eql(u8, self.scheme, "https");
    }
    
    /// Build request line for HTTP
    pub fn buildRequestLine(self: UrlComponents, allocator: std.mem.Allocator) ![]u8 {
        if (self.query) |q| {
            return try std.fmt.allocPrint(allocator, "{s}?{s}", .{ self.path, q });
        } else {
            return try allocator.dupe(u8, self.path);
        }
    }
};

/// Builder pattern for constructing requests
pub const RequestBuilder = struct {
    allocator: std.mem.Allocator,
    request: Request,
    
    pub fn init(allocator: std.mem.Allocator, m: Method, request_url: []const u8) RequestBuilder {
        return RequestBuilder{
            .allocator = allocator,
            .request = Request.init(allocator, m, request_url),
        };
    }
    
    pub fn deinit(self: *RequestBuilder) void {
        self.request.deinit();
    }
    
    /// Set HTTP method
    pub fn method(self: *RequestBuilder, m: Method) *RequestBuilder {
        self.request.method = m;
        return self;
    }
    
    /// Set URL
    pub fn url(self: *RequestBuilder, u: []const u8) *RequestBuilder {
        self.request.url = u;
        return self;
    }
    
    /// Add header
    pub fn header(self: *RequestBuilder, name: []const u8, value: []const u8) *RequestBuilder {
        self.request.addHeader(name, value) catch {}; // Ignore errors in builder
        return self;
    }
    
    /// Set query parameter
    pub fn query(self: *RequestBuilder, key: []const u8, value: []const u8) *RequestBuilder {
        // TODO: Implement proper query parameter handling
        _ = key;
        _ = value;
        return self;
    }
    
    /// Set JSON body
    pub fn json(self: *RequestBuilder, data: anytype) *RequestBuilder {
        // TODO: Implement JSON serialization
        _ = data;
        self.request.setHeader(Header.common.CONTENT_TYPE, "application/json") catch {};
        return self;
    }
    
    /// Set form data body  
    pub fn form(self: *RequestBuilder, data: []const u8) *RequestBuilder {
        self.request.body = Body.fromString(data);
        self.request.setHeader(Header.common.CONTENT_TYPE, "application/x-www-form-urlencoded") catch {};
        return self;
    }
    
    /// Set body
    pub fn body(self: *RequestBuilder, b: Body) *RequestBuilder {
        self.request.body = b;
        return self;
    }
    
    /// Set timeout
    pub fn timeout(self: *RequestBuilder, timeout_ms: u64) *RequestBuilder {
        self.request.setTimeout(timeout_ms);
        return self;
    }
    
    /// Build the final request
    pub fn build(self: RequestBuilder) Request {
        return self.request;
    }
};

test "url parsing" {
    const url1 = "https://example.com/path?query=value";
    const components1 = try UrlComponents.parse(std.testing.allocator, url1);
    
    try std.testing.expectEqualStrings("https", components1.scheme);
    try std.testing.expectEqualStrings("example.com", components1.host);
    try std.testing.expect(components1.port == 443);
    try std.testing.expectEqualStrings("/path", components1.path);
    try std.testing.expectEqualStrings("query=value", components1.query.?);
    try std.testing.expect(components1.isSecure());
    
    const url2 = "http://localhost:8080/api/v1";
    const components2 = try UrlComponents.parse(std.testing.allocator, url2);
    
    try std.testing.expectEqualStrings("http", components2.scheme);
    try std.testing.expectEqualStrings("localhost", components2.host);
    try std.testing.expect(components2.port == 8080);
    try std.testing.expectEqualStrings("/api/v1", components2.path);
    try std.testing.expect(components2.query == null);
    try std.testing.expect(!components2.isSecure());
}

test "request builder" {
    var builder = RequestBuilder.init(std.testing.allocator, .GET, "https://example.com");
    defer builder.deinit();
    
    _ = builder
        .header("User-Agent", "zhttp/0.1")
        .header("Accept", "application/json")
        .timeout(5000);
        
    const req = builder.build();
    try std.testing.expect(req.method == .GET);
    try std.testing.expectEqualStrings("https://example.com", req.url);
    try std.testing.expect(req.timeout == 5000);
    try std.testing.expectEqualStrings("zhttp/0.1", req.headers.get("User-Agent").?);
}

test "request basic operations" {
    var req = Request.init(std.testing.allocator, .POST, "https://api.example.com/data");
    defer req.deinit();
    
    try req.addHeader("Content-Type", "application/json");
    req.setBody(Body.fromString("{\"test\": true}"));
    req.setTimeout(10000);
    
    try std.testing.expect(req.method == .POST);
    try std.testing.expectEqualStrings("https://api.example.com/data", req.url);
    try std.testing.expect(req.timeout == 10000);
    try std.testing.expect(req.headers.has("Content-Type"));
    try std.testing.expect(!req.body.isEmpty());
}