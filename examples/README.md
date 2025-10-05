# zhttp Examples

This directory contains examples demonstrating various features of zhttp.

## Running Examples

### Client Examples (HTTP/1.1)

Build with HTTP/1.1 support (default):

```bash
zig build
```

Available client executables:
- `./zig-out/bin/get` - Simple GET request
- `./zig-out/bin/post_json` - POST JSON data
- `./zig-out/bin/download` - Download a file
- `./zig-out/bin/async_get` - Async GET request

### Server Examples

#### HTTP/1.1 Server

```bash
zig build
./zig-out/bin/http1_server
```

Then visit http://localhost:8080 in your browser.

#### HTTP/2 Server

```bash
zig build -Dengine_h2=true
./zig-out/bin/http2_server
```

Server runs on port 8443 (requires HTTP/2 client for testing).

#### HTTP/3 Server

```bash
zig build -Dengine_h3=true -Dquic_backend=zquic
./zig-out/bin/http3_server
```

**Note**: Requires TLS certificates (`cert.pem` and `key.pem` in current directory).

Generate self-signed certs for testing:
```bash
openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes
```

### Advanced Examples

#### Connection Pooling

```bash
zig build && ./zig-out/bin/connection_pool_example
```

Demonstrates:
- Connection pooling with keep-alive
- Connection reuse
- Pool statistics

#### Chunked Transfer Encoding

```bash
zig build && ./zig-out/bin/chunked_encoding_example
```

Demonstrates:
- Encoding data with chunked transfer encoding
- Decoding chunked data
- Streaming with trailers

#### WebSocket

```bash
zig build && ./zig-out/bin/websocket_example
```

Demonstrates:
- WebSocket upgrade handshake
- Frame encoding/decoding
- Text, binary, ping, pong, and close frames
- Masking

#### Server-Sent Events (SSE)

```bash
zig build && ./zig-out/bin/sse_example
```

Demonstrates:
- SSE event formatting
- Event builder pattern
- Parsing SSE streams
- Multi-line data support

#### HTTP/3

```bash
zig build -Dengine_h3=true -Dquic_backend=zquic
./zig-out/bin/http3_example
```

Demonstrates:
- QPACK header compression
- Variable-length integer encoding
- HTTP/3 framing (DATA, HEADERS, SETTINGS)
- 0-RTT session management

## Example Files

### Client Examples

| File | Description | Build Flags |
|------|-------------|-------------|
| `get.zig` | Simple HTTP GET request | Default |
| `post_json.zig` | POST JSON data | Default |
| `download.zig` | Download file to disk | Default |
| `async_get.zig` | Async HTTP GET with event loop | Default |
| `test_https.zig` | HTTPS with TLS verification | Default |
| `test_https_no_verify.zig` | HTTPS without verification | Default |

### Server Examples

| File | Description | Build Flags |
|------|-------------|-------------|
| `http1_server.zig` | HTTP/1.1 server with routing | Default |
| `http2_server.zig` | HTTP/2 server with multiplexing | `-Dengine_h2=true` |
| `http3_server.zig` | HTTP/3 server over QUIC | `-Dengine_h3=true -Dquic_backend=zquic` |

### Advanced Protocol Examples

| File | Description | Build Flags |
|------|-------------|-------------|
| `connection_pool_example.zig` | Connection pooling demo | Default |
| `chunked_encoding_example.zig` | Chunked transfer encoding | Default |
| `websocket_example.zig` | WebSocket protocol | Default |
| `sse_example.zig` | Server-Sent Events | Default |
| `http3_example.zig` | HTTP/3 QPACK and framing | `-Dengine_h3=true` |

## Code Snippets

### Simple GET Request

```zig
const std = @import("std");
const zhttp = @import("zhttp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var response = try zhttp.get(allocator, "https://api.github.com");
    defer response.deinit();

    std.debug.print("Status: {}\n", .{response.status_code});
    std.debug.print("Body: {s}\n", .{response.body});
}
```

### POST JSON

```zig
const json = "{ \"name\": \"John\", \"age\": 30 }";
var response = try zhttp.post(allocator, "https://api.example.com/users", json);
defer response.deinit();
```

### File Upload (Multipart)

```zig
var multipart = try zhttp.BodyStream.MultipartBuilder.init(allocator);
defer multipart.deinit();

const file = try std.fs.cwd().openFile("avatar.jpg", .{});
defer file.close();

try multipart.addFile("avatar", "avatar.jpg", "image/jpeg", file);
try multipart.addField("description", "My avatar");

var stream = try multipart.build(allocator);
var response = try zhttp.post(allocator, "https://api.example.com/upload", stream);
defer response.deinit();
```

### Async Request

```zig
var event_loop = try zhttp.AsyncRuntime.EventLoop.init(allocator);
defer event_loop.deinit();

var response = try zhttp.getAsync(allocator, &event_loop, "https://example.com");
defer response.deinit();
```

### WebSocket Client

```zig
const ws = zhttp.WebSocket;

// Generate key and upgrade
const key = try ws.Upgrade.generateKey(allocator);
defer allocator.free(key);

// After upgrade, send text frame
var frame = try ws.Frame.text(allocator, "Hello!", true);
defer frame.deinit(allocator);

try frame.write(writer);
```

### Server-Sent Events

```zig
var client = zhttp.SSE.Client.init(allocator);
defer client.deinit();

var events = try client.processChunk(sse_data);
defer events.deinit();

for (events.items) |event| {
    std.debug.print("{s}: {s}\n", .{ event.event_type.?, event.data });
}
```

## Building Custom Examples

Create a new file in `examples/` directory:

```zig
// examples/my_example.zig
const std = @import("std");
const zhttp = @import("zhttp");

pub fn main() !void {
    // Your code here
}
```

Build it:

```bash
zig build-exe examples/my_example.zig --dep zhttp --mod zhttp:./src/root.zig
```

Or add to `build.zig`:

```zig
const my_example = b.addExecutable(.{
    .name = "my_example",
    .root_source_file = b.path("examples/my_example.zig"),
    .target = target,
    .optimize = optimize,
});
my_example.root_module.addImport("zhttp", mod);
b.installArtifact(my_example);
```

## Documentation

For more detailed information, see:

- [Main Documentation](../docs/README.md)
- [Build System Guide](../docs/BUILD_SYSTEM.md)
- [HTTP/3 Server Guide](../docs/HTTP3_SERVER.md)

## Contributing

Feel free to add more examples! Please ensure they:

1. Are well-commented
2. Handle errors properly
3. Clean up resources with `defer`
4. Follow Zig style guidelines
5. Include a description at the top
