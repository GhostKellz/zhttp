# zhttp Documentation

**zhttp** is a high-performance HTTP client library for Zig with support for HTTP/1.1, HTTP/2, HTTP/3, and QUIC.

## Table of Contents

1. [Getting Started](#getting-started)
2. [Build System](#build-system)
3. [HTTP/1.1 Client](#http11-client)
4. [HTTP/2 Client](#http2-client)
5. [HTTP/3 Client](#http3-client)
6. [Advanced Features](#advanced-features)
7. [API Reference](#api-reference)

## Getting Started

### Installation

Add zhttp to your `build.zig.zon`:

```zig
.dependencies = .{
    .zhttp = .{
        .url = "https://github.com/yourname/zhttp/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
},
```

### Basic Usage

```zig
const std = @import("std");
const zhttp = @import("zhttp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Simple GET request
    var response = try zhttp.get(allocator, "https://api.github.com");
    defer response.deinit();

    std.debug.print("Status: {}\n", .{response.status_code});
    std.debug.print("Body: {s}\n", .{response.body});
}
```

## Build System

zhttp uses a **modular build system** with compile-time flags to enable/disable features.

### Build Flags

| Flag | Default | Description |
|------|---------|-------------|
| `-Dengine_h1` | `true` | Enable HTTP/1.1 support |
| `-Dengine_h2` | `false` | Enable HTTP/2 support |
| `-Dengine_h3` | `false` | Enable HTTP/3 support |
| `-Dquic_backend` | `none` | QUIC backend (`none`, `zquic`) |
| `-Dasync_runtime` | `homebrew` | Async runtime (`homebrew`) |

### Build Examples

**HTTP/1.1 only (minimal):**
```bash
zig build -Dengine_h1=true
```

**HTTP/1.1 + HTTP/2:**
```bash
zig build -Dengine_h1=true -Dengine_h2=true
```

**Full stack with HTTP/3:**
```bash
zig build -Dengine_h1=true -Dengine_h2=true -Dengine_h3=true -Dquic_backend=zquic
```

### Dependency Tree

- **HTTP/1.1**: Zero external dependencies (std lib only)
- **HTTP/2**: Zero external dependencies (homebrew HPACK)
- **HTTP/3**: Requires `zquic` when `-Dengine_h3=true -Dquic_backend=zquic`

## HTTP/1.1 Client

### Features

- ✅ Connection pooling with keep-alive
- ✅ Chunked transfer encoding
- ✅ Gzip/deflate/brotli compression
- ✅ Redirect following
- ✅ Timeout and retry support
- ✅ Request body streaming
- ✅ Multipart file uploads
- ✅ WebSocket upgrade

### Examples

**GET request:**
```zig
var response = try zhttp.get(allocator, "https://example.com");
defer response.deinit();
```

**POST JSON:**
```zig
const json_body = "{ \"name\": \"John\", \"age\": 30 }";
var response = try zhttp.post(allocator, "https://api.example.com/users", json_body);
defer response.deinit();
```

**File upload:**
```zig
var multipart = try zhttp.BodyStream.MultipartBuilder.init(allocator);
defer multipart.deinit();

const file = try std.fs.cwd().openFile("avatar.jpg", .{});
defer file.close();

try multipart.addFile("avatar", "avatar.jpg", "image/jpeg", file);
try multipart.addField("description", "My new avatar");

var stream = try multipart.build(allocator);
var response = try zhttp.post(allocator, "https://api.example.com/upload", stream);
defer response.deinit();
```

**Connection pooling:**
```zig
var pool = zhttp.ConnectionPool.init(allocator, .{
    .max_connections_per_host = 6,
    .max_idle_time_seconds = 90,
});
defer pool.deinit();

var conn = try pool.acquire("example.com", 443, true);
defer pool.release(conn, true); // true = keep-alive

// Use connection...
```

## HTTP/2 Client

### Features

- ✅ HPACK header compression (RFC 7541)
- ✅ Binary framing layer
- ✅ Stream multiplexing
- ✅ Flow control
- ✅ Server push support
- ✅ Priority and dependency handling

### Examples

**Using HTTP/2 directly:**
```zig
const http2 = @import("zhttp").Http2;

var conn = try http2.Stream.Connection.init(allocator, true);
defer conn.deinit();

// Create stream
var stream = try conn.createStream();

// Encode headers with HPACK
const headers = [_]http2.Stream.Header{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":path", .value = "/api/data" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":authority", .value = "example.com" },
};

// Send HEADERS frame
// ... (see examples/http2_client.zig for full example)
```

## HTTP/3 Client

### Features

- ✅ QPACK header compression (RFC 9204)
- ✅ Variable-length integer encoding
- ✅ HTTP/3 framing over QUIC
- ✅ 0-RTT support (with session resumption)
- ✅ Integration with zquic

### Building HTTP/3 Server

To build an HTTP/3 QUIC server, enable the HTTP/3 engine and zquic backend:

```bash
zig build -Dengine_h3=true -Dquic_backend=zquic
```

**HTTP/3 Server Example:**

```zig
const std = @import("std");
const zhttp = @import("zhttp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // HTTP/3 requires QUIC transport (via zquic)
    const zquic = @import("zquic");

    // Create QUIC server
    var server = try zquic.Server.init(allocator, .{
        .addr = "0.0.0.0",
        .port = 443,
        .cert_path = "/path/to/cert.pem",
        .key_path = "/path/to/key.pem",
    });
    defer server.deinit();

    // Handle incoming connections
    while (true) {
        var conn = try server.accept();

        // Process HTTP/3 frames
        const qpack = zhttp.Http3.QPACK;
        var decoder = qpack.Decoder.init(allocator, 4096);
        defer decoder.deinit();

        // Read HTTP/3 frames from QUIC stream
        // ... (see examples/http3_server.zig)
    }
}
```

**0-RTT Support:**

```zig
var manager = zhttp.Http3.ZeroRTT.ZeroRTTManager.init(allocator, .{
    .enabled = true,
    .max_early_data_size = 16384,
});
defer manager.deinit();

// Check if 0-RTT can be used
var request = zhttp.Http3.ZeroRTT.ZeroRTTRequest.init(allocator, "GET", "/api/data");
defer request.deinit();

if (manager.canUse0RTT(&request, "example.com")) {
    // Send early data
    const ticket = manager.getTicket("example.com").?;
    // ... send with 0-RTT
}
```

## Advanced Features

### Server-Sent Events (SSE)

```zig
const sse = zhttp.SSE;

var client = sse.Client.init(allocator);
defer client.deinit();

// Process incoming SSE data
const chunk = "event: update\nid: 42\ndata: Hello, World!\n\n";
var events = try client.processChunk(chunk);
defer events.deinit();

for (events.items) |event| {
    std.debug.print("Event: {s}\n", .{event.event_type.?});
    std.debug.print("Data: {s}\n", .{event.data});
}
```

### WebSocket

```zig
const ws = zhttp.WebSocket;

// Generate WebSocket key
const key = try ws.Upgrade.generateKey(allocator);
defer allocator.free(key);

// Create upgrade headers
var headers = try ws.Upgrade.createUpgradeHeaders(allocator, "example.com", "/ws", key);
defer headers.deinit();

// After successful upgrade, send/receive frames
var frame = try ws.Frame.text(allocator, "Hello, WebSocket!", true);
defer frame.deinit(allocator);

// Write frame to connection
// try frame.write(writer);
```

### Timeout and Retry

```zig
const timeout_config = zhttp.Timeout.TimeoutConfig{
    .connect_timeout_ms = 5000,
    .read_timeout_ms = 30000,
    .total_timeout_ms = 60000,
};

var manager = zhttp.Timeout.TimeoutManager.init(timeout_config);

// Check timeout
try manager.checkTotalTimeout();

// Retry strategy
var retry = zhttp.Timeout.RetryStrategy.init(.{
    .max_retries = 3,
    .initial_backoff_ms = 100,
    .backoff_multiplier = 2.0,
});

while (true) {
    const result = makeRequest() catch |err| {
        if (retry.shouldRetry(err)) {
            retry.backoff();
            continue;
        }
        return err;
    };
    break result;
}
```

### Redirect Following

```zig
var tracker = zhttp.Redirect.RedirectTracker.init(allocator, .{
    .policy = .normal, // .none, .safe, .normal, .strict
    .max_redirects = 10,
    .allow_insecure_redirects = false,
});
defer tracker.deinit();

// Track URL
try tracker.visit("https://example.com");

// Check if should follow
const should_follow = tracker.shouldFollow(301, "POST", true, true);

// Get redirect method (may change POST to GET for 301/302)
const method = tracker.getRedirectMethod(301, "POST");
```

## API Reference

### Core Types

- `Client` - HTTP/1.1 client
- `AsyncClient` - Async HTTP client (all versions)
- `Request` - HTTP request
- `Response` - HTTP response
- `Header` - HTTP header
- `Body` - HTTP body

### Modules

- `Compression` - Gzip/deflate/brotli
- `Brotli` - Homebrew brotli compression
- `ConnectionPool` - Connection pooling
- `Chunked` - Chunked transfer encoding
- `Timeout` - Timeout and retry
- `Redirect` - Redirect handling
- `BodyStream` - Request body streaming
- `Http2.HPACK` - HTTP/2 header compression
- `Http2.Frame` - HTTP/2 framing
- `Http2.Stream` - HTTP/2 streams
- `Http3.QPACK` - HTTP/3 header compression
- `Http3.Frame` - HTTP/3 framing
- `Http3.ZeroRTT` - 0-RTT support
- `SSE` - Server-Sent Events
- `WebSocket` - WebSocket protocol

### Convenience Functions

```zig
pub fn get(allocator: Allocator, url: []const u8) !Response
pub fn post(allocator: Allocator, url: []const u8, body: []const u8) !Response
pub fn put(allocator: Allocator, url: []const u8, body: []const u8) !Response
pub fn patch(allocator: Allocator, url: []const u8, body: []const u8) !Response
pub fn delete(allocator: Allocator, url: []const u8) !Response
pub fn head(allocator: Allocator, url: []const u8) !Response
pub fn download(allocator: Allocator, url: []const u8, path: []const u8) !void
```

## Performance

- **Zero-copy**: Minimal allocations where possible
- **Connection pooling**: Reuse connections with keep-alive
- **Streaming**: Support for large request/response bodies
- **Compression**: Automatic decompression of responses
- **HTTP/2 multiplexing**: Multiple streams over one connection
- **HTTP/3 0-RTT**: Reduced latency for repeat connections

## License

See LICENSE file for details.
