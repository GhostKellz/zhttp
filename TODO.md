# zhttp TODO - Protocol Support & Architecture Roadmap

## 🎯 Protocol Support Goals
- ✅ HTTP/1.1 - Fully supported
- 🚧 HTTP/2 - Implement (homebrew)
- 🚧 HTTP/3 - Optional via zquic integration
- 🚧 QUIC - Optional via zquic backend

## 🏗️ Modular Build System (Already Implemented!)
```bash
# Build flags available:
-Dengine_h1=true     # HTTP/1.1 (default: true)
-Dengine_h2=true     # HTTP/2 (default: false)
-Dengine_h3=true     # HTTP/3 (default: false)
-Dasync=true         # Async runtime (default: true)
-Dquic_backend=zquic # QUIC impl: zquic|none (default: none)
```

## 🔥 Critical: Async Runtime Overhaul
**Problem:** zsync dependency causes conflicts in downstream projects

**Solution:** Homebrew async runtime
1. Remove zsync dependency entirely
2. Implement minimal async runtime:
   - Event loop (epoll on Linux, kqueue on macOS/BSD)
   - Async task scheduler
   - Timer system for timeouts
   - Non-blocking I/O primitives
3. Keep it minimal - only what zhttp needs
4. Benefits:
   - ✅ Zero dependency conflicts
   - ✅ Full control over implementation
   - ✅ Smaller footprint
   - ✅ Better integration with Zig's async story

## 📋 Immediate Priorities

### Memory & Resource Management
1. Fix Response memory management - The Response/Body system needs proper ownership semantics to
   avoid memory leaks. This means adding a proper deinit() that frees owned strings and body data.
2. Connection pooling - The releaseConnection method currently just destroys connections. Should
   implement proper connection reuse for keep-alive.
3. Better error handling - Currently missing proper timeout handling, connection retries, and error
   recovery.

### Protocol Implementation

#### HTTP/1.1 (Current)
4. Chunked transfer encoding - The readChunkedBodyFromConnection is just a stub that reads until close.
5. Redirect following - The sendWithRedirects method has the structure but needs actual redirect logic.
6. Request body streaming - Currently only supports static body content, not streaming uploads.

#### HTTP/2 (Homebrew Implementation)
7. HPACK header compression
8. Binary framing layer
9. Stream multiplexing
10. Flow control
11. Server push support
12. Priority and dependency handling

#### HTTP/3 + QUIC (zquic Integration)
13. Evaluate zquic integration (https://github.com/ghostkellz/zquic)
    - Production-ready, 100K+ req/sec
    - Post-quantum crypto (ML-KEM-768, SLH-DSA)
    - Make it optional via `-Dquic_backend=zquic`
14. Implement HTTP/3 framing over QUIC
15. QPACK header compression
16. 0-RTT support

### Features & Quality of Life
17. Compression - gzip/brotli support (flags exist but not implemented)
18. Add common convenience methods - GET, POST, PUT, DELETE helper methods on the Client
19. Better request building - Fluent API for building requests with headers, query params, etc.
20. WebSocket support (HTTP/1.1 upgrade)
21. Server-Sent Events (SSE) support

## 🚀 Build Strategy
- Each protocol engine can be enabled/disabled at compile time
- Zero-cost abstractions - disabled features add no binary size
- Minimal dependencies:
  - HTTP/1.1: No deps (std lib only)
  - HTTP/2: No deps (homebrew impl)
  - HTTP/3: Optional zquic dep (only if enabled)
  - Async: Homebrew (no external deps)
