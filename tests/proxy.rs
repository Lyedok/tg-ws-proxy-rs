use std::time::Duration;

use clap::Parser;
use tokio::io::AsyncWriteExt;

use tg_ws_proxy_rs::config::Config;
use tg_ws_proxy_rs::crypto::{ProtoTag, generate_client_handshake};
use tg_ws_proxy_rs::faketls::{
    build_faketls_client_hello, drain_faketls_server_hello, sign_faketls_client_hello,
    write_tls_appdata,
};
use tg_ws_proxy_rs::proxy::split_mtproto_init_and_pending;

mod common;

use common::{
    await_proxy_handler, await_proxy_request, await_proxy_requests, rejecting_http_proxy,
    rejecting_http_proxy_requests, run_proxy_once, start_proxy_connection,
};

const SECRET: &str = "00112233445566778899aabbccddeeff";

// ─── Inbound handshake framing ───────────────────────────────────────────────

#[test]
fn split_mtproto_init_keeps_coalesced_appdata_payload() {
    // Some clients send the MTProto init and the first payload in the same TLS
    // AppData record; the listener must preserve the extra bytes.
    let mut data = Vec::new();
    data.extend(0u8..64);
    data.extend_from_slice(b"first payload bytes");

    let (handshake, pending) =
        split_mtproto_init_and_pending(&data).expect("coalesced init + payload");

    assert_eq!(handshake, core::array::from_fn(|i| i as u8));
    assert_eq!(pending, b"first payload bytes");
}

#[test]
fn split_mtproto_init_accepts_exactly_64_bytes() {
    // The normal case is exactly one 64-byte MTProto obfuscation init packet.
    let data: Vec<u8> = (0u8..64).collect();

    let (handshake, pending) = split_mtproto_init_and_pending(&data).expect("exact init");

    assert_eq!(handshake, core::array::from_fn(|i| i as u8));
    assert!(pending.is_empty());
}

#[test]
fn split_mtproto_init_rejects_short_input() {
    // Less than 64 bytes cannot be a complete MTProto obfuscation init.
    let data: Vec<u8> = (0u8..63).collect();

    assert!(split_mtproto_init_and_pending(&data).is_none());
    assert!(split_mtproto_init_and_pending(&[]).is_none());
}

// ─── Fallback chain ──────────────────────────────────────────────────────────

/// Build a serving (non-`--check`) config routed through `proxy_addr`, with
/// environment proxy discovery disabled so the host's own `HTTPS_PROXY` /
/// `NO_PROXY` cannot influence the test.
fn proxy_config(proxy_addr: &str, extra: &[&str]) -> Config {
    let mut args = vec![
        "tg-ws-proxy",
        "--secret",
        SECRET,
        "--outbound-proxy",
        proxy_addr,
        "--no-outbound-proxy",
        "--no-proxy",
        "",
        "--handshake-timeout",
        "2",
        "--cf-connect-timeout",
        "2",
        "--upstream-connect-timeout",
        "2",
        "--tcp-fallback-timeout",
        "2",
    ];
    args.extend_from_slice(extra);

    Config::try_parse_from(args).unwrap()
}

/// The `CONNECT` targets a fallback chain asked the outbound proxy for, in
/// order — the observable shape of the ladder.
fn connect_targets(requests: &[String]) -> Vec<&str> {
    requests
        .iter()
        .filter_map(|request| request.split_whitespace().nth(1))
        .collect()
}

#[tokio::test]
async fn proxy_upstream_fallback_uses_outbound_proxy() {
    let (proxy_addr, proxy_task) = rejecting_http_proxy_requests(2).await;
    let config = proxy_config(
        &format!("http://{proxy_addr}"),
        &["--mtproto-proxy", &format!("upstream.example:443:{SECRET}")],
    );

    run_proxy_once(config).await;

    let requests = await_proxy_requests(proxy_task).await;
    assert!(
        requests
            .iter()
            .any(|request| request.starts_with("CONNECT upstream.example:443 HTTP/1.1")),
        "expected upstream fallback CONNECT, got {requests:?}"
    );
}

#[tokio::test]
async fn proxy_tcp_fallback_uses_outbound_proxy() {
    let (proxy_addr, proxy_task) = rejecting_http_proxy().await;
    let config = proxy_config(&format!("http://{proxy_addr}"), &[]);

    run_proxy_once(config).await;

    // No --dc-ip and no CF/upstream tiers configured, so DC 2 falls straight
    // through to its built-in fallback IP.
    let request = await_proxy_request(proxy_task).await;
    assert!(request.starts_with("CONNECT 149.154.167.51:443 HTTP/1.1"));
}

#[tokio::test]
async fn cf_proxy_is_retried_fresh_on_every_connection_no_cooldown() {
    // Regression test for issue #81: a per-DC cooldown used to block *every*
    // CF domain for a DC after a single failed attempt, so with
    // --cf-balance/--default-domains (many domains) one flaky domain could
    // knock out CF entirely for --cf-fail-cooldown seconds, forcing every
    // connection in that window straight to the (often doomed) TCP fallback.
    // Upstream tg-ws-proxy's `_cfproxy_fallback` has no such cooldown at
    // all — every connection retries every configured domain fresh — so we
    // now match that. With one CF domain configured (2 domain variants:
    // kwsN and kwsN-1) and no --dc-ip/upstream-proxy, each of 2 separate
    // client connections should independently try both CF domain variants
    // before falling through to TCP: 3 CONNECTs per connection, 6 total.
    // The old cooldown-gated behavior would only produce 4 (connection 2
    // skips CF and goes straight to its single TCP-fallback attempt).
    let (proxy_addr, proxy_task) = rejecting_http_proxy_requests(6).await;
    let make_config = || {
        proxy_config(
            &format!("http://{proxy_addr}"),
            &["--cf-domain", "example.net"],
        )
    };

    run_proxy_once(make_config()).await;
    run_proxy_once(make_config()).await;

    let requests = await_proxy_requests(proxy_task).await;
    assert_eq!(
        requests.len(),
        6,
        "expected both connections to retry CF fresh (2 domains + TCP \
         fallback each), got {requests:?}"
    );
}

