//! Atomics used by the ring, switched to `loom`'s model-checked versions
//! under `--cfg loom`.

#[cfg(loom)]
pub(crate) use loom::sync::Arc;
#[cfg(loom)]
pub(crate) use loom::sync::atomic::{AtomicU64, Ordering, fence};

#[cfg(not(loom))]
pub(crate) use std::sync::Arc;
#[cfg(not(loom))]
pub(crate) use std::sync::atomic::{AtomicU64, Ordering, fence};
