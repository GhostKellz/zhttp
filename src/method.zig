const std = @import("std");

/// HTTP methods
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    PATCH,
    TRACE,
    CONNECT,
    
    /// Convert method to string for HTTP requests
    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .PATCH => "PATCH",
            .TRACE => "TRACE",
            .CONNECT => "CONNECT",
        };
    }
    
    /// Parse method from string
    pub fn fromString(str: []const u8) ?Method {
        if (std.ascii.eqlIgnoreCase(str, "GET")) return .GET;
        if (std.ascii.eqlIgnoreCase(str, "POST")) return .POST;
        if (std.ascii.eqlIgnoreCase(str, "PUT")) return .PUT;
        if (std.ascii.eqlIgnoreCase(str, "DELETE")) return .DELETE;
        if (std.ascii.eqlIgnoreCase(str, "HEAD")) return .HEAD;
        if (std.ascii.eqlIgnoreCase(str, "OPTIONS")) return .OPTIONS;
        if (std.ascii.eqlIgnoreCase(str, "PATCH")) return .PATCH;
        if (std.ascii.eqlIgnoreCase(str, "TRACE")) return .TRACE;
        if (std.ascii.eqlIgnoreCase(str, "CONNECT")) return .CONNECT;
        return null;
    }
    
    /// Check if method is considered safe (doesn't change server state)
    pub fn isSafe(self: Method) bool {
        return switch (self) {
            .GET, .HEAD, .OPTIONS, .TRACE => true,
            else => false,
        };
    }
    
    /// Check if method is idempotent (multiple identical requests have same effect)
    pub fn isIdempotent(self: Method) bool {
        return switch (self) {
            .GET, .HEAD, .PUT, .DELETE, .OPTIONS, .TRACE => true,
            .POST, .PATCH, .CONNECT => false,
        };
    }
    
    /// Check if method should have a request body
    pub fn expectsBody(self: Method) bool {
        return switch (self) {
            .POST, .PUT, .PATCH => true,
            else => false,
        };
    }
};

test "method to string" {
    try std.testing.expectEqualStrings("GET", Method.GET.toString());
    try std.testing.expectEqualStrings("POST", Method.POST.toString());
    try std.testing.expectEqualStrings("DELETE", Method.DELETE.toString());
}

test "method from string" {
    try std.testing.expect(Method.fromString("GET") == .GET);
    try std.testing.expect(Method.fromString("get") == .GET);
    try std.testing.expect(Method.fromString("POST") == .POST);
    try std.testing.expect(Method.fromString("INVALID") == null);
}

test "method properties" {
    try std.testing.expect(Method.GET.isSafe());
    try std.testing.expect(!Method.POST.isSafe());
    
    try std.testing.expect(Method.GET.isIdempotent());
    try std.testing.expect(!Method.POST.isIdempotent());
    
    try std.testing.expect(!Method.GET.expectsBody());
    try std.testing.expect(Method.POST.expectsBody());
}