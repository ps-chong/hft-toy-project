//! Batched PostgreSQL persistence outside the latency-critical path.

use async_trait::async_trait;
use hft_analytics::LatencySummary;
use hft_protocol::OrderIntent;
use serde::{Deserialize, Serialize};
use sqlx::{PgPool, postgres::PgPoolOptions};
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum StorageError {
    #[error("database operation failed: {0}")]
    Database(#[from] sqlx::Error),
    #[error("numeric value does not fit PostgreSQL BIGINT")]
    NumericRange,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PersistedOrder {
    pub session_id: Uuid,
    pub intent: OrderIntent,
    pub event_type: String,
}

#[cfg_attr(test, mockall::automock)]
#[async_trait]
pub trait Repository: Send + Sync {
    async fn store_order(&self, order: &PersistedOrder) -> Result<(), StorageError>;
    async fn store_latency(
        &self,
        session_id: Uuid,
        domain: &str,
        summary: LatencySummary,
    ) -> Result<(), StorageError>;
    async fn health(&self) -> Result<(), StorageError>;
}

pub struct PgRepository {
    pool: PgPool,
}

impl PgRepository {
    pub async fn connect(url: &str, max_connections: u32) -> Result<Self, StorageError> {
        let pool = PgPoolOptions::new()
            .max_connections(max_connections)
            .connect(url)
            .await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Ok(Self { pool })
    }
}

#[derive(Default)]
pub struct NullRepository;

#[async_trait]
impl Repository for NullRepository {
    async fn store_order(&self, _order: &PersistedOrder) -> Result<(), StorageError> {
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

#[async_trait]
impl Repository for PgRepository {
    async fn store_order(&self, order: &PersistedOrder) -> Result<(), StorageError> {
        let source_sequence = i64::try_from(order.intent.source_sequence)
            .map_err(|_| StorageError::NumericRange)?;
        let price =
            i64::try_from(order.intent.price).map_err(|_| StorageError::NumericRange)?;
        sqlx::query(
            "INSERT INTO order_events \
             (session_id, user_ref, source_sequence, event_type, side, symbol, \
              price, quantity, risk_revision) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
        )
        .bind(order.session_id)
        .bind(i64::from(order.intent.user_ref))
        .bind(source_sequence)
        .bind(&order.event_type)
        .bind(char::from(order.intent.side as u8).to_string())
        .bind(String::from_utf8_lossy(&order.intent.symbol).into_owned())
        .bind(price)
        .bind(i64::from(order.intent.quantity))
        .bind(i32::try_from(order.intent.risk_revision).map_err(|_| StorageError::NumericRange)?)
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
             (session_id, domain, samples, minimum_ns, p50_ns, p99_ns, \
              p999_ns, maximum_ns) \
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

fn as_i64(value: u64) -> Result<i64, StorageError> {
    i64::try_from(value).map_err(|_| StorageError::NumericRange)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn mockall_repository_is_a_nonblocking_test_seam() {
        let mut repository = MockRepository::new();
        repository.expect_health().once().returning(|| Ok(()));
        assert!(repository.health().await.is_ok());
    }
}
