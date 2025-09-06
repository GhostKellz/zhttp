# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-09-06

### Added
- Initial HTTP client implementation for Zig
- Support for HTTP/1.1 protocol
- HTTP methods: GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS, TRACE
- Request and response handling with headers and body
- URL parsing and validation
- Support for both HTTP and HTTPS connections
- TLS certificate verification with system CA bundles  
- Connection pooling for performance optimization
- Memory-safe implementations with proper cleanup
- Comprehensive example collection demonstrating usage
- Build system with configurable feature flags

### Features
- **Client**: Full-featured HTTP client with connection management
- **Request Builder**: Fluent API for constructing HTTP requests
- **Response Handling**: Complete response parsing with status, headers, and body
- **TLS Support**: Secure HTTPS connections with certificate verification
- **URL Parsing**: RFC-compliant URL parsing and manipulation
- **Body Handling**: Support for string, bytes, and streaming request/response bodies
- **Headers**: Complete HTTP header support with common headers predefined
- **Error Handling**: Comprehensive error types for different failure scenarios

### Build Options
- `engine_h1`: Enable HTTP/1.1 engine (default: true)
- `engine_h2`: Enable HTTP/2 engine (default: false) 
- `engine_h3`: Enable HTTP/3 engine (default: false)
- `async`: Enable async runtime via zsync (default: true)
- `with_brotli`: Enable Brotli compression support (default: false)
- `with_zlib`: Enable zlib/gzip compression support (default: true)
- `quic_backend`: QUIC backend selection (default: none)

### Examples
- Basic GET and POST requests
- File download functionality
- HTTPS connections with and without certificate verification  
- JSON request/response handling
- TLS debugging and testing tools

### Technical Details
- Compatible with Zig 0.16.0-dev
- Memory efficient with ArrayList improvements for Zig 0.16
- Proper resource management and cleanup
- Cross-platform TLS certificate loading
- Comprehensive test suite

### Known Issues
- TLS reading implementation has some edge cases under investigation
- HTTP/2 and HTTP/3 support planned for future releases
- Advanced features like request/response compression are partially implemented

### Breaking Changes
- This is the initial release, no breaking changes from previous versions