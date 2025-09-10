# zhttp API Reference

Complete API documentation for the zhttp HTTP client library.

## Quick Start

```zig
const std = @import("std");
const zhttp = @import("zhttp");

// Simple GET request
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

var response = try zhttp.get(allocator, "https://api.example.com/data");
defer response.deinit();

// Check response status
if (response.isSuccess()) {
    const body = try response.text(1024 * 1024); // 1MB max
    defer allocator.free(body);
    std.debug.print("Response: {s}\n", .{body});
}
```

## Client

### ClientOptions

Configuration for HTTP client behavior.

```zig
pub const ClientOptions = struct {
    connect_timeout: u64 = 10000,      // Connection timeout in ms
    read_timeout: u64 = 30000,         // Read timeout in ms
    write_timeout: u64 = 30000,        // Write timeout in ms
    max_redirects: u8 = 10,            // Maximum redirects to follow
    max_retries: u8 = 3,               // Maximum retry attempts
    user_agent: []const u8 = "zhttp/0.1.0",
    auto_decompress: bool = true,       // Automatic decompression
    max_body_size: usize = 10 * 1024 * 1024, // 10MB max response
    pool: PoolOptions = PoolOptions{}, // Connection pool settings
    tls: TlsOptions = TlsOptions{},     // TLS settings
}
```

### Client Methods

#### `Client.init(allocator: std.mem.Allocator, options: ClientOptions) Client`
Creates a new HTTP client instance.

#### `client.deinit() void`
Cleans up client resources.

#### `client.send(request: Request) !Response`
Sends an HTTP request and returns the response.

### Connection Pool Options

```zig
pub const PoolOptions = struct {
    max_per_host: u32 = 10,     // Max connections per host
    max_total: u32 = 100,       // Max total connections
    idle_timeout: u64 = 90000,  // Idle timeout in ms
}
```

### TLS Options

```zig
pub const TlsOptions = struct {
    verify_certificates: bool = true,
    ca_bundle: ?[]const u8 = null,
    pinned_certificates: ?[]const []const u8 = null,
    min_version: TlsVersion = .tls_1_2,
    alpn_protocols: []const []const u8 = &.{ "h2", "http/1.1" },
}
```

## Request

### Request Methods

#### `Request.init(allocator: std.mem.Allocator, method: Method, url: []const u8) Request`
Creates a new request.

#### `request.setBody(body: Body) void`
Sets the request body.

#### `request.addHeader(name: []const u8, value: []const u8) !void`
Adds a header to the request.

#### `request.setHeader(name: []const u8, value: []const u8) !void`
Sets a header, replacing any existing value.

#### `request.setTimeout(timeout_ms: u64) void`
Sets request timeout.

### RequestBuilder (Fluent API)

```zig
const request = RequestBuilder.init(allocator, .GET, "https://api.example.com")
    .header("Authorization", "Bearer token123")
    .query("limit", "10")
    .timeout(5000)
    .build();
```

#### Builder Methods
- `method(m: Method) *RequestBuilder` - Set HTTP method
- `url(u: []const u8) *RequestBuilder` - Set URL
- `header(name: []const u8, value: []const u8) *RequestBuilder` - Add header
- `query(key: []const u8, value: []const u8) *RequestBuilder` - Add query parameter
- `json(data: anytype) *RequestBuilder` - Set JSON body
- `form(data: []const u8) *RequestBuilder` - Set form data
- `body(b: Body) *RequestBuilder` - Set request body
- `timeout(timeout_ms: u64) *RequestBuilder` - Set timeout
- `build() Request` - Build the final request

## Response

### Response Methods

#### `response.isSuccess() bool`
Returns true if status code is 2xx.

#### `response.isRedirect() bool`
Returns true if status code is 3xx.

#### `response.isClientError() bool`
Returns true if status code is 4xx.

#### `response.isServerError() bool`
Returns true if status code is 5xx.

#### `response.isError() bool`
Returns true if status code is 4xx or 5xx.

#### `response.contentLength() ?u64`
Returns the Content-Length header value.

#### `response.contentType() ?[]const u8`
Returns the Content-Type header value.

#### `response.readAll(max_size: usize) ![]u8`
Reads the entire response body (caller owns returned memory).

#### `response.text(max_size: usize) ![]u8`
Reads response body as text.

#### `response.json(comptime T: type, max_size: usize) !T`
Parses response body as JSON into type T.

#### `response.location() ?[]const u8`
Returns the Location header for redirects.

## Body

### Body Types

```zig
pub const Body = union(enum) {
    none,
    string: []const u8,
    file: []const u8,
    reader: *std.Io.Reader,
    multipart: MultipartBody,
}
```

### Body Methods

