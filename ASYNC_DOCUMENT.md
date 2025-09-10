# zhttp Async Guide: Understanding the Hybrid Approach

## Overview

zhttp v0.1.1 implements a **hybrid async approach** that provides both synchronous and asynchronous HTTP client APIs. This design allows developers to choose the most appropriate approach for their use case while maintaining code compatibility and performance.

## Key Concepts

### 1. Dual Client Architecture

zhttp provides two distinct client implementations:

- **Synchronous Client** (`client.zig`): Traditional blocking I/O using standard Zig networking
- **Asynchronous Client** (`async_client.zig`): Non-blocking I/O using the zsync runtime

### 2. Build-Time Configuration

Async support is configurable at build time:

```bash
# Enable async support (default)
zig build -Dasync=true

# Disable async support  
zig build -Dasync=false
```

This is controlled by the `enable_async` build option in `build.zig:24`.

## When to Use Async vs Sync

### Use **Synchronous Client** when:

- Building simple scripts or command-line tools
- Making single or sequential HTTP requests
- Working in environments where async complexity isn't justified
- Learning HTTP client basics
- Debugging connection issues (simpler stack traces)

### Use **Asynchronous Client** when:

- Making multiple concurrent HTTP requests
- Building web servers or high-throughput applications
- Implementing real-time features (WebSockets, Server-Sent Events)
- Optimizing for resource utilization and scalability
- Working with reactive or event-driven architectures

## API Comparison

### Synchronous API

```zig
const std = @import("std");
const zhttp = @import("zhttp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Simple convenience function
    var response = try zhttp.get(allocator, "https://httpbin.org/get");
    defer response.deinit();

    // Or using explicit client
    var client = zhttp.Client.init(allocator, zhttp.ClientOptions{});
    defer client.deinit();
    
    var request = zhttp.Request.init(allocator, .GET, "https://httpbin.org/get");
    defer request.deinit();
    
    var response2 = try client.send(request);
    defer response2.deinit();
}
```

### Asynchronous API

```zig
const std = @import("std");
const zhttp = @import("zhttp");
const zsync = @import("zsync");

pub fn main() !void {
    // Define async task
    const AsyncTask = struct {
        fn task(io: zsync.Io) !void {
            var mut_io = io;
            
            // Convenience function
            var response = try zhttp.getAsync(io.getAllocator(), &mut_io, "https://httpbin.org/get");
            defer response.deinit();
            
            // Or using explicit async client
            var client = zhttp.AsyncClient.init(io.getAllocator(), zhttp.AsyncClientOptions{});
            defer client.deinit();
            
            var request = zhttp.Request.init(io.getAllocator(), .GET, "https://httpbin.org/get");
            defer request.deinit();
            
            var response2 = try client.send(&mut_io, request);
            defer response2.deinit();
        }
    };
    
    // Run with zsync runtime
    try zsync.runBlocking(AsyncTask.task, {});
}
```

## Implementation Details

### Conditional Compilation

The async client uses conditional compilation to provide a stub when async is disabled:

```zig
pub const AsyncClient = if (!build_options.enable_async) struct {
    // Stub implementation that returns AsyncNotEnabled error
    pub fn send(self: *@This(), io: anytype, request: Request) !Response {
        return Error.AsyncNotEnabled;
    }
} else struct {
    // Full async implementation using zsync
    pub fn send(self: *Self, io: *zsync.Io, request: Request) !Response {
        // ... async implementation
    }
};
```

### zsync Integration

When async is enabled, zhttp integrates with the [zsync](https://github.com/zeroengines/zsync) async runtime:

- **zsync.Io**: Provides the async I/O context
- **zsync.runBlocking**: Entry point for async applications
- **Future Integration**: Connection pooling, timers, and structured concurrency

### Current Async Status

**⚠️ Note**: The current async implementation (v0.1.1) is a **foundation** that:

- Provides the API structure for async operations
- Integrates with zsync runtime
- Uses synchronous operations internally (marked with TODO comments)
- Serves as a framework for future async I/O development

### Migration Path

The hybrid approach provides a clear migration path:

1. **Start Sync**: Begin with synchronous API for simplicity
2. **Add Async**: Gradually introduce async clients where beneficial
3. **Mix & Match**: Use both APIs in the same application as needed
4. **Full Async**: Eventually move to fully async architecture if required

## Configuration Examples

### Basic Synchronous Setup

```zig
// build.zig
const enable_async = false; // Disable async to reduce binary size

// main.zig  
const zhttp = @import("zhttp");
// Only sync API available
```

### Async-Ready Setup

```zig
// build.zig  
const enable_async = true; // Enable both sync and async APIs

// main.zig
const zhttp = @import("zhttp");
// Both sync and async APIs available
```

### Production Configuration

```zig
const client_options = zhttp.ClientOptions{
    .connect_timeout = 5000,        // 5 seconds
    .read_timeout = 30000,          // 30 seconds
    .max_redirects = 5,             // Limit redirects
    .max_retries = 3,               // Retry failed requests
    .pool = .{
        .max_per_host = 20,         // Connections per host
        .max_total = 100,           // Total connections
        .idle_timeout = 60000,      // 1 minute idle timeout
    },
};
```

## Error Handling

Both sync and async clients use the same error types defined in `error.zig`:

```zig
const Error = @import("error.zig").Error;

// Common errors
Error.ConnectTimeout
Error.ReadTimeout
Error.TooManyRedirects
Error.AsyncNotEnabled  // When async is disabled but async API is used
```

## Performance Considerations

### Synchronous Performance

- **Lower memory overhead**: No async runtime overhead
- **Simpler stack traces**: Easier debugging
- **Predictable timing**: No async scheduling overhead
- **Best for**: CLI tools, scripts, simple services

### Asynchronous Performance

- **Higher throughput**: Multiple concurrent requests
- **Better resource utilization**: Non-blocking I/O
- **Scalability**: Handles many connections efficiently  
- **Best for**: Web servers, high-load applications

## Best Practices

### 1. Choose the Right API

```zig
// Good: Simple one-off request
var response = try zhttp.get(allocator, url);

// Good: Multiple concurrent requests
try zsync.runBlocking(struct {
    fn task(io: zsync.Io) !void {
        var mut_io = io;
        // Make multiple concurrent requests
        var response1 = zhttp.getAsync(io.getAllocator(), &mut_io, url1);
        var response2 = zhttp.getAsync(io.getAllocator(), &mut_io, url2);
        // ...
    }
}.task, {});
```

### 2. Resource Management

```zig
// Always defer cleanup for both sync and async
var client = zhttp.Client.init(allocator, options);
defer client.deinit();

var response = try client.send(request);
defer response.deinit();
```

### 3. Error Handling

```zig
// Check async availability
if (!build_options.enable_async) {
    std.log.err("Async support not enabled. Build with -Dasync=true");
    return;
}
```

## Future Development

The hybrid approach enables incremental improvements:

1. **Enhanced Async I/O**: Replace sync operations with true async I/O
2. **Connection Pooling**: Async-aware connection management
3. **Structured Concurrency**: Better async task management
4. **HTTP/2 & HTTP/3**: Async-first protocol implementations
5. **WebSocket Support**: Real-time bidirectional communication

## Conclusion

zhttp's hybrid async approach provides:

- **Flexibility**: Choose sync or async based on requirements
- **Compatibility**: Existing sync code continues to work
- **Performance**: Optimal approach for each use case
- **Future-Ready**: Foundation for advanced async features

This design allows developers to start simple and scale complexity as needed, making zhttp suitable for everything from simple scripts to high-performance web applications.