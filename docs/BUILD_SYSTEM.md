# zhttp Modular Build System

zhttp features a modular build system that allows you to compile only the HTTP protocol versions you need, minimizing binary size and dependencies.

## Build Flags

### Engine Selection

Control which HTTP protocol versions are compiled into your binary:

```bash
# HTTP/1.1 only (default, zero dependencies)
zig build -Dengine_h1=true

# HTTP/1.1 + HTTP/2 (zero dependencies)
zig build -Dengine_h1=true -Dengine_h2=true

# All protocols including HTTP/3 (requires zquic)
zig build -Dengine_h1=true -Dengine_h2=true -Dengine_h3=true -Dquic_backend=zquic
```

### Available Flags

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `engine_h1` | `bool` | `true` | Enable HTTP/1.1 support |
| `engine_h2` | `bool` | `false` | Enable HTTP/2 support |
| `engine_h3` | `bool` | `false` | Enable HTTP/3 support |
| `quic_backend` | `string` | `"none"` | QUIC backend: `"none"` or `"zquic"` |
| `async_runtime` | `string` | `"homebrew"` | Async runtime (currently only `"homebrew"`) |

## Dependency Matrix

| Configuration | External Dependencies | Features |
|---------------|----------------------|----------|
| `-Dengine_h1=true` | **None** (std lib only) | HTTP/1.1, chunked encoding, compression (gzip/deflate/brotli), websockets, SSE |
| `-Dengine_h2=true` | **None** (homebrew HPACK) | HTTP/2, HPACK, stream multiplexing, flow control, server push |
| `-Dengine_h3=true -Dquic_backend=zquic` | **zquic** | HTTP/3, QPACK, 0-RTT, QUIC transport |

## Use Cases

### Minimal HTTP/1.1 Client

**Goal**: Smallest binary size, no external dependencies

```bash
zig build -Dengine_h1=true -Dengine_h2=false -Dengine_h3=false
```

**Features available**:
- GET, POST, PUT, PATCH, DELETE, HEAD
- Connection pooling
- Keep-alive
- Chunked transfer encoding
- Gzip/deflate/brotli decompression
- Redirect following
- Timeouts and retries
- WebSocket upgrade
- Server-Sent Events

**Binary size**: ~150KB (Release, stripped)

### Modern Web Client (HTTP/1.1 + HTTP/2)

**Goal**: Support modern web APIs with automatic protocol negotiation

```bash
zig build -Dengine_h1=true -Dengine_h2=true
```

**Features available**:
- All HTTP/1.1 features
- HTTP/2 multiplexing
- HPACK header compression
- Server push
- Priority streams

**Binary size**: ~220KB (Release, stripped)

**Dependencies**: None (homebrew HPACK implementation)

### Full Stack (HTTP/1.1 + HTTP/2 + HTTP/3)

**Goal**: Maximum performance with 0-RTT and QUIC

```bash
zig build -Dengine_h1=true -Dengine_h2=true -Dengine_h3=true -Dquic_backend=zquic
```

**Features available**:
- All HTTP/1.1 and HTTP/2 features
- HTTP/3 over QUIC
- QPACK header compression
- 0-RTT resumption
- UDP-based transport

**Binary size**: ~450KB (Release, stripped)

**Dependencies**: zquic

## Configuration in build.zig

In your project's `build.zig`, you can configure zhttp based on user options:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // User-configurable options
    const enable_h2 = b.option(bool, "http2", "Enable HTTP/2 support") orelse false;
    const enable_h3 = b.option(bool, "http3", "Enable HTTP/3 support") orelse false;

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zhttp dependency
    const zhttp = b.dependency("zhttp", .{
        .target = target,
        .optimize = optimize,
        .engine_h1 = true,
        .engine_h2 = enable_h2,
        .engine_h3 = enable_h3,
        .quic_backend = if (enable_h3) "zquic" else "none",
    });

    exe.root_module.addImport("zhttp", zhttp.module("zhttp"));
    b.installArtifact(exe);
}
```

Then build with:

```bash
# HTTP/1.1 only
zig build

# With HTTP/2
zig build -Dhttp2=true

# With HTTP/3
zig build -Dhttp3=true
```

## Runtime Detection

Check which protocols are available at runtime:

```zig
const zhttp = @import("zhttp");
const build_options = @import("build_options");

