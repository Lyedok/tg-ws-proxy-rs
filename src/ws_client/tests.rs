use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::accept_hdr_async;

use super::*;

fn install_rustls_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

fn test_certificate(domain: &str) -> (CertificateDer<'static>, PrivateKeyDer<'static>) {
    let cert = rcgen::generate_simple_self_signed(vec![domain.to_string()]).unwrap();
    let cert_der = CertificateDer::from(cert.serialize_der().unwrap());
    let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(cert.serialize_private_key_der()));
    (cert_der, key_der)
}

#[test]
fn media_tag_marks_only_media_dcs() {
    assert_eq!(media_tag(true), "m");
    assert_eq!(media_tag(false), "");
}

#[test]
fn base_cf_record_strips_only_the_dash_one_label() {
    assert_eq!(
        base_cf_record("kws2-1.example.net").as_deref(),
        Some("kws2.example.net")
    );
    // Only the first `-1.` is replaced, so a customer domain that itself
    // contains `-1.` keeps its own labels intact.
    assert_eq!(
        base_cf_record("kws2-1.node-1.example.net").as_deref(),
        Some("kws2.node-1.example.net")
    );
    assert_eq!(base_cf_record("kws2.example.net"), None);
    assert_eq!(base_cf_record("kws2-1"), None);
}

#[test]
fn dns_not_found_is_recognised_on_every_platform() {
    // The `-1` record fallback keys off this, and each libc words the failure
    // differently — a missed variant turns an optional record into a hard
    // failure of the whole CF tier.
    for reason in [
        "TCP connect: failed to lookup address information: Name or service not known",
        "TCP connect: nodename nor servname provided, or not known",
        "TCP connect: No such host is known. (os error 11001)",
    ] {
        assert!(is_dns_not_found(reason), "not recognised: {reason}");
    }

    // Anything that is not a resolver failure on the connect step must not
    // trigger the silent retry.
    for reason in [
        "TCP connect: Connection refused (os error 111)",
        "TCP connect timed out",
        "HTTP proxy http://127.0.0.1:1: 407 from server",
        // Same text, but from a later phase than the TCP connect.
        "TLS handshake: failed to lookup address information",
    ] {
        assert!(!is_dns_not_found(reason), "wrongly recognised: {reason}");
    }
}

#[test]
fn ordered_records_put_the_preferred_variant_first() {
    let base = || "kws2.example".to_string();
    let dash_one = || "kws2-1.example".to_string();

    assert_eq!(
        ordered_records(base(), dash_one(), false),
        ["kws2.example", "kws2-1.example"]
    );
    assert_eq!(
        ordered_records(base(), dash_one(), true),
        ["kws2-1.example", "kws2.example"]
    );
}

/// Regression test for the domain-fronting fallback (issue #81): the TLS SNI
/// sent on the wire must be the fronted domain, while the WebSocket upgrade's
/// `Host` header must still be the real one — and the handshake must succeed
/// even though the server's certificate only covers the real domain (proving
/// certificate verification is skipped for fronted connections, since a real
/// cert can never match a spoofed SNI).
#[tokio::test]
async fn sni_override_presents_fronted_sni_but_keeps_real_host() {
    install_rustls_provider();

    let real_domain = "real.example.test";
    let fronted_sni = "fronted.example.test";

    let (cert, key) = test_certificate(real_domain);
    let observed_sni: Arc<StdMutex<Option<String>>> = Arc::new(StdMutex::new(None));
    let observed_host: Arc<StdMutex<Option<String>>> = Arc::new(StdMutex::new(None));

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    let server_sni = Arc::clone(&observed_sni);
    let server_host = Arc::clone(&observed_host);
    let server_task = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();

        // Peek at the ClientHello's SNI before picking a server config —
        // this is the only way to observe what SNI the client actually sent
        // on the wire.
        let acceptor =
            tokio_rustls::LazyConfigAcceptor::new(rustls::server::Acceptor::default(), stream);
        tokio::pin!(acceptor);
        let start = acceptor.as_mut().await.unwrap();
        *server_sni.lock().unwrap() = start.client_hello().server_name().map(str::to_string);

        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![cert], key)
            .unwrap();
        let tls_stream = start.into_stream(Arc::new(config)).await.unwrap();

        accept_hdr_async(
            tls_stream,
            move |req: &tungstenite::handshake::server::Request, resp| {
                let host = req
                    .headers()
                    .get("Host")
                    .and_then(|v| v.to_str().ok())
                    .map(str::to_string);
                *server_host.lock().unwrap() = host;
                Ok(resp)
            },
        )
        .await
        .unwrap();
    });

    let tcp = TcpStream::connect(addr).await.unwrap();
    let request = format!("wss://{real_domain}/apiws")
        .into_client_request()
        .unwrap();

    let (ws, response) = tls_handshake_and_upgrade(tcp, request, false, Some(fronted_sni))
        .await
        .expect("fronted handshake should succeed even though the cert doesn't match the SNI");
    assert_eq!(response.status().as_u16(), 101);
    drop(ws);

    tokio::time::timeout(Duration::from_secs(2), server_task)
        .await
        .expect("server task timed out")
        .expect("server task panicked");

    assert_eq!(observed_sni.lock().unwrap().as_deref(), Some(fronted_sni));
    assert_eq!(observed_host.lock().unwrap().as_deref(), Some(real_domain));
}

/// Without an override, SNI and Host both stay the real domain (unchanged
/// existing behavior) — and, unlike the fronted path, this goes through the
/// normal certificate-verified connector, so it must fail against a
/// self-signed cert that isn't in the trust store.
#[tokio::test]
async fn no_sni_override_uses_domain_for_both_and_verifies_the_certificate() {
    install_rustls_provider();

    let real_domain = "real.example.test";
    let (cert, key) = test_certificate(real_domain);

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    let server_task = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![cert], key)
            .unwrap();
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
        // The client is expected to abort during the TLS handshake because
        // it doesn't trust this self-signed cert, so the accept here may
        // legitimately fail — that's the point of the assertion below.
        let _ = acceptor.accept(stream).await;
    });

    let tcp = TcpStream::connect(addr).await.unwrap();
    let request = format!("wss://{real_domain}/apiws")
        .into_client_request()
        .unwrap();

    let result = tls_handshake_and_upgrade(tcp, request, false, None).await;
    assert!(
        result.is_err(),
        "expected certificate verification to reject the self-signed cert"
    );

    tokio::time::timeout(Duration::from_secs(2), server_task)
        .await
        .expect("server task timed out")
        .ok();
}
