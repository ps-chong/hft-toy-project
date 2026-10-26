//! Typed control-plane protocol shared by `hftd`, `hftctl`, and the
//! dashboard: one JSON object per line over the local Unix socket.

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{RiskConfigRecord, generated};

/// Number of strategies the R5 implements (see `hft/strategy.hpp`).
pub const STRATEGY_COUNT: u8 = 2;

/// Operator-visible risk and trading state. The control actor owns the only
/// mutable copy; everything else receives snapshots.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ControlSnapshot {
    /// Trading permitted by the operator.
    pub armed: bool,
    /// Operator kill (fail-closed default).
    pub killed: bool,
    /// Maximum shares per order.
    pub max_quantity: u32,
    /// Lowest accepted price.
    pub price_floor: u64,
    /// Highest accepted price.
    pub price_ceiling: u64,
    /// Strictly increasing; bumped by every accepted command.
    pub revision: u32,
    /// Active R5 strategy.
    #[serde(default)]
    pub strategy_id: u8,
    /// Set only by `arm`: asks the R5 to clear latched automatic kills.
    #[serde(default)]
    pub clear_faults: bool,
}

impl Default for ControlSnapshot {
    fn default() -> Self {
        Self {
            armed: false,
            killed: true,
            max_quantity: 1_000,
            price_floor: 1,
            price_ceiling: 1_000_000_000,
            revision: 1,
            strategy_id: 0,
            clear_faults: false,
        }
    }
}

impl ControlSnapshot {
    /// Builds the A53 -> R5 `risk_config` record for this snapshot.
    #[must_use]
    pub fn to_record(&self) -> RiskConfigRecord {
        use generated::ipc::risk_config_flags as flag;
        let mut flags = 0;
        if self.armed {
            flags |= flag::ARMED;
        }
        if self.killed {
            flags |= flag::KILL;
        }
        if self.clear_faults {
            flags |= flag::CLEAR_KILL;
        }
        RiskConfigRecord {
            flags,
            revision: self.revision,
            max_quantity: self.max_quantity,
            max_orders_per_window: 1_000,
            price_floor: self.price_floor,
            price_ceiling: self.price_ceiling,
            rate_window_ns: 1_000_000_000,
            max_open_orders: 1_024,
            strategy_id: self.strategy_id,
            ..RiskConfigRecord::default()
        }
    }

    /// True when the A53 may forward intents to the exchange.
    #[must_use]
    pub fn trading_permitted(&self) -> bool {
        self.armed && !self.killed
    }
}

/// One operator request.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "command", rename_all = "kebab-case")]
pub enum ControlCommand {
    /// Report the current snapshot.
    Status,
    /// Report counters.
    Counters,
    /// Permit trading and clear latched faults.
    Arm,
    /// Stop trading immediately.
    Kill,
    /// Replace the risk limits.
    SetRisk {
        /// Maximum shares per order.
        max_quantity: u32,
        /// Lowest accepted price.
        price_floor: u64,
        /// Highest accepted price.
        price_ceiling: u64,
    },
    /// Select the R5 strategy.
    SelectStrategy {
        /// Strategy index.
        strategy_id: u8,
    },
}

/// Why a command was refused.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Error, Serialize, Deserialize)]
pub enum ControlError {
    /// `price_floor` exceeds `price_ceiling`.
    #[error("price floor exceeds ceiling")]
    InvalidCollar,
    /// A zero quantity limit would reject every order.
    #[error("max_quantity must be positive")]
    InvalidQuantity,
    /// The strategy index is out of range.
    #[error("unknown strategy")]
    UnknownStrategy,
    /// The revision counter is exhausted.
    #[error("revision counter exhausted")]
    RevisionExhausted,
}

impl ControlCommand {
    /// Applies the command to `state`. Returns `Ok(true)` when the state
    /// changed (and its revision was bumped); read-only commands return
    /// `Ok(false)`. A refused command leaves `state` untouched.
    pub fn apply(&self, state: &mut ControlSnapshot) -> Result<bool, ControlError> {
        let mut next = *state;
        next.clear_faults = false;
        match *self {
            Self::Status | Self::Counters => return Ok(false),
            Self::Arm => {
                next.armed = true;
                next.killed = false;
                next.clear_faults = true;
            }
            Self::Kill => next.killed = true,
            Self::SetRisk {
                max_quantity,
                price_floor,
                price_ceiling,
            } => {
                if max_quantity == 0 {
                    return Err(ControlError::InvalidQuantity);
                }
                if price_floor > price_ceiling {
                    return Err(ControlError::InvalidCollar);
                }
                next.max_quantity = max_quantity;
                next.price_floor = price_floor;
                next.price_ceiling = price_ceiling;
            }
            Self::SelectStrategy { strategy_id } => {
                if strategy_id >= STRATEGY_COUNT {
                    return Err(ControlError::UnknownStrategy);
                }
                next.strategy_id = strategy_id;
            }
        }
        next.revision = state
            .revision
            .checked_add(1)
            .ok_or(ControlError::RevisionExhausted)?;
        *state = next;
        Ok(true)
    }
}

