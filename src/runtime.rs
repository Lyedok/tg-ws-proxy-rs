use std::collections::HashMap;
use std::sync::Mutex as StdMutex;
use std::time::{Duration, Instant};

use crate::config::{default_dc_ips, default_dc_overrides};
use crate::outbound::OutboundConnector;

pub struct Runtime {
    outbound: OutboundConnector,
    dc_overrides: HashMap<u32, u32>,
    dc_fallback_ips: HashMap<u32, String>,
    /// Domain-fronting SNI, when enabled via `--fronting-domain`. `None` means
    /// the fallback is disabled entirely (the default).
    fronting_domain: Option<String>,
    /// How long the fronting fallback stays "sticky" after last succeeding.
    fronting_cooldown: Duration,
    /// Shared with `pool.rs`'s background refill (unlike the per-DC cooldowns
    /// in `proxy.rs`, which only that module's own fallback logic needs),
    /// which is why this lives on `Runtime` instead of a `proxy.rs` static.
    fronting_until: StdMutex<Option<Instant>>,
}

impl Runtime {
    pub fn new(outbound: OutboundConnector) -> Self {
        Self {
            outbound,
            dc_overrides: default_dc_overrides(),
            dc_fallback_ips: default_dc_ips(),
            fronting_domain: None,
            fronting_cooldown: Duration::from_secs(1800),
            fronting_until: StdMutex::new(None),
        }
    }

    /// Configure the domain-fronting fallback. `domain: None` keeps it disabled.
    pub fn with_fronting(mut self, domain: Option<String>, cooldown: Duration) -> Self {
        self.fronting_domain = domain;
        self.fronting_cooldown = cooldown;
        self
    }

    pub fn outbound(&self) -> &OutboundConnector {
        &self.outbound
    }

    pub fn websocket_dc(&self, dc: u32) -> u32 {
        *self.dc_overrides.get(&dc).unwrap_or(&dc)
    }

    pub fn fallback_ip(&self, dc: u32) -> Option<&str> {
        self.dc_fallback_ips.get(&dc).map(String::as_str)
    }

    /// The configured fronting SNI, if the fallback is enabled.
    pub fn fronting_domain(&self) -> Option<&str> {
        self.fronting_domain.as_deref()
    }

    /// Whether the fronting fallback is currently in its sticky window.
    pub fn fronting_active(&self) -> bool {
        matches!(*self.fronting_until.lock().unwrap(), Some(until) if Instant::now() < until)
    }

    /// Mark the fronting fallback as active for another `fronting_cooldown`
    /// from now (called after a successful fronted connection).
    pub fn activate_fronting(&self) {
        *self.fronting_until.lock().unwrap() = Some(Instant::now() + self.fronting_cooldown);
    }

    /// Clear the sticky window (called after a fronted connection fails).
    pub fn deactivate_fronting(&self) {
        *self.fronting_until.lock().unwrap() = None;
    }
}