#### `Body.fromString(str: []const u8) Body`
Creates body from string data.

#### `Body.fromFile(path: []const u8) Body`
Creates body from file path.

#### `Body.fromReader(reader: *std.Io.Reader) Body`
Creates body from reader interface.

#### `Body.empty() Body`
Creates empty body.

### MultipartBody

For file uploads and form data.

```zig
var multipart = MultipartBody.init(allocator);
defer multipart.deinit();

try multipart.addField("name", "John Doe");
try multipart.addFile("avatar", "profile.jpg", Body.fromFile("./profile.jpg"), "image/jpeg");

const request = RequestBuilder.init(allocator, .POST, "https://api.example.com/upload")
    .body(Body{ .multipart = multipart })
    .build();
```

## Headers

### HeaderMap Methods

#### `headers.append(name: []const u8, value: []const u8) !void`
Adds a header (allows multiple values for same name).

#### `headers.set(name: []const u8, value: []const u8) !void`
Sets a header (replaces existing value).

#### `headers.get(name: []const u8) ?[]const u8`
Gets first header value.

#### `headers.getAll(name: []const u8, allocator: std.mem.Allocator) ![][]const u8`
Gets all values for a header name.

#### `headers.has(name: []const u8) bool`
Checks if header exists.

#### `headers.remove(name: []const u8) void`
Removes all headers with given name.

## HTTP Methods

```zig
pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,
    TRACE,
    CONNECT,
}
```

### Method Utility Functions

#### `method.toString() []const u8`
Returns string representation of method.

#### `Method.fromString(str: []const u8) ?Method`
Parses method from string.

#### `method.isSafe() bool`
Returns true for safe methods (GET, HEAD, OPTIONS, TRACE).

#### `method.isIdempotent() bool`
Returns true for idempotent methods.

#### `method.expectsBody() bool`
Returns true if method typically has a request body.

## Convenience Functions

### `zhttp.get(allocator: std.mem.Allocator, url: []const u8) !Response`
Performs a simple GET request.

### `zhttp.post(allocator: std.mem.Allocator, url: []const u8, body: Body) !Response`
Performs a POST request with body.

### `zhttp.download(allocator: std.mem.Allocator, url: []const u8, file_path: []const u8) !void`
Downloads a file from URL to local path.

## Error Handling

### Error Types

```zig
pub const Error = error{
    // Connection errors
    ConnectionFailed,
    ConnectionTimeout,
    TlsHandshakeFailed,
    
    // Request/Response errors
    InvalidUrl,
    InvalidRequest,
    InvalidResponse,
    InvalidHeader,
    
    // Protocol errors
    UnsupportedProtocol,
    UnsupportedVersion,
    
    // Limits and constraints
    TooManyRedirects,
    ResponseBodyTooLarge,
    RequestTimeout,
    
    // Resource errors
    OutOfMemory,
    FileNotFound,
    PermissionDenied,
    
    // Generic errors
    NetworkError,
    UnknownError,
}
```

### Error Context

```zig
pub const ErrorContext = struct {
    message: ?[]const u8 = null,
    url: ?[]const u8 = null,
    status_code: ?u16 = null,
    
    pub fn withMessage(self: ErrorContext, msg: []const u8) ErrorContext
    pub fn withUrl(self: ErrorContext, url: []const u8) ErrorContext  
    pub fn withStatusCode(self: ErrorContext, code: u16) ErrorContext
}
```

## Examples

### Basic Usage

```zig
// GET request
var response = try zhttp.get(allocator, "https://jsonplaceholder.typicode.com/posts/1");
defer response.deinit();

if (response.isSuccess()) {
    const Post = struct { id: u32, title: []const u8, body: []const u8 };
    const post = try response.json(Post, 1024);
    std.debug.print("Title: {s}\n", .{post.title});
}
```

### POST with JSON

```zig
const data = .{ .title = "New Post", .body = "Content here" };
const request = RequestBuilder.init(allocator, .POST, "https://jsonplaceholder.typicode.com/posts")
    .json(data)
    .build();

var response = try client.send(request);
defer response.deinit();
```

### File Upload

```zig
var multipart = MultipartBody.init(allocator);
defer multipart.deinit();

try multipart.addFile("file", "document.pdf", Body.fromFile("./document.pdf"), "application/pdf");

const request = RequestBuilder.init(allocator, .POST, "https://api.example.com/upload")
    .body(Body{ .multipart = multipart })
    .build();
```

### Custom Headers and Authentication

```zig
const request = RequestBuilder.init(allocator, .GET, "https://api.example.com/protected")
    .header("Authorization", "Bearer your-token-here")
    .header("User-Agent", "MyApp/1.0")
    .header("Accept", "application/json")
    .build();
```