/// Daemon counters reported by `counters` and `status`.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
pub struct DaemonCounters {
    /// Intents read from the R5.
    pub intents_received: u64,
    /// Intents sent to the exchange.
    pub intents_sent: u64,
    /// Intents withheld because trading was not permitted.
    pub intents_blocked: u64,
    /// Exchange acceptances.
    pub accepted: u64,
    /// Exchange rejections.
    pub rejected: u64,
    /// Client heartbeats sent.
    pub heartbeats_sent: u64,
    /// Journal records lost to lapping or a full storage queue.
    pub journal_dropped: u64,
    /// Risk configurations sent to the R5.
    pub configs_sent: u64,
    /// Median intent-to-acknowledgement latency.
    pub intent_to_ack_p50_ns: u64,
    /// 99th percentile intent-to-acknowledgement latency.
    pub intent_to_ack_p99_ns: u64,
}

/// Reply to one [`ControlCommand`].
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ControlResponse {
    /// Whether the command was accepted.
    pub ok: bool,
    /// Current snapshot.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<ControlSnapshot>,
    /// Current counters.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub counters: Option<DaemonCounters>,
    /// Refusal reason.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl ControlResponse {
    /// Successful reply.
    #[must_use]
    pub fn ok(state: ControlSnapshot, counters: DaemonCounters) -> Self {
        Self {
            ok: true,
            state: Some(state),
            counters: Some(counters),
            error: None,
        }
    }

    /// Refusal.
    #[must_use]
    pub fn error(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            state: None,
            counters: None,
            error: Some(message.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn applies_fail_closed_transitions() {
        let mut state = ControlSnapshot::default();
        assert_eq!(ControlCommand::Arm.apply(&mut state), Ok(true));
        assert!(state.trading_permitted());
        assert!(state.clear_faults);
        assert_eq!(ControlCommand::Kill.apply(&mut state), Ok(true));
        assert!(!state.trading_permitted());
        assert!(!state.clear_faults, "only arm requests a fault clear");
        assert_eq!(state.revision, 3);
        assert_eq!(ControlCommand::Status.apply(&mut state), Ok(false));
        assert_eq!(state.revision, 3);
    }

    #[test]
    fn refused_commands_leave_state_untouched() {
        let mut state = ControlSnapshot::default();
        let before = state;
        let command = ControlCommand::SetRisk {
            max_quantity: 10,
            price_floor: 100,
            price_ceiling: 90,
        };
        assert_eq!(command.apply(&mut state), Err(ControlError::InvalidCollar));
        assert_eq!(state, before);
        let strategy = ControlCommand::SelectStrategy { strategy_id: 9 };
        assert_eq!(
            strategy.apply(&mut state),
            Err(ControlError::UnknownStrategy)
        );
    }

    #[test]
    fn json_wire_format_is_stable() {
        let command: ControlCommand = serde_json::from_str(
            r#"{"command":"set-risk","max_quantity":5,"price_floor":1,"price_ceiling":9}"#,
        )
        .unwrap_or(ControlCommand::Status);
        assert_eq!(
            command,
            ControlCommand::SetRisk {
                max_quantity: 5,
                price_floor: 1,
                price_ceiling: 9
            }
        );
        let encoded = serde_json::to_string(&ControlCommand::SelectStrategy { strategy_id: 1 })
            .unwrap_or_default();
        assert_eq!(encoded, r#"{"command":"select-strategy","strategy_id":1}"#);
    }

    #[test]
    fn record_flags_follow_the_schema() {
        let mut state = ControlSnapshot::default();
        assert_eq!(ControlCommand::Arm.apply(&mut state), Ok(true));
        let record = state.to_record();
        assert_eq!(
            record.flags,
            generated::ipc::risk_config_flags::ARMED
                | generated::ipc::risk_config_flags::CLEAR_KILL
        );
        assert_eq!(record.revision, 2);
        assert_eq!(record.abi_version, generated::ABI_VERSION);
    }
}
