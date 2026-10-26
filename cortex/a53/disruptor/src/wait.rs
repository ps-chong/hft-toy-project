//! Spin-then-park waiting for producers and consumers on a Tokio runtime.
//!
//! A waiter spins briefly (the hand-off usually completes within a few
//! hundred nanoseconds), then parks on a `tokio::sync::Notify`. The other side
//! calls `notify_waiters` only when the waiter count is non-zero, so an
//! uncontended publish costs one fence and one relaxed load.

use std::sync::atomic::{AtomicUsize, Ordering, fence};

use tokio::sync::Notify;

/// How long to spin before parking.
#[derive(Clone, Copy, Debug)]
pub struct WaitStrategy {
    /// Busy-poll iterations before parking on the notifier.
    pub spins: u32,
}

impl Default for WaitStrategy {
    fn default() -> Self {
        Self { spins: 128 }
    }
}

#[derive(Default)]
pub(crate) struct Signals {
    data: Notify,
    data_waiters: AtomicUsize,
    space: Notify,
    space_waiters: AtomicUsize,
}

/// Decrements the waiter count even if the waiting future is dropped
/// (cancelled by `select!`), so the count never leaks.
struct WaiterGuard<'a>(&'a AtomicUsize);

impl Drop for WaiterGuard<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

impl Signals {
    pub(crate) fn wake_data(&self) {
        wake(&self.data, &self.data_waiters);
    }

    pub(crate) fn wake_space(&self) {
        wake(&self.space, &self.space_waiters);
    }

    pub(crate) async fn wait_for_data(&self, strategy: WaitStrategy, ready: impl Fn() -> bool) {
        wait(&self.data, &self.data_waiters, strategy, ready).await;
    }

    pub(crate) async fn wait_for_space(&self, strategy: WaitStrategy, ready: impl Fn() -> bool) {
        wait(&self.space, &self.space_waiters, strategy, ready).await;
    }
}

fn wake(notify: &Notify, waiters: &AtomicUsize) {
    // SeqCst fence: orders the caller's preceding release store (cursor or
    // sequence) before reading the waiter count. Paired with the waiter's
    // SeqCst increment-then-fence, at least one side sees the other.
    fence(Ordering::SeqCst);
    if waiters.load(Ordering::Relaxed) > 0 {
        notify.notify_waiters();
    }
}

async fn wait(
    notify: &Notify,
    waiters: &AtomicUsize,
    strategy: WaitStrategy,
    ready: impl Fn() -> bool,
) {
    for _ in 0..strategy.spins {
        if ready() {
            return;
        }
        std::hint::spin_loop();
    }
    loop {
        let notified = notify.notified();
        tokio::pin!(notified);
        // Register before re-checking, so a wake-up between the check and the
        // await is not lost.
        notified.as_mut().enable();
        waiters.fetch_add(1, Ordering::SeqCst);
        let _guard = WaiterGuard(waiters);
        fence(Ordering::SeqCst);
        if ready() {
            return;
        }
        notified.await;
        if ready() {
            return;
        }
    }
}
