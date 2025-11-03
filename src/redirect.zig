const std = @import("std");

/// HTTP Redirect handling (RFC 7231 Section 6.4)

/// Redirect policy
pub const RedirectPolicy = enum {
    /// Never follow redirects
    none,
    /// Follow only GET/HEAD redirects
    safe,
    /// Follow all redirects, changing POST to GET for 301/302
    normal,
    /// Follow all redirects, preserving method and body
    strict,
};

/// Redirect configuration
pub const RedirectConfig = struct {
    policy: RedirectPolicy = .normal,
    max_redirects: usize = 10,
    allow_insecure_redirects: bool = false, // Allow HTTPS -> HTTP
};

/// Redirect chain tracker
pub const RedirectTracker = struct {
    allocator: std.mem.Allocator,
    visited_urls: std.ArrayList([]const u8),
    config: RedirectConfig,

    pub fn init(allocator: std.mem.Allocator, config: RedirectConfig) RedirectTracker {
        return .{
            .allocator = allocator,
            .visited_urls = .{},
            .config = config,
        };
    }

    pub fn deinit(self: *RedirectTracker) void {
        for (self.visited_urls.items) |url| {
            self.allocator.free(url);
        }
        self.visited_urls.deinit(self.allocator);
    }

    /// Check if we should follow this redirect
    pub fn shouldFollow(self: *const RedirectTracker, status_code: u16, method: []const u8, from_https: bool, to_https: bool) bool {
        // Check redirect limit
        if (self.visited_urls.items.len >= self.config.max_redirects) {
            return false;
        }

        // Check policy
        switch (self.config.policy) {
            .none => return false,
            .safe => {
                // Only follow GET/HEAD
                return std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD");
            },
            .normal, .strict => {
                // Check insecure redirects
                if (from_https and !to_https and !self.config.allow_insecure_redirects) {
                    return false;
                }
                return isRedirect(status_code);
            },
        }
    }

    /// Track a visited URL
    pub fn visit(self: *RedirectTracker, url: []const u8) !void {
        // Check for redirect loops
        for (self.visited_urls.items) |visited| {
            if (std.mem.eql(u8, visited, url)) {
                return error.RedirectLoop;
            }
        }

        const url_copy = try self.allocator.dupe(u8, url);
        try self.visited_urls.append(self.allocator, url_copy);
    }

    /// Get the method to use for redirect
    pub fn getRedirectMethod(self: *const RedirectTracker, status_code: u16, original_method: []const u8) []const u8 {
        switch (self.config.policy) {
            .strict => return original_method,
            else => {
                // RFC 7231: 301/302/303 change POST to GET
                if ((status_code == 301 or status_code == 302 or status_code == 303) and
                    std.mem.eql(u8, original_method, "POST"))
                {
                    return "GET";
                }
                return original_method;
            },
        }
    }

    /// Should preserve body on redirect
    pub fn shouldPreserveBody(self: *const RedirectTracker, status_code: u16, original_method: []const u8) bool {
        switch (self.config.policy) {
            .strict => {
                // 307/308 always preserve body
                return status_code == 307 or status_code == 308;
            },
            else => {
                // Only preserve for 307/308, and only if method stays the same
                if (status_code == 307 or status_code == 308) {
                    const new_method = self.getRedirectMethod(status_code, original_method);
                    return std.mem.eql(u8, new_method, original_method);
                }
                return false;
            },
        }
    }
};

/// Check if status code is a redirect
pub fn isRedirect(status_code: u16) bool {
    return switch (status_code) {
        301, // Moved Permanently
        302, // Found
        303, // See Other
        307, // Temporary Redirect
        308, // Permanent Redirect
        => true,
        else => false,
    };
}

