# zhttp Integration Guide

How to integrate zhttp into your Zig projects using `zig fetch`.

## Installation

### Using zig fetch (Recommended)

Add zhttp to your project using Zig's package manager:

```bash
zig fetch --save https://github.com/ghostkellz/zhttp
```

This will add zhttp to your `build.zig.zon` dependencies section:

```zig
.dependencies = .{
    .zhttp = .{
        .url = "https://github.com/ghostkellz/zhttp",
        .hash = "...", // Auto-generated hash
    },
},
```

### build.zig Configuration

In your `build.zig`, add zhttp as a dependency:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add zhttp dependency
    const zhttp_dep = b.dependency("zhttp", .{
        .target = target,
        .optimize = optimize,
    });

    // Your executable
    const exe = b.addExecutable(.{
        .name = "your-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link zhttp
    exe.root_module.addImport("zhttp", zhttp_dep.module("zhttp"));
    
    b.installArtifact(exe);
}
```

### Import in Your Code

```zig
const std = @import("std");
const zhttp = @import("zhttp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use zhttp here
    var response = try zhttp.get(allocator, "https://api.example.com");
    defer response.deinit();
    
    std.debug.print("Status: {}\n", .{response.status});
}
```

## Integration Patterns

### 1. Simple HTTP Client Service

Create a reusable HTTP service wrapper:

```zig
const std = @import("std");
const zhttp = @import("zhttp");

pub const ApiClient = struct {
    allocator: std.mem.Allocator,
    client: zhttp.Client,
    base_url: []const u8,
    auth_token: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, auth_token: ?[]const u8) ApiClient {
        const options = zhttp.ClientOptions{
            .connect_timeout = 10000,
            .read_timeout = 30000,
        };
        
        return ApiClient{
            .allocator = allocator,
            .client = zhttp.Client.init(allocator, options),
            .base_url = base_url,
            .auth_token = auth_token,
        };
    }

    pub fn deinit(self: *ApiClient) void {
        self.client.deinit();
    }

    pub fn get(self: *ApiClient, endpoint: []const u8) !zhttp.Response {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, endpoint });
        defer self.allocator.free(url);

        var builder = zhttp.RequestBuilder.init(self.allocator, .GET, url);
        
        if (self.auth_token) |token| {
            const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
            defer self.allocator.free(auth_header);
            builder = builder.header("Authorization", auth_header);
        }
        
        const request = builder.build();
        return self.client.send(request);
    }

    pub fn postJson(self: *ApiClient, endpoint: []const u8, data: anytype) !zhttp.Response {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, endpoint });
        defer self.allocator.free(url);

        var builder = zhttp.RequestBuilder.init(self.allocator, .POST, url)
            .json(data)
            .header("Content-Type", "application/json");
            
        if (self.auth_token) |token| {
            const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
            defer self.allocator.free(auth_header);
            builder = builder.header("Authorization", auth_header);
        }
        
        const request = builder.build();
        return self.client.send(request);
    }
};
```

### 2. REST API Integration

Example of integrating with a REST API:

```zig
const std = @import("std");
const zhttp = @import("zhttp");

const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
};

const UsersApi = struct {
    client: ApiClient,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, token: []const u8) UsersApi {
        return UsersApi{
            .client = ApiClient.init(allocator, base_url, token),
        };
    }

    pub fn deinit(self: *UsersApi) void {
        self.client.deinit();
    }

    pub fn getUser(self: *UsersApi, user_id: u32) !User {
        const endpoint = try std.fmt.allocPrint(self.client.allocator, "/users/{}", .{user_id});
        defer self.client.allocator.free(endpoint);

        var response = try self.client.get(endpoint);
        defer response.deinit();

        if (!response.isSuccess()) {
            return error.ApiError;
        }

        return try response.json(User, 1024 * 1024);
    }

    pub fn createUser(self: *UsersApi, user_data: struct { name: []const u8, email: []const u8 }) !User {
        var response = try self.client.postJson("/users", user_data);
        defer response.deinit();

        if (!response.isSuccess()) {
            return error.ApiError;
        }

        return try response.json(User, 1024 * 1024);
    }
};
```

### 3. File Download Service

Integration for downloading files:

```zig
const std = @import("std");
const zhttp = @import("zhttp");