#[tokio::test]
async fn cf_worker_is_tried_before_the_cf_proxy() {
    // The Python fallback order for a DC without --dc-ip is Worker, then CF
    // proxy, then TCP: 1 + 2 + 1 = 4 CONNECTs.
    let (proxy_addr, proxy_task) = rejecting_http_proxy_requests(4).await;
    let config = proxy_config(
        &format!("http://{proxy_addr}"),
        &[
            "--cf-worker-domain",
            "worker.example.dev",
            "--cf-domain",
            "example.net",
        ],
    );

    run_proxy_once(config).await;

    let requests = await_proxy_requests(proxy_task).await;
    assert_eq!(
        connect_targets(&requests),
        [
            "worker.example.dev:443",
            "kws2.example.net:443",
            "kws2-1.example.net:443",
            "149.154.167.51:443",
        ]
    );
}

#[tokio::test]
async fn cf_priority_tries_the_cf_proxy_before_the_direct_websocket() {
    // With --dc-ip set the direct WS path is normally first; --cf-priority
    // flips that, and the CF tier is then not retried after WS also fails.
    let (proxy_addr, proxy_task) = rejecting_http_proxy_requests(5).await;
    let config = proxy_config(
        &format!("http://{proxy_addr}"),
        &[
            "--cf-priority",
            "--cf-domain",
            "example.net",
            "--dc-ip",
            "2:149.154.167.220",
            "--ws-connect-timeout",
            "2",
        ],
    );

    run_proxy_once(config).await;

    let requests = await_proxy_requests(proxy_task).await;
    assert_eq!(
        connect_targets(&requests),
        [
            // CF first, both records...
            "kws2.example.net:443",
            "kws2-1.example.net:443",
            // ...then the direct WS attempt on both Telegram hostnames...
            "149.154.167.220:443",
            "149.154.167.220:443",
            // ...and finally the TCP fallback. CF is not tried a second time.
            "149.154.167.51:443",
        ]
    );
}

#[tokio::test]
async fn a_client_with_the_wrong_secret_is_dropped_without_dialling_out() {
    let (proxy_addr, proxy_task) = rejecting_http_proxy().await;
    let config = proxy_config(&format!("http://{proxy_addr}"), &[]);

    let (mut client, handler) = start_proxy_connection(config).await;
    // A handshake generated with a different secret must not parse.
    let wrong_secret = hex::decode("ffeeddccbbaa99887766554433221100").unwrap();
    let (handshake, _, _) =
        generate_client_handshake(&wrong_secret, 2, ProtoTag::PaddedIntermediate);
    client.write_all(&handshake).await.unwrap();
    drop(client);

    await_proxy_handler(handler).await;

    // The scanner is drained silently: nothing was dialled outbound.
    assert!(
        tokio::time::timeout(Duration::from_millis(200), proxy_task)
            .await
            .is_err(),
        "a bad handshake must not trigger an outbound connection"
    );
}

#[tokio::test]
async fn inbound_faketls_handshake_is_accepted_and_routed() {
    let domain = "example.com";
    let (proxy_addr, proxy_task) = rejecting_http_proxy().await;
    let config = proxy_config(
        &format!("http://{proxy_addr}"),
        &["--listen-faketls-domain", domain],
    );
    let secret = config.secret_bytes();

    let (client, handler) = start_proxy_connection(config).await;
    let (mut reader, mut writer) = tokio::io::split(client);

    // Speak the client half of the FakeTLS camouflage: a signed ClientHello,
    // then the real MTProto init inside an Application Data record.
    let mut client_hello = build_faketls_client_hello(domain);
    sign_faketls_client_hello(&mut client_hello, &secret);
    writer.write_all(&client_hello).await.unwrap();

    assert!(
        drain_faketls_server_hello(&mut reader).await,
        "proxy did not answer with a valid FakeTLS ServerHello"
    );

    let (handshake, _, _) = generate_client_handshake(&secret, 2, ProtoTag::PaddedIntermediate);
    write_tls_appdata(&mut writer, &handshake).await.unwrap();
    drop(writer);
    drop(reader);

    await_proxy_handler(handler).await;

    // The camouflaged handshake was unwrapped and routed like any other.
    let request = await_proxy_request(proxy_task).await;
    assert!(request.starts_with("CONNECT 149.154.167.51:443 HTTP/1.1"));
}

#[tokio::test]
async fn inbound_faketls_rejects_a_client_hello_for_another_hostname() {
    let (proxy_addr, proxy_task) = rejecting_http_proxy().await;
    let config = proxy_config(
        &format!("http://{proxy_addr}"),
        &["--listen-faketls-domain", "example.com"],
    );
    let secret = config.secret_bytes();

    let (mut client, handler) = start_proxy_connection(config).await;

    let mut client_hello = build_faketls_client_hello("not-the-configured.example");
    sign_faketls_client_hello(&mut client_hello, &secret);
    client.write_all(&client_hello).await.unwrap();
    drop(client);

    await_proxy_handler(handler).await;

    assert!(
        tokio::time::timeout(Duration::from_millis(200), proxy_task)
            .await
            .is_err(),
        "an SNI mismatch must not trigger an outbound connection"
    );
}