/// Parse Location header to get redirect URL
pub fn parseLocationHeader(location: []const u8, base_url: []const u8) ![]const u8 {
    // If location is absolute, return as-is
    if (std.mem.startsWith(u8, location, "http://") or
        std.mem.startsWith(u8, location, "https://"))
    {
        return location;
    }

    // If location is protocol-relative (//example.com/path)
    if (std.mem.startsWith(u8, location, "//")) {
        // Extract protocol from base_url
        const protocol_end = std.mem.indexOf(u8, base_url, "://") orelse return error.InvalidBaseUrl;
        return std.mem.concat(std.heap.page_allocator, u8, &[_][]const u8{
            base_url[0..protocol_end],
            ":",
            location,
        });
    }

    // Location is relative - need to resolve against base_url
    // Extract base (protocol + host)
    const protocol_end = std.mem.indexOf(u8, base_url, "://") orelse return error.InvalidBaseUrl;
    const after_protocol = protocol_end + 3;
    const path_start = std.mem.indexOfPos(u8, base_url, after_protocol, "/") orelse base_url.len;

    const base = base_url[0..path_start];

    if (std.mem.startsWith(u8, location, "/")) {
        // Absolute path
        return std.mem.concat(std.heap.page_allocator, u8, &[_][]const u8{ base, location });
    } else {
        // Relative path - append to base with /
        return std.mem.concat(std.heap.page_allocator, u8, &[_][]const u8{ base, "/", location });
    }
}

test "is redirect status" {
    try std.testing.expect(isRedirect(301));
    try std.testing.expect(isRedirect(302));
    try std.testing.expect(isRedirect(303));
    try std.testing.expect(isRedirect(307));
    try std.testing.expect(isRedirect(308));
    try std.testing.expect(!isRedirect(200));
    try std.testing.expect(!isRedirect(404));
}

test "redirect tracker visit" {
    const allocator = std.testing.allocator;

    var tracker = RedirectTracker.init(allocator, .{});
    defer tracker.deinit();

    try tracker.visit("https://example.com");
    try std.testing.expectEqual(@as(usize, 1), tracker.visited_urls.items.len);

    // Visiting again should cause redirect loop error
    try std.testing.expectError(error.RedirectLoop, tracker.visit("https://example.com"));
}

test "redirect method conversion" {
    const config = RedirectConfig{ .policy = .normal };
    const tracker = RedirectTracker.init(std.testing.allocator, config);

    // 301/302 should change POST to GET
    const method1 = tracker.getRedirectMethod(301, "POST");
    try std.testing.expectEqualStrings("GET", method1);

    const method2 = tracker.getRedirectMethod(302, "POST");
    try std.testing.expectEqualStrings("GET", method2);

    // 307/308 should preserve POST
    const method3 = tracker.getRedirectMethod(307, "POST");
    try std.testing.expectEqualStrings("POST", method3);

    // GET should always stay GET
    const method4 = tracker.getRedirectMethod(301, "GET");
    try std.testing.expectEqualStrings("GET", method4);
}

test "redirect should follow policy" {
    const allocator = std.testing.allocator;

    // Safe policy - only GET/HEAD
    {
        var tracker = RedirectTracker.init(allocator, .{ .policy = .safe });
        defer tracker.deinit();

        try std.testing.expect(tracker.shouldFollow(301, "GET", false, false));
        try std.testing.expect(tracker.shouldFollow(301, "HEAD", false, false));
        try std.testing.expect(!tracker.shouldFollow(301, "POST", false, false));
    }

    // None policy - never follow
    {
        var tracker = RedirectTracker.init(allocator, .{ .policy = .none });
        defer tracker.deinit();

        try std.testing.expect(!tracker.shouldFollow(301, "GET", false, false));
    }
}

test "parse location header absolute" {
    const location = "https://example.com/new-path";
    const base = "https://old.com/old-path";

    const result = try parseLocationHeader(location, base);
    try std.testing.expectEqualStrings(location, result);
}

test "parse location header relative" {
    const location = "new-path";
    const base = "https://example.com/old-path";

    const result = try parseLocationHeader(location, base);
    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualStrings("https://example.com/new-path", result);
}

test "parse location header absolute path" {
    const location = "/new-path";
    const base = "https://example.com/old-path";

    const result = try parseLocationHeader(location, base);
    defer std.heap.page_allocator.free(result);

    try std.testing.expectEqualStrings("https://example.com/new-path", result);
}
