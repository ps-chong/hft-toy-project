//! Batched `PostgreSQL` journal, kept off the latency-critical path.
//!
//! The journal task is the only caller, so no state here is shared between
//! tasks. `PgPool` is internally synchronized; [`AnyRepository`] picks the
//! backend by enum dispatch instead of a boxed trait object.

use std::future::Future;

use hft_analytics::LatencySummary;
use hft_protocol::{OrderIntent, Side};
use serde::{Deserialize, Serialize};
use sqlx::{PgPool, postgres::PgPoolOptions};
use thiserror::Error;
use uuid::Uuid;

/// Storage failures.
#[derive(Debug, Error)]
pub enum StorageError {
    /// Query or connection failure.
    #[error("database operation failed: {0}")]
    Database(#[from] sqlx::Error),
    /// Migration failure.
    #[error("database migration failed: {0}")]
    Migration(#[from] sqlx::migrate::MigrateError),
    /// A u64 value does not fit `BIGINT`.
    #[error("numeric value does not fit PostgreSQL BIGINT")]
    NumericRange,
}

/// Lifecycle step being journaled for an order.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum OrderEventType {
    /// Read from the R5 (journal's view of the intent ring).
    Received,
    /// Sent to the exchange.
    Sent,
    /// Withheld because trading was not permitted.
    Blocked,
    /// Accepted by the exchange.
    Accepted,
    /// Rejected by the exchange.
    Rejected,
    /// Executed.
    Executed,
    /// Cancelled.
    Canceled,
}

impl OrderEventType {
    /// Value stored in `order_events.event_type`.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Received => "received",
            Self::Sent => "sent",
            Self::Blocked => "blocked",
            Self::Accepted => "accepted",
            Self::Rejected => "rejected",
            Self::Executed => "executed",
            Self::Canceled => "canceled",
        }
    }
}

/// One journal row. `Copy`: nothing on the hot path allocates for it.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PersistedOrder {
    /// Daemon session that produced the row.
    pub session_id: Uuid,
    /// The intent concerned.
    pub intent: OrderIntent,
    /// Lifecycle step.
    pub event_type: OrderEventType,
}

/// Session metadata written once at start-up.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionInfo {
    /// Daemon session.
    pub session_id: Uuid,
    /// Exchange session name.
    pub feed_session: String,
    /// Build identifier.
    pub build_id: String,
    /// IPC ABI version.
    pub schema_version: i32,
}

/// Persistence operations the daemon needs.
pub trait Repository: Send + Sync {
    /// Records the session row that every order row references.
    fn open_session(
        &self,
        session: &SessionInfo,
    ) -> impl Future<Output = Result<(), StorageError>> + Send;
    /// Stores a batch of order rows in one statement.
    fn store_orders(
        &self,
        orders: &[PersistedOrder],
    ) -> impl Future<Output = Result<(), StorageError>> + Send;
    /// Stores one latency summary.
    fn store_latency(
        &self,
        session_id: Uuid,
        domain: &str,
        summary: LatencySummary,
    ) -> impl Future<Output = Result<(), StorageError>> + Send;
    /// Round-trips a trivial query.
    fn health(&self) -> impl Future<Output = Result<(), StorageError>> + Send;
}

/// `PostgreSQL` backend.
#[derive(Clone)]
pub struct PgRepository {
    pool: PgPool,
}

impl PgRepository {
    /// Connects and applies migrations.
    pub async fn connect(url: &str, max_connections: u32) -> Result<Self, StorageError> {
        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .connect(url)
            .await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Ok(Self { pool })
    }
}

fn as_i64(value: u64) -> Result<i64, StorageError> {
    i64::try_from(value).map_err(|_| StorageError::NumericRange)
}

fn side_code(side: Side) -> &'static str {
    match side {
        Side::Buy => "B",
        Side::Sell => "S",
        Side::Unknown => "?",
    }
}

