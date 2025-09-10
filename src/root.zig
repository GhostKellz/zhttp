const std = @import("std");

// Core public API
pub const Client = @import("client.zig").Client;
pub const ClientOptions = @import("client.zig").ClientOptions;
pub const Request = @import("request.zig").Request;
pub const RequestBuilder = @import("request.zig").RequestBuilder;
pub const Response = @import("response.zig").Response;
pub const Header = @import("header.zig").Header;
pub const Body = @import("body.zig").Body;

// HTTP methods
pub const Method = @import("method.zig").Method;

// Error types
pub const Error = @import("error.zig").Error;

// Convenience functions
pub const get = @import("client.zig").get;
pub const post = @import("client.zig").post;
pub const put = @import("client.zig").put;
pub const patch = @import("client.zig").patch;
pub const delete = @import("client.zig").delete;
pub const head = @import("client.zig").head;
pub const download = @import("client.zig").download;

// Version check disabled for now - see build.zig.zon minimum_zig_version

test {
    // Import all tests
    _ = @import("client.zig");
    _ = @import("request.zig");
    _ = @import("response.zig");
    _ = @import("header.zig");
    _ = @import("body.zig");
    _ = @import("method.zig");
    _ = @import("error.zig");
    _ = @import("http1.zig");
}