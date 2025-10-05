const std = @import("std");

// Build options for conditional compilation
const build_options = @import("build_options");

// Core public API
pub const Client = @import("client.zig").Client;
pub const ClientOptions = @import("client.zig").ClientOptions;

// Server API
pub const Server = @import("server.zig").Server;
pub const ServerOptions = @import("server.zig").ServerOptions;
pub const ServerRequest = @import("server.zig").ServerRequest;
pub const ServerResponse = @import("server.zig").ServerResponse;
pub const Handler = @import("server.zig").Handler;

// Async API (available when async is enabled)
pub const AsyncClient = @import("async_client.zig").AsyncClient;
pub const AsyncClientOptions = @import("async_client.zig").AsyncClientOptions;
pub const AsyncRuntime = @import("async_runtime.zig");
pub const Request = @import("request.zig").Request;
pub const RequestBuilder = @import("request.zig").RequestBuilder;
pub const Response = @import("response.zig").Response;
pub const Header = @import("header.zig").Header;
pub const Body = @import("body.zig").Body;

// HTTP methods
pub const Method = @import("method.zig").Method;

// Error types
pub const Error = @import("error.zig").Error;

// Compression support
pub const Compression = @import("compression.zig");
pub const Brotli = @import("brotli.zig");

// Connection pooling and keep-alive
pub const ConnectionPool = @import("connection_pool.zig").ConnectionPool;
pub const PoolConfig = @import("connection_pool.zig").PoolConfig;

// Chunked transfer encoding
pub const Chunked = @import("chunked.zig");

// Timeout and retry support
pub const Timeout = @import("timeout.zig");

// Redirect handling
pub const Redirect = @import("redirect.zig");

// Request body streaming
pub const BodyStream = @import("body_stream.zig");

// HTTP/2 support
pub const Http2 = struct {
    pub const HPACK = @import("http2/hpack.zig");
    pub const Frame = @import("http2/frame.zig");
    pub const Stream = @import("http2/stream.zig");
    pub const Client = if (build_options.engine_h2) @import("http2_client.zig").Http2Client else struct {};
    pub const Server = if (build_options.engine_h2) @import("http2_server.zig").Http2Server else struct {};
    pub const ServerRequest = if (build_options.engine_h2) @import("http2_server.zig").Http2ServerRequest else struct {};
    pub const ServerResponse = if (build_options.engine_h2) @import("http2_server.zig").Http2ServerResponse else struct {};
    pub const ClientOptions = if (build_options.engine_h2) @import("http2_client.zig").Http2ClientOptions else struct {};
    pub const ServerOptions = if (build_options.engine_h2) @import("http2_server.zig").Http2ServerOptions else struct {};
};

// HTTP/3 support
pub const Http3 = struct {
    pub const QPACK = @import("http3/qpack.zig");
    pub const Frame = @import("http3/frame.zig");
    pub const ZeroRTT = @import("http3/zero_rtt.zig");
    pub const Client = if (build_options.engine_h3) @import("http3_client.zig").Http3Client else struct {};
    pub const Server = if (build_options.engine_h3) @import("http3_server.zig").Http3Server else struct {};
    pub const ServerRequest = if (build_options.engine_h3) @import("http3_server.zig").Http3ServerRequest else struct {};
    pub const ServerResponse = if (build_options.engine_h3) @import("http3_server.zig").Http3ServerResponse else struct {};
    pub const ClientOptions = if (build_options.engine_h3) @import("http3_client.zig").Http3ClientOptions else struct {};
    pub const ServerOptions = if (build_options.engine_h3) @import("http3_server.zig").Http3ServerOptions else struct {};
};

// Server-Sent Events support
pub const SSE = @import("sse.zig");

// WebSocket support
pub const WebSocket = @import("websocket.zig");

// Convenience functions
pub const get = @import("client.zig").get;
pub const post = @import("client.zig").post;
pub const put = @import("client.zig").put;
pub const patch = @import("client.zig").patch;
pub const delete = @import("client.zig").delete;
pub const head = @import("client.zig").head;
pub const download = @import("client.zig").download;

// Async convenience functions (available when async is enabled) 
pub const getAsync = @import("async_client.zig").getAsync;
pub const postAsync = @import("async_client.zig").postAsync;

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