/// Column-major view of a batch for one `UNNEST` insert.
#[derive(Default)]
struct OrderColumns {
    sessions: Vec<Uuid>,
    user_refs: Vec<i64>,
    sequences: Vec<i64>,
    event_types: Vec<&'static str>,
    sides: Vec<&'static str>,
    symbols: Vec<String>,
    prices: Vec<i64>,
    quantities: Vec<i64>,
    revisions: Vec<i32>,
}

impl OrderColumns {
    fn from_orders(orders: &[PersistedOrder]) -> Result<Self, StorageError> {
        let mut columns = Self::default();
        for order in orders {
            let intent = &order.intent;
            columns.sessions.push(order.session_id);
            columns.user_refs.push(i64::from(intent.user_ref));
            columns.sequences.push(as_i64(intent.source_sequence)?);
            columns.event_types.push(order.event_type.as_str());
            columns.sides.push(side_code(intent.side));
            columns
                .symbols
                .push(String::from_utf8_lossy(&intent.symbol).into_owned());
            columns.prices.push(as_i64(intent.price)?);
            columns.quantities.push(i64::from(intent.quantity));
            columns
                .revisions
                .push(i32::try_from(intent.risk_revision).map_err(|_| StorageError::NumericRange)?);
        }
        Ok(columns)
    }
}

