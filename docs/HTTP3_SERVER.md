# Building an HTTP/3 QUIC Server with zhttp

This guide explains how to build an HTTP/3 server using zhttp's modular build system and zquic backend.

## Prerequisites

1. **Zig 0.16.0-dev** or later
2. **zquic** library (automatically fetched when building with HTTP/3 enabled)
3. **TLS certificates** (required for QUIC)

## Quick Start

### 1. Build Configuration

Build zhttp with HTTP/3 support enabled:

```bash
zig build -Dengine_h1=true -Dengine_h2=true -Dengine_h3=true -Dquic_backend=zquic
```

### 2. Add Dependencies

In your `build.zig.zon`:

```zig
.dependencies = .{
    .zhttp = .{
        .url = "https://github.com/yourname/zhttp/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
    .zquic = .{
        .url = "https://github.com/ghostkellz/zquic/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
},
```

### 3. Configure build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "http3-server",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zhttp with HTTP/3 enabled
    const zhttp = b.dependency("zhttp", .{
        .target = target,
        .optimize = optimize,
        .engine_h1 = true,
        .engine_h2 = true,
        .engine_h3 = true,
        .quic_backend = "zquic",
    });

    exe.root_module.addImport("zhttp", zhttp.module("zhttp"));

    // zquic is automatically added when quic_backend = "zquic"

    b.installArtifact(exe);
}
```

## Basic HTTP/3 Server

### Minimal Example

```zig
const std = @import("std");
const zhttp = @import("zhttp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize QUIC server via zquic
    const zquic = @import("zquic");

    var server = try zquic.Server.init(allocator, .{
        .addr = "0.0.0.0",
        .port = 443,
        .cert_path = "/path/to/cert.pem",
        .key_path = "/path/to/key.pem",
        // HTTP/3 ALPN
        .alpn_protocols = &[_][]const u8{"h3"},
    });
    defer server.deinit();

    std.debug.print("HTTP/3 server listening on port 443\n", .{});

    // Accept connections
    while (true) {
        var conn = server.accept() catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            continue;
        };

        // Spawn handler
        const thread = try std.Thread.spawn(.{}, handleConnection, .{ allocator, conn });
        thread.detach();
    }
}

fn handleConnection(allocator: std.mem.Allocator, conn: anytype) !void {
    defer conn.deinit();

    // Initialize QPACK decoder for header decompression
    var decoder = zhttp.Http3.QPACK.Decoder.init(allocator, 4096);
    defer decoder.deinit();

    // Read HTTP/3 frames from QUIC streams
    while (true) {
        // Accept bidirectional stream
        var stream = conn.acceptBidiStream() catch |err| {
            if (err == error.ConnectionClosed) break;
            return err;
        };
        defer stream.close();

        // Read frame header
        const frame_header = try zhttp.Http3.Frame.FrameHeader.decode(stream.reader());

        switch (frame_header.frame_type) {
            .headers => {
                // Read header block
                const header_block = try allocator.alloc(u8, @intCast(frame_header.length));
                defer allocator.free(header_block);
                _ = try stream.reader().readAll(header_block);

                // Decode QPACK headers
                var headers = try decoder.decodeHeaderBlock(header_block);
                defer {
                    for (headers.items) |h| {
                        allocator.free(h.name);
                        allocator.free(h.value);
                    }
                    headers.deinit();
                }

                // Extract request details
                var method: ?[]const u8 = null;
                var path: ?[]const u8 = null;
                for (headers.items) |h| {
                    if (std.mem.eql(u8, h.name, ":method")) method = h.value;
                    if (std.mem.eql(u8, h.name, ":path")) path = h.value;
                }

                std.debug.print("Request: {s} {s}\n", .{ method.?, path.? });

                // Send response
                try sendResponse(allocator, stream, 200, "Hello from HTTP/3!");
            },

            .data => {
                // Handle data frame
                const data = try allocator.alloc(u8, @intCast(frame_header.length));
                defer allocator.free(data);
                _ = try stream.reader().readAll(data);

                std.debug.print("Received data: {s}\n", .{data});
            },

            .settings => {
                // Handle settings frame
                const settings_frame = try zhttp.Http3.Frame.SettingsFrame.decode(
                    allocator,
                    frame_header,
                    stream.reader(),
                );
                defer allocator.free(settings_frame.settings);

                for (settings_frame.settings) |setting| {
                    std.debug.print("Setting: {} = {}\n", .{ setting.parameter, setting.value });
                }
            },

            else => {
                // Skip unknown frame types
                try stream.reader().skipBytes(frame_header.length, .{});
            },
        }
    }
}

fn sendResponse(
    allocator: std.mem.Allocator,
    stream: anytype,
    status: u16,
    body: []const u8,
) !void {
    // Encode response headers with QPACK
    var encoder = zhttp.Http3.QPACK.Encoder.init(allocator, 4096);
    defer encoder.deinit();

    const headers = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = ":status", .value = try std.fmt.allocPrint(allocator, "{d}", .{status}) },
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "content-length", .value = try std.fmt.allocPrint(allocator, "{d}", .{body.len}) },
    };
    defer allocator.free(headers[0].value);
    defer allocator.free(headers[2].value);

    var header_block = std.ArrayList(u8).init(allocator);
    defer header_block.deinit();

    try encoder.encodeHeaders(header_block.writer().any(), &headers);

    // Send HEADERS frame
    const headers_frame = zhttp.Http3.Frame.HeadersFrame.init(header_block.items);
    try headers_frame.encode(stream.writer());

    // Send DATA frame
    const data_frame = zhttp.Http3.Frame.DataFrame.init(body);
    try data_frame.encode(stream.writer());
}
```

## Advanced Features

### 0-RTT Support

Enable 0-RTT to reduce connection latency for repeat clients:

```zig
// Initialize 0-RTT manager
var zero_rtt = zhttp.Http3.ZeroRTT.ZeroRTTManager.init(allocator, .{
    .enabled = true,
    .max_early_data_size = 16384,
    .session_ticket_lifetime = 86400, // 24 hours
});
defer zero_rtt.deinit();

