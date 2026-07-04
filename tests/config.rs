use clap::Parser;
use tg_ws_proxy_rs::config::Config;

#[test]
fn ee_secret_supplies_inbound_faketls_domain_and_key() {
    let key = "2a519e5be6c3219c69879e5fa2a0eab8";
    let domain = "www.yandex.ru";
    let secret = format!("ee{}{}", key, hex::encode(domain.as_bytes()));
    let cfg = Config::try_parse_from(["tg-ws-proxy", "--secret", &secret]).unwrap();

    assert_eq!(cfg.listen_faketls_domain().as_deref(), Some(domain));
    assert_eq!(cfg.secret_bytes(), hex::decode(key).unwrap());
    assert_eq!(cfg.link_secret(), secret);
}

#[test]
fn listen_faketls_domain_turns_plain_secret_into_ee_link() {
    let key = "2a519e5be6c3219c69879e5fa2a0eab8";
    let cfg = Config::try_parse_from([
        "tg-ws-proxy",
        "--secret",
        key,
        "--listen-faketls-domain",
        "www.yandex.ru",
    ])
    .unwrap();

    assert_eq!(cfg.secret_bytes(), hex::decode(key).unwrap());
    assert_eq!(
        cfg.link_secret(),
        format!("ee{}{}", key, hex::encode("www.yandex.ru"))
    );
}

#[test]
fn plain_secret_still_generates_dd_link() {
    let key = "2a519e5be6c3219c69879e5fa2a0eab8";
    let cfg = Config::try_parse_from(["tg-ws-proxy", "--secret", key]).unwrap();

    assert_eq!(cfg.listen_faketls_domain(), None);
    assert_eq!(cfg.link_secret(), format!("dd{}", key));
}

#[test]
fn multiple_secrets_are_parsed_and_primary_link_uses_first_secret() {
    let first = "11111111111111111111111111111111";
    let second = "22222222222222222222222222222222";
    let cfg =
        Config::try_parse_from(["tg-ws-proxy", "--secret", first, "--secret", second]).unwrap();

    assert_eq!(cfg.secrets, vec![first.to_string(), second.to_string()]);
    assert_eq!(cfg.secret_bytes(), hex::decode(first).unwrap());
    assert_eq!(
        cfg.secret_bytes_list(),
        vec![hex::decode(first).unwrap(), hex::decode(second).unwrap()]
    );
    assert_eq!(cfg.link_secret(), format!("dd{}", first));
}

#[test]
fn cf_worker_domain_accepts_python_alias_and_normalizes_url() {
    // The Python reference uses --cfproxy-worker-domain; keep that spelling
    // working while advertising the shorter Rust-style --cf-worker-domain.
    let cfg = Config::try_parse_from([
        "tg-ws-proxy",
        "--cfproxy-worker-domain",
        "https://example.user.workers.dev/apiws",
    ])
    .unwrap();

    assert_eq!(
        cfg.cf_worker_domain().as_deref(),
        Some("example.user.workers.dev")
    );
}

#[test]
fn cf_worker_domains_accept_multiple_values_and_normalize() {
    let cfg = Config::try_parse_from([
        "tg-ws-proxy",
        "--cf-worker-domain",
        "https://a.user.workers.dev/apiws,b.user.workers.dev/",
    ])
    .unwrap();

    assert_eq!(
        cfg.cf_worker_domains(),
        vec![
            "a.user.workers.dev".to_string(),
            "b.user.workers.dev".to_string()
        ]
    );
}

#[test]
fn default_host_binds_and_links_to_the_same_address() {
    // Regression test for https://github.com/valnesfjord/tg-ws-proxy-rs/issues/82:
    // without --host, the listener must bind to whatever address link_host()
    // advertises (or 127.0.0.1 if no LAN IP is detectable), never a mismatch
    // like binding 127.0.0.1 while advertising a LAN IP that isn't reachable.
    let cfg = Config::try_parse_from(["tg-ws-proxy"]).unwrap();

    let bind_host = cfg.bind_host();
    let link_host = cfg.link_host();

    if bind_host == "0.0.0.0" {
        // A LAN IP was detected: the link must show that concrete address,
        // and 0.0.0.0 actually listens on it (unlike 127.0.0.1 before this fix).
        assert_ne!(link_host, "0.0.0.0");
    } else {
        // No LAN connectivity: both must fall back to loopback consistently.
        assert_eq!(bind_host, "127.0.0.1");
        assert_eq!(link_host, "127.0.0.1");
    }
}

#[test]
fn explicit_host_is_respected_for_binding() {
    let cfg = Config::try_parse_from(["tg-ws-proxy", "--host", "127.0.0.1"]).unwrap();
    assert_eq!(cfg.bind_host(), "127.0.0.1");
}

#[test]
fn fronting_domain_is_disabled_by_default() {
    let cfg = Config::try_parse_from(["tg-ws-proxy"]).unwrap();

    assert_eq!(cfg.fronting_domain, None);
    assert_eq!(cfg.fronting_cooldown, 1800);
}

#[test]
fn fronting_flags_parse() {
    let cfg = Config::try_parse_from([
        "tg-ws-proxy",
        "--fronting-domain",
        "sprinthost.ru",
        "--fronting-cooldown",
        "60",
    ])
    .unwrap();

    assert_eq!(cfg.fronting_domain.as_deref(), Some("sprinthost.ru"));
    assert_eq!(cfg.fronting_cooldown, 60);
}

#[test]
fn cf_worker_domains_accept_repeated_flags_including_alias() {
    let cfg = Config::try_parse_from([
        "tg-ws-proxy",
        "--cf-worker-domain",
        "a.user.workers.dev",
        "--cfproxy-worker-domain",
        "b.user.workers.dev",
    ])
    .unwrap();

    assert_eq!(
        cfg.cf_worker_domains(),
        vec![
            "a.user.workers.dev".to_string(),
            "b.user.workers.dev".to_string()
        ]
    );
}
