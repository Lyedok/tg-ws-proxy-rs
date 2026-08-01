use std::sync::Arc;
use std::time::Duration;

use clap::Parser;

use tg_ws_proxy_rs::config::Config;
use tg_ws_proxy_rs::outbound::OutboundConnector;
use tg_ws_proxy_rs::pool::WsPool;
use tg_ws_proxy_rs::runtime::Runtime;

mod common;

use common::{await_proxy_requests, rejecting_http_proxy_requests};

fn pool_with_outbound(pool_size: usize, outbound: OutboundConnector) -> Arc<WsPool> {
    Arc::new(WsPool::with_runtime(
        pool_size,
        Duration::from_secs(55),
        Arc::new(Runtime::new(outbound)),
    ))
}

#[tokio::test]
async fn an_empty_pool_misses_and_lets_the_caller_connect_directly() {
    let pool = pool_with_outbound(0, OutboundConnector::direct());

    let hit = pool.get(2, false, "203.0.113.10".to_string(), false).await;

    assert!(hit.is_none());
}

#[tokio::test]
async fn pool_refill_dials_through_the_outbound_connector() {
    // A miss schedules a background refill; with an unreachable upstream it
    // must give up rather than spin, and it must honour the outbound proxy.
    let (proxy_addr, proxy_task) = rejecting_http_proxy_requests(1).await;
    let outbound =
        OutboundConnector::from_config(Some(&format!("http://{proxy_addr}")), None, false).unwrap();
    let pool = pool_with_outbound(1, outbound);

    assert!(
        pool.get(2, false, "203.0.113.10".to_string(), false)
            .await
            .is_none()
    );

    let requests = await_proxy_requests(proxy_task).await;
    assert!(
        requests[0].starts_with("CONNECT 203.0.113.10:443 HTTP/1.1"),
        "unexpected refill target: {requests:?}"
    );
}

#[tokio::test]
async fn warmup_gives_up_on_unreachable_dcs_instead_of_hanging() {
    // One CONNECT per (DC, media) bucket: connect_batch stops a bucket after
    // its first failure, so a fully blocked network costs 2 attempts per DC
    // rather than 2 × --pool-size.
    let (proxy_addr, proxy_task) = rejecting_http_proxy_requests(2).await;
    let config = Config::try_parse_from([
        "tg-ws-proxy",
        "--dc-ip",
        "2:203.0.113.10",
        "--outbound-proxy",
        &format!("http://{proxy_addr}"),
        "--no-outbound-proxy",
        "--no-proxy",
        "",
    ])
    .unwrap();
    let pool = pool_with_outbound(4, config.outbound_connector().unwrap());

    tokio::time::timeout(Duration::from_secs(10), pool.warmup(&config))
        .await
        .expect("warmup should not hang on an unreachable DC");

    let requests = await_proxy_requests(proxy_task).await;
    assert_eq!(requests.len(), 2);

    // Nothing was pooled, so a subsequent get still misses.
    assert!(
        pool.get(2, false, "203.0.113.10".to_string(), false)
            .await
            .is_none()
    );
}
