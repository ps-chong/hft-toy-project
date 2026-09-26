# Coding standards

## Library-first rule

Before introducing a helper, use an existing standard facility with the same
semantics. C++ code searches `std`, then the pinned Boost subset, then CIB.
Rust code searches `std`, then an already-approved focused crate. A wrapper is
acceptable only at a wire-format, MMIO, FreeRTOS/OpenAMP, FFI, error-translation,
or test boundary.

Project-specific replacements for `span`, `string_view`, `array`, `optional`,
`variant`, `expected`, algorithms, iterators, duration/time-point types, scope
guards, `Result`, `Option`, slices, `From`/`TryFrom`, or standard collections
are not accepted.

## Ownership and lifetime

- Prefer values, stack storage, and static storage.
- C++ dynamic ownership is `std::unique_ptr`; shared ownership needs a written
  justification and uses `std::shared_ptr` plus `std::weak_ptr` to break cycles.
- The R5 trading path performs no general-purpose allocation after startup.
  A dynamic target lifetime must use a fixed pool and a `unique_ptr` custom
  deleter.
- A raw C++ pointer is non-owning or isolated inside an MMIO/C API adapter.
- Rust uses borrowing by default, `Box<T>` for unique heap ownership, and
  `Arc<T>` only for genuinely cross-task shared ownership.
- Every acquired resource is held by an RAII/`Drop` type. Manual paired cleanup
  is confined to the implementation of that type.

## Error handling

R5 code is built without exceptions. Recoverable failures use `std::expected`
or a small error enum; an invariant failure latches the kill switch. Rust uses
typed `Result` values and preserves error sources. No error is discarded
without incrementing a named counter or emitting a rate-limited diagnostic.

## Concurrency

The latency path has one owner for each mutable state object. It uses bounded
SPSC queues and run-to-completion handlers, never a blocking mutex. Linux
services use actors and bounded channels. A noncritical lock must have a bounded
scope, cannot cross an async suspension, and must expose contention metrics.

## Generated and unsafe code

Generated files carry a “do not edit” header and are checked for drift. Each
Rust `unsafe` block and each C++ MMIO cast documents its safety invariant next
to the operation. Vendor/generated code is excluded from style checks but not
from integration tests.
