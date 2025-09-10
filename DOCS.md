# zhttp Documentation

A modern HTTP client library for Zig with TLS support.

## Overview

zhttp is an HTTP/1.1 client library for Zig that provides a simple API for making HTTP requests with TLS support. The library is designed to be easy to use while providing flexibility for advanced use cases.

## Features

- HTTP/1.1 protocol support
- TLS/SSL connections
- Request/Response builders
- Header management
- Body handling (text, JSON, binary)
- Connection management
- Convenience functions for common operations

## Current Limitations

⚠️ **This library is under active development and not production-ready**

Major issues to be resolved:
- Memory management improvements needed for Response/Body
- Connection pooling not yet implemented
- Chunked transfer encoding is stubbed
- Redirect following needs implementation
- Limited error handling and retry logic
- No HTTP/2 support yet

## Architecture

The library is organized into several core modules:

### Core Components

- **Client** (`client.zig`) - Main HTTP client with connection management
- **Request** (`request.zig`) - Request builder and representation
- **Response** (`response.zig`) - Response parsing and handling
- **Body** (`body.zig`) - Request/response body management
- **Header** (`header.zig`) - HTTP header utilities
- **Method** (`method.zig`) - HTTP method definitions
- **Error** (`error.zig`) - Error types and handling

### Protocol Support

- **HTTP/1.1** (`http1.zig`) - HTTP/1.1 protocol implementation
- **TLS** - Native TLS support via Zig's std.crypto.tls

## Memory Management

The library uses Zig's allocator pattern throughout. Users must provide an allocator when creating a client, and proper cleanup is required:

```zig
var client = try Client.init(allocator, .{});
defer client.deinit();
```

## Error Handling

zhttp uses Zig's error union types for error handling. Common errors include:
- `ConnectionFailed` - Unable to establish connection
- `TlsHandshakeFailed` - TLS negotiation failed
- `InvalidResponse` - Malformed HTTP response
- `OutOfMemory` - Allocation failure

## Testing

Run the test suite with:
```bash
zig build test
```

## Contributing

See TODO.md for a list of planned features and known issues. Contributions are welcome!

## License

[License information to be added]