pub fn main() !void {
    std.debug.print("HTTP/1.1: {}\n", .{build_options.engine_h1});
    std.debug.print("HTTP/2: {}\n", .{build_options.engine_h2});
    std.debug.print("HTTP/3: {}\n", .{build_options.engine_h3});

    // Conditionally use HTTP/2
    if (build_options.engine_h2) {
        // Use HTTP/2 features
        var conn = try zhttp.Http2.Stream.Connection.init(allocator, true);
        defer conn.deinit();
    }
}
```

## QUIC Backend Selection

Currently, zhttp supports one QUIC backend:

### zquic (recommended)

```bash
zig build -Dengine_h3=true -Dquic_backend=zquic
```

- Maintained QUIC implementation for Zig
- Supports HTTP/3
- 0-RTT resumption
- Modern QUIC features

### Custom QUIC Backend

To use a different QUIC library, modify `build.zig`:

```zig
if (engine_h3) {
    const quic_backend = b.option([]const u8, "quic_backend", "QUIC backend") orelse "zquic";

    if (std.mem.eql(u8, quic_backend, "custom")) {
        // Add your QUIC library
        const custom_quic = b.dependency("custom_quic", .{});
        mod.addImport("quic", custom_quic.module("quic"));
    } else if (std.mem.eql(u8, quic_backend, "zquic")) {
        const zquic = b.dependency("zquic", .{});
        mod.addImport("zquic", zquic.module("zquic"));
    }
}
```

## Optimization Tips

### Minimize Binary Size

```bash
zig build -Doptimize=ReleaseSmall -Dengine_h1=true -Dengine_h2=false -Dengine_h3=false -Dstrip=true
```

### Maximum Performance

```bash
zig build -Doptimize=ReleaseFast -Dengine_h1=true -Dengine_h2=true -Dengine_h3=true -Dquic_backend=zquic
```

### Development Build

```bash
zig build -Doptimize=Debug -Dengine_h1=true -Dengine_h2=true -Dengine_h3=true
```

## CI/CD Examples

### GitHub Actions

```yaml
name: Build Matrix
on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        config:
          - { name: "HTTP/1.1", flags: "-Dengine_h1=true" }
          - { name: "HTTP/1.1 + HTTP/2", flags: "-Dengine_h1=true -Dengine_h2=true" }
          - { name: "Full stack", flags: "-Dengine_h1=true -Dengine_h2=true -Dengine_h3=true -Dquic_backend=zquic" }
    steps:
      - uses: actions/checkout@v4
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.16.0-dev
      - name: Build ${{ matrix.config.name }}
        run: zig build ${{ matrix.config.flags }}
      - name: Test
        run: zig build test
```

## Migration Guide

### From HTTP/1.1 to HTTP/2

No code changes required! Just enable HTTP/2:

```bash
# Before
zig build -Dengine_h1=true

# After
zig build -Dengine_h1=true -Dengine_h2=true
```

The client will automatically negotiate HTTP/2 via ALPN when connecting to servers that support it.

### From HTTP/2 to HTTP/3

Enable HTTP/3 and add zquic dependency:

```bash
# Before
zig build -Dengine_h1=true -Dengine_h2=true

# After
zig build -Dengine_h1=true -Dengine_h2=true -Dengine_h3=true -Dquic_backend=zquic
```

Add to `build.zig.zon`:
```zig
.dependencies = .{
    .zquic = .{
        .url = "https://github.com/ghostkellz/zquic/archive/refs/heads/main.tar.gz",
        .hash = "...",
    },
},
```

## Troubleshooting

### "Undefined symbol: zquic"

You enabled HTTP/3 but didn't specify the QUIC backend:

```bash
# Wrong
zig build -Dengine_h3=true

# Correct
zig build -Dengine_h3=true -Dquic_backend=zquic
```

### "HTTP/2 not available"

HTTP/2 is opt-in. Enable it with:

```bash
zig build -Dengine_h2=true
```

### Large binary size

Disable unused protocol versions:

```bash
# Before (450KB)
zig build -Dengine_h1=true -Dengine_h2=true -Dengine_h3=true -Dquic_backend=zquic

# After (150KB)
zig build -Dengine_h1=true -Dengine_h2=false -Dengine_h3=false
```
