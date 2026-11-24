// The unit drive — a tests/ target the lane's unit command runs.
use kc_fixture::auth_client::AuthClient;
use kc_fixture::config::Config;
use std::future::Future;
use std::pin::pin;
use std::task::{Context, Poll, Waker};

fn block_on<F: Future>(future: F) -> F::Output {
    let mut future = pin!(future);
    let mut cx = Context::from_waker(Waker::noop());
    loop {
        if let Poll::Ready(value) = future.as_mut().poll(&mut cx) {
            return value;
        }
    }
}

#[test]
fn drive() {
    let client = AuthClient::new("kc");
    assert_eq!(client.realm(), "kc");
    assert_eq!(client.exchange("code").unwrap(), "kc:code");
    assert_eq!(client.port("8080").unwrap(), 8080);
    assert_eq!(client.fallback("8443").unwrap(), 8443);
    assert_eq!(client.pick(&["kc-a", "b"]), "kc-a");
    assert_eq!(block_on(client.token("code")).unwrap(), "at-code");
    // The future is built and dropped — refresh's body never runs.
    drop(client.refresh("rt"));
    assert!(Config::new("kc").valid());
}