const DownloadManager = struct {
    allocator: std.mem.Allocator,
    client: zhttp.Client,

    pub fn init(allocator: std.mem.Allocator) DownloadManager {
        const options = zhttp.ClientOptions{
            .connect_timeout = 30000,
            .read_timeout = 120000, // Longer timeout for large files
            .max_body_size = 100 * 1024 * 1024, // 100MB max
        };
        
        return DownloadManager{
            .allocator = allocator,
            .client = zhttp.Client.init(allocator, options),
        };
    }

    pub fn deinit(self: *DownloadManager) void {
        self.client.deinit();
    }

    pub fn downloadFile(self: *DownloadManager, url: []const u8, output_path: []const u8) !void {
        var response = try zhttp.get(self.allocator, url);
        defer response.deinit();

        if (!response.isSuccess()) {
            std.debug.print("Download failed with status: {}\n", .{response.status});
            return error.DownloadFailed;
        }

        const content = try response.readAll(100 * 1024 * 1024); // 100MB max
        defer self.allocator.free(content);

        const file = try std.fs.cwd().createFile(output_path, .{});
        defer file.close();
        try file.writeAll(content);

        std.debug.print("Downloaded {} bytes to {s}\n", .{ content.len, output_path });
    }

    pub fn downloadWithProgress(self: *DownloadManager, url: []const u8, output_path: []const u8) !void {
        const request = zhttp.RequestBuilder.init(self.allocator, .GET, url).build();
        var response = try self.client.send(request);
        defer response.deinit();

        if (!response.isSuccess()) {
            return error.DownloadFailed;
        }

        const content_length = response.contentLength();
        const file = try std.fs.cwd().createFile(output_path, .{});
        defer file.close();

        // Read in chunks and show progress
        var buffer: [8192]u8 = undefined;
        var total_read: usize = 0;
        
        while (true) {
            const bytes_read = try response.body_reader.read(&buffer);
            if (bytes_read == 0) break;
            
            try file.writeAll(buffer[0..bytes_read]);
            total_read += bytes_read;
            
            if (content_length) |total| {
                const progress = (@as(f64, @floatFromInt(total_read)) / @as(f64, @floatFromInt(total))) * 100.0;
                std.debug.print("\rProgress: {d:.1}%", .{progress});
            }
        }
        std.debug.print("\nDownload complete: {} bytes\n", .{total_read});
    }
};
```

### 4. Configuration-Based Client

Integration with application configuration:

```zig
const std = @import("std");
const zhttp = @import("zhttp");

const HttpConfig = struct {
    base_url: []const u8,
    timeout_ms: u64 = 30000,
    max_retries: u8 = 3,
    user_agent: []const u8 = "MyApp/1.0",
    enable_tls_verify: bool = true,
};

const ConfigurableClient = struct {
    allocator: std.mem.Allocator,
    client: zhttp.Client,
    config: HttpConfig,

    pub fn initFromConfig(allocator: std.mem.Allocator, config: HttpConfig) ConfigurableClient {
        const options = zhttp.ClientOptions{
            .connect_timeout = config.timeout_ms,
            .read_timeout = config.timeout_ms,
            .max_retries = config.max_retries,
            .user_agent = config.user_agent,
            .tls = .{
                .verify_certificates = config.enable_tls_verify,
            },
        };
        
        return ConfigurableClient{
            .allocator = allocator,
            .client = zhttp.Client.init(allocator, options),
            .config = config,
        };
    }

    pub fn deinit(self: *ConfigurableClient) void {
        self.client.deinit();
    }
};
```

### 5. Error Handling Integration

Robust error handling for production use:

```zig
const std = @import("std");
const zhttp = @import("zhttp");

const HttpError = error{
    NetworkTimeout,
    ServerError,
    ClientError,
    InvalidResponse,
    RateLimited,
};

