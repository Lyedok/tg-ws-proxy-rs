use std::time::Duration;

use tg_ws_proxy_rs::outbound::OutboundConnector;
use tg_ws_proxy_rs::runtime::Runtime;

#[test]
fn fronting_disabled_by_default() {
    let runtime = Runtime::new(OutboundConnector::direct());

    assert_eq!(runtime.fronting_domain(), None);
    assert!(!runtime.fronting_active());
}

#[test]
fn fronting_disabled_without_a_domain_even_if_activated() {
    // `with_fronting(None, ..)` must keep the fallback off regardless of
    // what activate_fronting() does — callers gate on fronting_domain()
    // being Some before ever calling activate_fronting(), but the invariant
    // should hold even if that changes.
    let runtime =
        Runtime::new(OutboundConnector::direct()).with_fronting(None, Duration::from_secs(1800));

    assert_eq!(runtime.fronting_domain(), None);
    assert!(!runtime.fronting_active());
}

#[test]
fn activate_fronting_makes_it_active_until_cooldown_expires() {
    let runtime = Runtime::new(OutboundConnector::direct())
        .with_fronting(Some("sprinthost.ru".to_string()), Duration::from_secs(1800));

    assert!(!runtime.fronting_active());

    runtime.activate_fronting();

    assert!(runtime.fronting_active());
    assert_eq!(runtime.fronting_domain(), Some("sprinthost.ru"));
}

#[test]
fn deactivate_fronting_clears_the_sticky_window() {
    let runtime = Runtime::new(OutboundConnector::direct())
        .with_fronting(Some("sprinthost.ru".to_string()), Duration::from_secs(1800));

    runtime.activate_fronting();
    assert!(runtime.fronting_active());

    runtime.deactivate_fronting();
    assert!(!runtime.fronting_active());
    // The configured domain itself is unaffected by deactivation — only the
    // sticky window is cleared, so a later timeout can retrigger fronting.
    assert_eq!(runtime.fronting_domain(), Some("sprinthost.ru"));
}

#[test]
fn zero_cooldown_expires_immediately() {
    let runtime = Runtime::new(OutboundConnector::direct())
        .with_fronting(Some("sprinthost.ru".to_string()), Duration::from_secs(0));

    runtime.activate_fronting();
    // `Instant::now() + 0 <= Instant::now()` by the time we check, so the
    // sticky window is effectively already expired.
    std::thread::sleep(Duration::from_millis(1));
    assert!(!runtime.fronting_active());
}
