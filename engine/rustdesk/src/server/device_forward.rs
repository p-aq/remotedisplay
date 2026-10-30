// remotedisplay: camera and microphone forwarding on the host (camera & audio
// forwarding spec, Host side). For now, the owner's switch (decision 0009): off by
// default, and only the host owner turns it on, from the server app, which runs
// `remotedisplayd --set-device-forward on|off`. Request handling joins it in Phase 1.

use hbb_common::config::Config;

/// The engine option behind the owner's switch: "Y" when on, absent when off.
pub const OPTION: &str = "rd-allow-device-forward";

/// Whether the owner allows controllers to forward their camera and microphone.
pub fn is_allowed() -> bool {
    Config::get_option(OPTION) == "Y"
}

/// The option value for `--set-device-forward`'s argument; an empty value removes the
/// option, so "off" is the default state rather than a stored "N".
pub fn option_value(arg: &str) -> Option<&'static str> {
    match arg {
        "on" => Some("Y"),
        "off" => Some(""),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn on_and_off_only() {
        assert_eq!(option_value("on"), Some("Y"));
        assert_eq!(option_value("off"), Some(""));
        for arg in ["", "ON", "yes", "true", "1", "Y"] {
            assert_eq!(option_value(arg), None, "{arg:?}");
        }
    }
}
