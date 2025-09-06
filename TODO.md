  Immediate priorities:

  1. Fix Response memory management - The Response/Body system needs proper ownership semantics to
  avoid memory leaks. This means adding a proper deinit() that frees owned strings and body data.
  2. Connection pooling - The releaseConnection method currently just destroys connections. Should
  implement proper connection reuse for keep-alive.
  3. Better error handling - Currently missing proper timeout handling, connection retries, and error
   recovery.

  Feature additions:

  4. Chunked transfer encoding - The readChunkedBodyFromConnection is just a stub that reads until
  close.
  5. Redirect following - The sendWithRedirects method has the structure but needs actual redirect
  logic.
  6. Request body streaming - Currently only supports static body content, not streaming uploads.
  7. HTTP/2 support - The architecture is ready with engine_h2 flag but needs implementation.
  8. Compression - gzip/brotli support (flags exist but not implemented).

  Quick wins:

  9. Add common convenience methods - GET, POST, PUT, DELETE helper methods on the Client.
  10. Better request building - Fluent API for building requests with headers, query params, etc.

  Which would you like to tackle? The Response memory management would clean up those leaks, or we
  could add some useful features like proper redirect following or chunked encoding.
