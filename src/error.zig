const std = @import("std");

/// Structured error types for the HTTP client
pub const Error = error{
    // Connection errors
    ConnectTimeout,
    ReadTimeout,
    WriteTimeout,
    ConnectionRefused,
    ConnectionReset,
    NetworkUnreachable,
    HostUnreachable,
    
    // TLS errors
    TlsError,
    CertificateVerificationFailed,
    CertPinFail,
    TlsHandshakeTimeout,
    
    // DNS errors
    DnsError,
    DnsTimeout,
    HostNotFound,
    
    // Protocol errors
    ProtocolError,
    InvalidStatusLine,
    InvalidHeader,
    InvalidContentLength,
    ChunkedEncodingError,
    UnsupportedTransferEncoding,
    
    // HTTP/2 specific
    H2GoAway,
    H2StreamReset,
    H2FlowControl,
    H2FrameSize,
    H2ProtocolError,
    
    // HTTP/3 specific
    H3TransportError,
    H3StreamError,
    H3ConnectionError,
    
    // Request/Response errors
    InvalidUrl,
    InvalidMethod,
    HeadersTooLarge,
    BodyTooLarge,
    TooManyRedirects,
    RedirectLoopDetected,
    
    // Cancellation and timeout
    Canceled,
    DeadlineExceeded,
    
    // System errors
    OutOfMemory,
    SystemResources,
    PermissionDenied,
    
    // Other
    UnexpectedEndOfFile,
    InvalidData,
    UnsupportedFeature,
};

/// Context information for errors
pub const ErrorContext = struct {
    /// Optional error code from the underlying system
    system_code: ?i32 = null,
    /// Optional message providing more context
    message: ?[]const u8 = null,
    /// Optional URL that caused the error
    url: ?[]const u8 = null,
    /// Optional HTTP status code if available
    status_code: ?u16 = null,
    
    pub fn init() ErrorContext {
        return ErrorContext{};
    }
    
    pub fn withMessage(self: ErrorContext, msg: []const u8) ErrorContext {
        var ctx = self;
        ctx.message = msg;
        return ctx;
    }
    
    pub fn withUrl(self: ErrorContext, url: []const u8) ErrorContext {
        var ctx = self;
        ctx.url = url;
        return ctx;
    }
    
    pub fn withStatusCode(self: ErrorContext, code: u16) ErrorContext {
        var ctx = self;
        ctx.status_code = code;
        return ctx;
    }
};

test "error types" {
    const err: Error = Error.ConnectTimeout;
    try std.testing.expect(err == Error.ConnectTimeout);
}

test "error context" {
    const ctx = ErrorContext.init()
        .withMessage("Connection timed out")
        .withUrl("https://example.com");
        
    try std.testing.expect(ctx.message != null);
    try std.testing.expect(ctx.url != null);
    try std.testing.expectEqualStrings("Connection timed out", ctx.message.?);
    try std.testing.expectEqualStrings("https://example.com", ctx.url.?);
}