// In connection handler, check for early data
if (conn.hasEarlyData()) {
    const early_data = try conn.readEarlyData(allocator);
    defer allocator.free(early_data);

    // Process early data (must be idempotent!)
    try handleEarlyData(early_data);
}

// After handshake, issue session ticket
const ticket = try conn.getSessionTicket();
try zero_rtt.storeTicket("client_id", ticket, 16384);
```

### QPACK Dynamic Table

Configure QPACK dynamic table size for better compression:

```zig
// Send SETTINGS frame with QPACK parameters
var settings = zhttp.Http3.Frame.SettingsFrame.init(&[_]zhttp.Http3.Frame.SettingsFrame.Setting{
    .{ .parameter = .qpack_max_table_capacity, .value = 16384 },
    .{ .parameter = .qpack_blocked_streams, .value = 100 },
});

try settings.encode(control_stream.writer());
```

### Connection Multiplexing

HTTP/3 allows multiple concurrent streams:

```zig
// Handle multiple streams concurrently
var threads = std.ArrayList(std.Thread).init(allocator);
defer {
    for (threads.items) |thread| {
        thread.join();
    }
    threads.deinit();
}

while (true) {
    var stream = try conn.acceptBidiStream();

    const thread = try std.Thread.spawn(.{}, handleStream, .{ allocator, stream });
    try threads.append(thread);
}
```

## TLS Certificate Generation

HTTP/3 requires TLS. Generate self-signed certificates for testing:

```bash
# Generate private key
openssl genrsa -out key.pem 2048

# Generate self-signed certificate
openssl req -new -x509 -key key.pem -out cert.pem -days 365 \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost"
```

For production, use certificates from Let's Encrypt or another CA.

## Production Deployment

### Systemd Service

Create `/etc/systemd/system/http3-server.service`:

```ini
[Unit]
Description=HTTP/3 Server
After=network.target

[Service]
Type=simple
User=http3
WorkingDirectory=/opt/http3-server
ExecStart=/opt/http3-server/http3-server
Restart=on-failure
RestartSec=10

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/http3-server/data

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl enable http3-server
sudo systemctl start http3-server
```

### Docker Deployment

```dockerfile
FROM zigtools/zig:0.16.0-dev AS builder

WORKDIR /app
COPY . .

RUN zig build -Doptimize=ReleaseFast \
    -Dengine_h1=true \
    -Dengine_h2=true \
    -Dengine_h3=true \
    -Dquic_backend=zquic

FROM debian:bookworm-slim

COPY --from=builder /app/zig-out/bin/http3-server /usr/local/bin/

# Copy TLS certificates
COPY cert.pem /etc/http3/cert.pem
COPY key.pem /etc/http3/key.pem

EXPOSE 443/udp

CMD ["/usr/local/bin/http3-server"]
```

Build and run:

```bash
docker build -t http3-server .
docker run -p 443:443/udp http3-server
```

## Testing

### curl with HTTP/3

```bash
# Install curl with HTTP/3 support
curl --http3 https://localhost:443/

# Verbose output
curl --http3 -v https://localhost:443/
```

### Load Testing

Use `h3load` for HTTP/3 load testing:

```bash
h3load -n 10000 -c 100 https://localhost:443/
```

## Monitoring

Log connection statistics:

```zig
std.debug.print("Active connections: {}\n", .{server.getActiveConnections()});
std.debug.print("Total bytes sent: {}\n", .{server.getTotalBytesSent()});
std.debug.print("Total bytes received: {}\n", .{server.getTotalBytesReceived()});
```

## Troubleshooting

### "QUIC connection failed"

- Check firewall allows UDP port 443
- Verify TLS certificates are valid
- Check ALPN protocol is "h3"

### "QPACK decompression error"

- Ensure dynamic table size is synchronized between client and server
- Send SETTINGS frame with QPACK parameters early

### "Stream reset"

- Client may have exceeded flow control limits
- Check stream window sizes

## Performance Tuning

### Buffer Sizes

```zig
var server = try zquic.Server.init(allocator, .{
    .addr = "0.0.0.0",
    .port = 443,
    .cert_path = "/path/to/cert.pem",
    .key_path = "/path/to/key.pem",
    .max_recv_buffer_size = 1024 * 1024, // 1MB
    .max_send_buffer_size = 1024 * 1024, // 1MB
    .max_streams_per_connection = 100,
});
```

### OS Tuning

```bash
# Increase UDP buffer sizes
sudo sysctl -w net.core.rmem_max=2500000
sudo sysctl -w net.core.wmem_max=2500000
```

## Next Steps

- [Build System Documentation](BUILD_SYSTEM.md)
- [QPACK Reference](../src/http3/qpack.zig)
- [HTTP/3 Framing](../src/http3/frame.zig)
- [0-RTT Guide](../src/http3/zero_rtt.zig)
