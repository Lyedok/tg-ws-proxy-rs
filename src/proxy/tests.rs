use super::*;

#[test]
fn balanced_rotates_the_starting_domain() {
    let counter = AtomicUsize::new(0);
    let workers = vec![
        "w1.example.workers.dev".to_string(),
        "w2.example.workers.dev".to_string(),
        "w3.example.workers.dev".to_string(),
    ];

    assert_eq!(
        balanced(&workers, &counter),
        ["w1", "w2", "w3"].map(|w| format!("{w}.example.workers.dev"))
    );
    assert_eq!(
        balanced(&workers, &counter),
        ["w2", "w3", "w1"].map(|w| format!("{w}.example.workers.dev"))
    );
    assert_eq!(
        balanced(&workers, &counter),
        ["w3", "w1", "w2"].map(|w| format!("{w}.example.workers.dev"))
    );
}

#[test]
fn balanced_leaves_short_lists_untouched() {
    let counter = AtomicUsize::new(0);
    let single = vec!["only.example".to_string()];

    assert_eq!(balanced(&[], &counter), Vec::<String>::new());
    assert_eq!(balanced(&single, &counter), single);
    // A list that cannot be rotated must not consume a counter tick either.
    assert_eq!(counter.load(Ordering::Relaxed), 0);
}

#[test]
fn balance_order_borrows_when_balancing_is_disabled() {
    let counter = AtomicUsize::new(0);
    let domains = vec!["a.example".to_string(), "b.example".to_string()];

    assert!(matches!(
        balance_order(&domains, false, &counter),
        Cow::Borrowed(_)
    ));
    assert!(matches!(
        balance_order(&domains, true, &counter),
        Cow::Owned(_)
    ));
}

#[test]
fn cooldown_is_tracked_per_key() {
    let cooldowns: CooldownMap<String> = CooldownMap::new();

    assert!(!cooldowns.active("w1.example.workers.dev"));

    cooldowns.set(
        "w1.example.workers.dev".to_string(),
        Duration::from_secs(60),
    );
    assert!(cooldowns.active("w1.example.workers.dev"));
    assert!(!cooldowns.active("w2.example.workers.dev"));

    cooldowns.clear("w1.example.workers.dev");
    assert!(!cooldowns.active("w1.example.workers.dev"));
}

#[test]
fn cooldown_expires_once_the_window_passes() {
    let cooldowns: CooldownMap<(u32, bool)> = CooldownMap::new();

    cooldowns.set((2, false), Duration::ZERO);

    assert!(!cooldowns.active(&(2, false)));
}

#[test]
fn cooldown_keys_include_the_media_flag() {
    let cooldowns: CooldownMap<(u32, bool)> = CooldownMap::new();

    cooldowns.set((2, false), Duration::from_secs(60));

    assert!(cooldowns.active(&(2, false)));
    // The media flag is part of the key — a non-media cooldown must not leak
    // into the media bucket for the same DC.
    assert!(!cooldowns.active(&(2, true)));
}

#[test]
fn upstream_key_joins_host_and_port() {
    assert_eq!(upstream_key("proxy.example", 443), "proxy.example:443");
}

#[test]
fn human_bytes_scales_through_the_units() {
    assert_eq!(human_bytes(0), "0.0B");
    assert_eq!(human_bytes(1023), "1023.0B");
    assert_eq!(human_bytes(1024), "1.0KB");
    assert_eq!(human_bytes(1024 * 1024), "1.0MB");
    assert_eq!(human_bytes(3 * 1024 * 1024 * 1024), "3.0GB");
}

#[tokio::test]
async fn an_aborted_direction_still_reports_the_bytes_it_moved() {
    // Regression test: the directions used to return their total, and
    // `join_bridge` cancels whichever one is still running — so the cancelled
    // side's count was lost and every session logged one direction as zero.
    let counters = Arc::new(BridgeCounters::default());

    let upload = tokio::spawn({
        let counters = Arc::clone(&counters);
        async move {
            counters.add_up(4096);
            // Finishes first, which is what triggers the abort below.
        }
    });

    let download = tokio::spawn({
        let counters = Arc::clone(&counters);
        async move {
            counters.add_down(1024);
            // Still running when the peer finishes, so this task is aborted
            // partway — exactly the case that used to lose the count.
            std::future::pending::<()>().await;
            counters.add_down(999_999);
        }
    });

    join_bridge(upload, download).await;

    assert_eq!(counters.totals(), (4096, 1024));
}

#[test]
fn bridge_counters_accumulate_across_many_chunks() {
    let counters = BridgeCounters::default();

    for _ in 0..10 {
        counters.add_up(100);
        counters.add_down(250);
    }

    assert_eq!(counters.totals(), (1000, 2500));
}
