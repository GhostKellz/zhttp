# TODO — zhttp: HTTP/1·2·3 Client Library for Zig 0.16 with zsync Async

> **Objective**: Build a production‑quality HTTP client library for Zig **0.16+** supporting **HTTP/1.1**, **HTTP/2**, and **HTTP/3**, with a unified public API and optional **async runtime via `zsync`** ([https://github.com/ghostkellz/zsync](https://github.com/ghostkellz/zsync)). The library must be portable, secure-by-default, and suitable for CLI tools, services, and embedded use.

---

## 0) Principles & Targets

* **Single public API** that abstracts protocol version; engine chosen via ALPN & policy.
* **Zig 0.16+ only**; fail fast at compile time if lower.
* **Security-first** defaults: TLS verify on, SNI, sane ciphers, HTTP/2 & 3 mitigation knobs.
* **Zero globals**; explicit `Client` and allocators everywhere.
* **Blocking core** with **optional zsync-based async** adapter; no forced runtime.
* **Small deps**; pure Zig where practical; minimal, optional bindings for QUIC.

---

## 1) Public API (v0.1)

### 1.1 Types

* `Client` — connection pooling, engine selection, retries, redirects.
* `ClientOptions` — timeouts, limits, TLS, proxy, feature toggles.
* `Request` — method, url, headers, body (bytes | reader | file), per‑request timeout.
* `Response` — status, headers, `body_reader`, helpers (`readAll`, `json(T)`, `text`).
* `Header` — name/value; case-preserving on output, case-insensitive lookup; validated per RFC.
* `Body` — variants: `None`, `Bytes`, `Reader`, `File`, `Multipart` (streaming).

### 1.2 Builders

* `RequestBuilder` with `.method() .url() .header() .query() .json() .form() .timeout()`.
* Convenience helpers: `get(url)`, `post(url, bytes)`, `download(url, file)`.

### 1.3 Async Adapter (optional)

* `AsyncClient` using `zsync` executor.
* `sendTask(req) -> zsync.Task(Response)`; cancellation & timeouts integrated.
* `joinAll` helpers for concurrent requests.

### 1.4 Errors & Results

* Structured error enum: `ConnectTimeout`, `ReadTimeout`, `WriteTimeout`, `TlsError`, `DnsError`, `ProtocolError`, `Canceled`, `TooManyRedirects`, `BodyTooLarge`, `CertPinFail`, `H2GoAway`, `H3TransportError`, etc.
* Response status & headers always available when applicable (even on early body failure).

---

## 2) Engines & ALPN Selection

### 2.1 Engine Interface (internal)

* `EngineCtx` vtable: `init()`, `request()`, `close()`, optional `drain()`.
* Engines: `h1`, `h2`, `h3` modules; share common codecs for headers/media types.

### 2.2 ALPN & Scheme

* `https://` TLS handshake advertises `['h3','h2','http/1.1']` (configurable order).
* Negotiated protocol selects engine; fallback order if ALPN unsupported.
* `http://` uses h1; defer `h2c` upgrade (later milestone).

### 2.3 Feature Flags

* Build flags: `-Dengine_h1=true`, `-Dengine_h2=true`, `-Dengine_h3=true`, `-Dasync=true`.
* Runtime toggles in `ClientOptions` to disable certain engines per policy.

---

## 3) TLS & Trust

* Wrap std TLS; configure SNI, verify chain & hostname; session reuse.
* Trust stores: system roots by default; custom CA file/bytes supported.
* ALPN list from `ClientOptions`.
* Certificate pinning: SPKI SHA‑256 list; hard fail on mismatch.
* Settings for min TLS version, cipher suites (sane defaults), HTTP/2 & 3 settings.

**Tasks**:

* [ ] TLS context builder & cache.
* [ ] System trust loader (platform‑specific hooks).
* [ ] Pinning validator.
* [ ] ALPN integration for h2/h3.

---

## 4) Connection Pooling & Limits

* Per `(scheme, host, port, engine)` pool.
* LRU eviction; max conns per host; idle timeout; total cap.
* H1: one in‑flight per connection; open more as needed.
* H2/H3: multiplex streams; track `SETTINGS_MAX_CONCURRENT_STREAMS` (h2) and transport caps (h3).
* Backpressure queue + fairness across hosts.

**Tasks**:

* [ ] Pool datastructures; lock strategy; allocator strategy.
* [ ] Idle reaper task; pings for h2; keep‑alive for h1.
* [ ] Connection health checks; retry on reuse failure.

---

## 5) HTTP/1.1 Engine

* Parser/serializer: start line, headers, chunked encoding; content-length; EOF semantics.
* Keep‑alive & connection reuse; `Expect: 100-continue` handling.
* Proxy support: HTTP CONNECT & basic auth.
* Optional decompression (gzip/deflate/br) via adapters (pluggable to keep core small).

**Tasks**:

* [ ] Request encode + header canonicalization.
* [ ] Response parse + chunked reader; trailers.
* [ ] 100-continue; early hints (103) optional.
* [ ] Proxy CONNECT tunnel.
* [ ] Benchmarks, fuzzing parser.

---

## 6) HTTP/2 Engine

* TLS+ALPN `h2`; SETTINGS exchange; HPACK (dynamic & static tables).
* Multiplexing (streams), flow control (conn + stream windows), PRIORITY (nice‑to‑have).
* PING, GOAWAY, RST\_STREAM; graceful shutdown.
* Header validation & size limits to prevent abuse.

**Tasks**:

* [ ] Framer (binary frames) + state machine.
* [ ] HPACK encoder/decoder with bounded tables.
* [ ] Flow‑control accounting & backpressure.
* [ ] Stream lifecycle & error propagation.
* [ ] GOAWAY handling with retries at app layer.

---

## 7) HTTP/3 Engine (QUIC)

* QUIC transport via optional backend (pick one; make pluggable):

  * **msquic** (C lib; permissive; high quality) or
  * **quiche** (Cloudflare; C/Rust; ALPN/QPACK support).
* QPACK header compression; stream mux; 0‑RTT (off by default), connection migration optional.
* Path MTU, loss recovery, anti‑amplification; idle timeout.

**Tasks**:

* [ ] Backend adapter interface & build flags.
* [ ] QPACK encoder/decoder (or backend‑provided bindings).
* [ ] Connection/stream mgmt; version negotiation.
* [ ] Retry & fallback when QUIC blocked (UDP filtered) → h2/h1.

---

## 8) Middleware & Policies

* Redirects: RFC 7231/9110 compliance; limit hops; cross‑scheme policy.
* Retries: idempotent verbs only; backoff + jitter; budget per request.
* Cookie jar: optional; in‑memory store; domain/path rules.
* Decompression: negotiate `Accept‑Encoding`; stream decode when enabled.
* Auth helpers: Basic, Bearer; pluggable signers.

**Tasks**:

* [ ] Redirect policy impl + tests.
* [ ] Retry policy with per‑request override.
* [ ] Cookie jar (optional module) + policies.

---

## 9) Bodies & Streaming

* Request bodies: bytes, reader stream, file stream; chunked (h1) or known length.
* Response bodies: streaming reader; `readAll` helper; max size guard.
* Multipart/form‑data builder (streaming, boundary auto‑gen); file part support.

**Tasks**:

* [ ] Reader/Writer adaptors; content‑length auto compute if possible.
* [ ] Multipart builder; form urlencoded.
* [ ] Backpressure from network → body source.

---

## 10) Async Runtime via zsync (optional)

**Dependency**

```sh
# Add async runtime from main branch archive
zig fetch --save github.com/ghostkellz/zsync
```

Add to `build.zig.zon`:

```zig
.{
  .dependencies = .{
    .zsync = .{ .url = "https://github.com/ghostkellz/zsync/archive/refs/heads/main.tar.gz" },
  },
}
```

**Build flag**: `-Dasync=true` (default true; allow disable).

**Async API**

* `AsyncClient.init`, `.deinit`.
* `sendTask(req) -> zsync.Task(Response)`; `cancel()` support.
* `joinAll`, `map`, `timeout` helpers; executor integration samples.

**Tasks**:

* [ ] Adapter that runs blocking `Client.send` on zsync worker pool.
* [ ] zsync timers for connect/read/write timeouts and cancellation.
* [ ] Fair scheduling & per‑host concurrency caps.
* [ ] Tests: cancellation at all phases; leaks; stress 1k tasks.

---

## 11) Configuration & Flags

* Build‑time: `engine_h1/h2/h3`, `async`, `quic_backend=msquic|quiche|none`, `with_brotli`, `with_zlib`.
* Runtime: `ClientOptions` mirrors + limits; hostname & port overrides; proxy config.
* Env overrides (optional) for CLI use: `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`.

---

## 12) Diagnostics & Metrics

* Structured error types (section 1.4).
* Event hooks: connect start/end, TLS handshake, ALPN result, request start/finish, retries, redirects.
* Optional wire logging (headers only; redact secrets) with levels.
* Basic metrics counters: in‑flight, pool size, connect latency, TTFB, bytes sent/recv.

---

## 13) Testing Strategy

* Unit tests for header parsing, URL parsing, chunked encoding/decoding, HPACK/QPACK (when added).
* Integration tests against **httpbin**/local test server; golden cases for redirects/retries/cookies.
* Fuzz tests for parsers (h1 headers, h2 frames).
* Property tests: idempotent retry safety; flow control invariants (h2).
* QUIC tests via backend loopback if possible; UDP blocked fallback.
* Platform tests: Linux, macOS; CI matrix.

---

## 14) Benchmarks

* H1 single connection latency/throughput; 1k requests small payload; large download stream.
* H2 multiplexed streams; effect of flow control windows.
* H3 performance vs H2 on lossy links; handshake cost.
* Memory profile under load; no leaks.

---

## 15) Security Checklist

* TLS verification on; hostname check; min TLS version 1.2.
* Disable h2/h3 features that can be abused until hardened (e.g., PRIORITY optional).
* Reasonable header and body size limits; configurable.
* Strip hop‑by‑hop headers correctly.
* Redact Authorization/Cookie in logs.
* Cert pinning (opt‑in) with clear errors.

---

## 16) Examples & Docs

* `examples/get.zig`, `post_json.zig`, `download.zig`, `multipart_upload.zig`.
* `examples/async_concurrent.zig` using zsync executor.
* README: install, build flags, minimal usage, feature table, version support.
* API docs comments on all public types.

---

## 17) Packaging & CI

* `build.zig` exposes module `zhttp` and example binaries.
* `build.zig.zon` with `zsync` dep (async optional via flag).
* GitHub Actions: Zig 0.16 matrix; fmt, test, examples; optional sanitizer/leak checks.
* Release tags: `v0.1.0` (H1 stable; H2/H3 experimental behind flags), `v0.2` (H2 stable), `v0.3` (H3 beta).

---

## 18) Roadmap & Milestones

**M1 — H1 Core (blocking) + basic pool**

* [ ] Request/response, chunked, keep‑alive, redirects, timeouts.
* [ ] Minimal retry; JSON/text helpers; multipart builder.
* [ ] Docs + examples; unit/integration tests; initial benchmarks.

**M2 — zsync Async Adapter**

* [ ] AsyncClient + tasks; cancellation; timeouts; joinAll.
* [ ] Stress tests; metrics; wire logging.

**M3 — H2 Engine (alpha)**

* [ ] Frames, HPACK, streams, flow control; ALPN; GOAWAY handling.
* [ ] Integration tests; benchmarks; hardening.

**M4 — H2 Stable + Proxy Support**

* [ ] Prioritization optional; SETTINGS tuning; pooled reuse.

**M5 — H3 Engine (beta)**

* [ ] QUIC backend adapter (choose one); QPACK; fallback to H2/H1.
* [ ] UDP block detection; migration off.

**M6 — H3 Hardening + Docs**

* [ ] More tests; perf tuning; production notes.

---

## 19) Acceptance Criteria (v0.1)

* Zig 0.16 builds clean on Linux/macOS; no leaks under tests.
* H1 sync client passes integration tests (httpbin) incl. redirects/retries/multipart.
* Async adapter (zsync) runs 1k concurrent requests within memory budget; supports cancel.
* TLS verification on by default; ALPN negotiation present (h2/h3 flags may be off at v0.1).

---

## 20) Commands Cheatsheet

```sh
# Add dependency for async runtime (optional)
zig fetch --save github.com/ghostkellz/zsync

# Build & test
zig build test

# Build example
zig build install  # installs examples declared in build.zig

# Enable/disable engines & async at build time
zig build -Dengine_h1=true -Dengine_h2=true -Dengine_h3=true -Dasync=true
```

---

## 21) Naming & Module Import

* Package name: **zhttp** (short, descriptive). Alternative: **zttp** if preferred.
* Users import with `const zhttp = @import("zhttp");` after `zig fetch` & `zig build`.

---

**End of TODO** — start with **M1 (H1 core)** and keep H2/H3 behind flags until green. Async via **zsync** is optional but on by default for convenience.

