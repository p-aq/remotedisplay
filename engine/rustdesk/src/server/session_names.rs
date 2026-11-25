// remotedisplay: who is connected, by name, for the server app (decision 0009).
//
// The server app lists the engine's connections with lsof, as `ip:port`. A connection
// whose controller logs in adds that controller's name under its address here, and the
// `--server` writes them all to remotedisplay-sessions.json on the same 2 s loop as
// remotedisplay-perms.json, so the app's Active sessions and menu can say who it is.

use super::device_forward::MAX_NAME;
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{Arc, Mutex},
};

/// Each logged-in connection's controller, by connection id: its address and name.
type Names = Arc<Mutex<HashMap<i32, (String, String)>>>;

lazy_static::lazy_static! {
    static ref NAMES: Names = Default::default();
}

/// What the server app reads: `{"192.168.1.245:37911": "<controller>"}`, one entry for
/// each logged-in connection, `{}` when no one is connected.
pub fn sessions_json() -> String {
    json_of(&NAMES)
}

fn json_of(names: &Names) -> String {
    let out: serde_json::Map<String, serde_json::Value> = names
        .lock()
        .unwrap()
        .values()
        .map(|(addr, name)| (addr.clone(), name.clone().into()))
        .collect();
    serde_json::Value::Object(out).to_string()
}

/// `addr` as the server app writes a peer it found with lsof: IPv4-mapped IPv6 as IPv4,
/// as the connection's own address (`try_into_v4`), other IPv6 in brackets without a zone.
fn address(addr: SocketAddr) -> String {
    match hbb_common::try_into_v4(addr) {
        SocketAddr::V6(v6) => format!("[{}]:{}", v6.ip(), v6.port()),
        v4 => v4.to_string(),
    }
}

/// A connection's entry: none until its controller logs in, and gone when the connection
/// drops it, however the connection ends.
pub struct SessionName {
    conn_id: i32,
    addr: SocketAddr,
    names: Names,
}

impl SessionName {
    pub fn new(conn_id: i32, addr: SocketAddr) -> Self {
        Self::with(conn_id, addr, NAMES.clone())
    }

    fn with(conn_id: i32, addr: SocketAddr, names: Names) -> Self {
        Self {
            conn_id,
            addr,
            names,
        }
    }

    /// Names the controller from now on, cut to the length the app's menu shows.
    pub fn logged_in(&self, name: &str) {
        let name = name.chars().take(MAX_NAME).collect();
        self.names
            .lock()
            .unwrap()
            .insert(self.conn_id, (address(self.addr), name));
    }
}

impl Drop for SessionName {
    fn drop(&mut self) {
        self.names.lock().unwrap().remove(&self.conn_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv6Addr, SocketAddrV6};

    fn json(names: &Names) -> serde_json::Value {
        serde_json::from_str(&json_of(names)).unwrap()
    }

    #[test]
    fn names_each_logged_in_controller_under_the_address_the_app_reads() {
        let names = Names::default();
        assert_eq!(json_of(&names), "{}");
        let session = |id, addr: SocketAddr| SessionName::with(id, addr, names.clone());
        let mapped = session(1, "[::ffff:192.168.1.245]:37911".parse().unwrap());
        let tailscale = session(2, "[fd7a:115c:a1e0::5]:41000".parse().unwrap());
        let fe80 = Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
        let link_local = session(3, SocketAddrV6::new(fe80, 50419, 0, 4).into());
        let at_the_password = session(4, "192.168.1.9:50000".parse().unwrap());
        mapped.logged_in("Alex");
        tailscale.logged_in("Sam");
        link_local.logged_in("Sam");
        assert_eq!(
            json(&names),
            serde_json::json!({
                "192.168.1.245:37911": "Alex",
                "[fd7a:115c:a1e0::5]:41000": "Sam",
                "[fe80::1]:50419": "Sam",
            })
        );
        drop(mapped);
        drop(tailscale);
        drop(link_local);
        assert_eq!(json_of(&names), "{}", "each entry goes with its connection");
        drop(at_the_password);
    }

    #[test]
    fn cuts_the_name_to_the_menus_length() {
        let names = Names::default();
        let session = SessionName::with(1, "192.168.1.245:37911".parse().unwrap(), names.clone());
        session.logged_in(&format!("\"{}", "é".repeat(100)));
        let name = json(&names)["192.168.1.245:37911"].clone();
        assert_eq!(name, format!("\"{}", "é".repeat(MAX_NAME - 1)));
    }
}