const SafeHttpClient = struct {
    client: zhttp.Client,
    allocator: std.mem.Allocator,

    pub fn safeRequest(self: *SafeHttpClient, request: zhttp.Request) HttpError!zhttp.Response {
        var response = self.client.send(request) catch |err| switch (err) {
            error.ConnectionTimeout, error.RequestTimeout => return HttpError.NetworkTimeout,
            error.ConnectionFailed, error.NetworkError => return HttpError.NetworkTimeout,
            error.InvalidResponse => return HttpError.InvalidResponse,
            else => return HttpError.InvalidResponse,
        };

        // Check status codes
        if (response.status >= 500) {
            response.deinit();
            return HttpError.ServerError;
        }
        
        if (response.status == 429) {
            response.deinit();
            return HttpError.RateLimited;
        }
        
        if (response.status >= 400) {
            response.deinit();
            return HttpError.ClientError;
        }

        return response;
    }

    pub fn retryableRequest(self: *SafeHttpClient, request: zhttp.Request, max_retries: u8) !zhttp.Response {
        var retries: u8 = 0;
        
        while (retries <= max_retries) {
            const result = self.safeRequest(request);
            
            switch (result) {
                HttpError.NetworkTimeout, HttpError.ServerError => {
                    retries += 1;
                    if (retries <= max_retries) {
                        // Exponential backoff
                        const delay_ms = std.math.pow(u64, 2, retries) * 1000;
                        std.time.sleep(delay_ms * std.time.ns_per_ms);
                        continue;
                    }
                    return result;
                },
                HttpError.RateLimited => {
                    // Wait longer for rate limits
                    std.time.sleep(60 * std.time.ns_per_s);
                    retries += 1;
                    continue;
                },
                else => return result,
            }
        }
        
        unreachable;
    }
};
```

## Testing Integration

### Mock HTTP Client

For testing purposes:

```zig
const std = @import("std");
const zhttp = @import("zhttp");

const MockResponse = struct {
    status: u16,
    body: []const u8,
    headers: std.StringHashMap([]const u8),
};

const MockClient = struct {
    responses: std.HashMap([]const u8, MockResponse, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockClient {
        return MockClient{
            .responses = std.HashMap([]const u8, MockResponse, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn addMockResponse(self: *MockClient, url: []const u8, response: MockResponse) !void {
        try self.responses.put(url, response);
    }

    pub fn get(self: *MockClient, url: []const u8) !MockResponse {
        return self.responses.get(url) orelse error.MockNotFound;
    }
};
```

## Build System Integration

### Custom Build Options

Add build options for HTTP configuration:

```zig
// In build.zig
pub fn build(b: *std.Build) void {
    // ... existing code ...

    const enable_tls = b.option(bool, "tls", "Enable TLS support") orelse true;
    const http_timeout = b.option(u64, "http-timeout", "Default HTTP timeout in ms") orelse 30000;

    const options = b.addOptions();
    options.addOption(bool, "enable_tls", enable_tls);
    options.addOption(u64, "http_timeout", http_timeout);

    exe.root_module.addOptions("build_options", options);
}
```

```zig
// In your code
const build_options = @import("build_options");

const client_options = zhttp.ClientOptions{
    .connect_timeout = build_options.http_timeout,
    .tls = .{
        .verify_certificates = build_options.enable_tls,
    },
};
```

## Best Practices

1. **Always call `deinit()`** on clients and responses to prevent memory leaks
2. **Use timeouts** appropriate for your use case
3. **Handle errors gracefully** with proper error types
4. **Reuse client instances** instead of creating new ones for each request
5. **Validate responses** before processing
6. **Use connection pooling** by keeping client instances alive
7. **Consider rate limiting** for API integrations
8. **Mock HTTP calls** in tests
9. **Use HTTPS** with certificate verification in production
10. **Monitor performance** and adjust timeouts/retry logic accordingly

## Common Issues

### Memory Leaks
Ensure you call `deinit()` on all clients and responses:
```zig
var client = zhttp.Client.init(allocator, .{});
defer client.deinit(); // Important!

var response = try client.send(request);
defer response.deinit(); // Important!
```

### TLS Certificate Errors
For development with self-signed certificates:
```zig
const options = zhttp.ClientOptions{
    .tls = .{ .verify_certificates = false }, // Only for development!
};
```

### Timeout Issues
Adjust timeouts for your use case:
```zig
const options = zhttp.ClientOptions{
    .connect_timeout = 10000, // 10 seconds
    .read_timeout = 60000,    // 60 seconds for large responses
};
```