impl Repository for PgRepository {
    async fn open_session(&self, session: &SessionInfo) -> Result<(), StorageError> {
        sqlx::query(
            "INSERT INTO sessions (id, feed_session, build_id, schema_version) \
             VALUES ($1, $2, $3, $4) ON CONFLICT (id) DO NOTHING",
        )
        .bind(session.session_id)
        .bind(&session.feed_session)
        .bind(&session.build_id)
        .bind(session.schema_version)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn store_orders(&self, orders: &[PersistedOrder]) -> Result<(), StorageError> {
        if orders.is_empty() {
            return Ok(());
        }
        let columns = OrderColumns::from_orders(orders)?;
        // One round trip per batch: PostgreSQL expands the arrays into rows.
        sqlx::query(
            "INSERT INTO order_events \
             (session_id, user_ref, source_sequence, event_type, side, symbol, \
              price, quantity, risk_revision) \
             SELECT * FROM UNNEST($1::uuid[], $2::bigint[], $3::bigint[], $4::text[], \
                                  $5::text[], $6::text[], $7::bigint[], $8::bigint[], \
                                  $9::integer[]) \
             ON CONFLICT DO NOTHING",
        )
        .bind(&columns.sessions)
        .bind(&columns.user_refs)
        .bind(&columns.sequences)
        .bind(&columns.event_types)
        .bind(&columns.sides)
        .bind(&columns.symbols)
        .bind(&columns.prices)
        .bind(&columns.quantities)
        .bind(&columns.revisions)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn store_latency(
        &self,
        session_id: Uuid,
        domain: &str,
        summary: LatencySummary,
    ) -> Result<(), StorageError> {
        sqlx::query(
            "INSERT INTO latency_summaries \
             (session_id, domain, samples, minimum_ns, p50_ns, p99_ns, p999_ns, maximum_ns) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
        )
        .bind(session_id)
        .bind(domain)
        .bind(as_i64(summary.samples)?)
        .bind(as_i64(summary.minimum_ns)?)
        .bind(as_i64(summary.p50_ns)?)
        .bind(as_i64(summary.p99_ns)?)
        .bind(as_i64(summary.p999_ns)?)
        .bind(as_i64(summary.maximum_ns)?)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn health(&self) -> Result<(), StorageError> {
        sqlx::query("SELECT 1").execute(&self.pool).await?;
        Ok(())
    }
}

/// Backend that discards everything (no `DATABASE_URL`).
#[derive(Clone, Copy, Debug, Default)]
pub struct NullRepository;

impl Repository for NullRepository {
    async fn open_session(&self, _session: &SessionInfo) -> Result<(), StorageError> {
        Ok(())
    }

    async fn store_orders(&self, _orders: &[PersistedOrder]) -> Result<(), StorageError> {
        Ok(())
    }

    async fn store_latency(
        &self,
        _session_id: Uuid,
        _domain: &str,
        _summary: LatencySummary,
    ) -> Result<(), StorageError> {
        Ok(())
    }

    async fn health(&self) -> Result<(), StorageError> {
        Ok(())
    }
}

/// Backend chosen at start-up, dispatched by `match` instead of a vtable.
#[derive(Clone)]
pub enum AnyRepository {
    /// `PostgreSQL`.
    Pg(PgRepository),
    /// Discard.
    Null(NullRepository),
}

impl Repository for AnyRepository {
    async fn open_session(&self, session: &SessionInfo) -> Result<(), StorageError> {
        match self {
            Self::Pg(repository) => repository.open_session(session).await,
            Self::Null(repository) => repository.open_session(session).await,
        }
    }

    async fn store_orders(&self, orders: &[PersistedOrder]) -> Result<(), StorageError> {
        match self {
            Self::Pg(repository) => repository.store_orders(orders).await,
            Self::Null(repository) => repository.store_orders(orders).await,
        }
    }

    async fn store_latency(
        &self,
        session_id: Uuid,
        domain: &str,
        summary: LatencySummary,
    ) -> Result<(), StorageError> {
        match self {
            Self::Pg(repository) => repository.store_latency(session_id, domain, summary).await,
            Self::Null(repository) => repository.store_latency(session_id, domain, summary).await,
        }
    }

    async fn health(&self) -> Result<(), StorageError> {
        match self {
            Self::Pg(repository) => repository.health().await,
            Self::Null(repository) => repository.health().await,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn null_repository_accepts_everything() {
        let repository = AnyRepository::Null(NullRepository);
        let order = PersistedOrder {
            session_id: Uuid::nil(),
            intent: OrderIntent::default(),
            event_type: OrderEventType::Sent,
        };
        assert!(repository.store_orders(&[order; 3]).await.is_ok());
        assert!(repository.health().await.is_ok());
    }

    #[test]
    fn batches_become_typed_columns() {
        let order = PersistedOrder {
            session_id: Uuid::nil(),
            intent: OrderIntent {
                user_ref: 9,
                side: Side::Sell,
                symbol: *b"ACME    ",
                price: 5,
                ..OrderIntent::default()
            },
            event_type: OrderEventType::Accepted,
        };
        let columns = OrderColumns::from_orders(&[order, order]).unwrap();
        assert_eq!(columns.user_refs, [9, 9]);
        assert_eq!(columns.event_types, ["accepted", "accepted"]);
        assert_eq!(columns.sides, ["S", "S"]);
        assert_eq!(columns.symbols[0], "ACME    ");
    }

    #[test]
    fn rejects_values_outside_bigint() {
        let order = PersistedOrder {
            session_id: Uuid::nil(),
            intent: OrderIntent {
                price: u64::MAX,
                ..OrderIntent::default()
            },
            event_type: OrderEventType::Sent,
        };
        assert!(matches!(
            OrderColumns::from_orders(&[order]),
            Err(StorageError::NumericRange)
        ));
    }

    /// Runs against the CI PostgreSQL service when `DATABASE_URL` is set.
    #[tokio::test]
    async fn postgres_round_trip_when_available() {
        let Some(url) = std::env::var("DATABASE_URL")
            .ok()
            .filter(|url| !url.is_empty())
        else {
            return;
        };
        let repository = PgRepository::connect(&url, 1).await.unwrap();
        let session = SessionInfo {
            session_id: Uuid::new_v4(),
            feed_session: "TESTSESS01".to_owned(),
            build_id: "test".to_owned(),
            schema_version: 2,
        };
        repository.open_session(&session).await.unwrap();
        let order = PersistedOrder {
            session_id: session.session_id,
            intent: OrderIntent {
                user_ref: 1,
                side: Side::Buy,
                ..OrderIntent::default()
            },
            event_type: OrderEventType::Sent,
        };
        repository.store_orders(&[order]).await.unwrap();
        repository.health().await.unwrap();
    }
}
