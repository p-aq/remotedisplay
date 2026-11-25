// remotedisplay: whether a Mac host can share its screen and be controlled, for the
// controller (decision 0028; UX audit of 2026-11-21, item 1).
//
// Without Screen Recording the host sends no picture, and the controller waits on
// "Connected, waiting for image…", which looks like a slow network. Without
// Accessibility the host drops the controller's clicks and keys. The login response says
// which, as `rd_host_sound` does for the sound. Only a Mac host sends these keys, and a
// controller that doesn't get them changes nothing.

/// The login response's `rd_host_screen` (Screen Recording) and `rd_host_control`
/// (Accessibility): "ready", or "unavailable" without that permission.
pub(super) fn keys(screen: bool, control: bool) -> Vec<(String, serde_json::Value)> {
    let say = |ready: bool| if ready { "ready" } else { "unavailable" };
    vec![
        ("rd_host_screen".to_owned(), say(screen).into()),
        ("rd_host_control".to_owned(), say(control).into()),
    ]
}

/// This Mac's keys, from the checks the engine already makes for the server app's
/// permission file. With `false` they only read what macOS has granted and never prompt.
/// Screen Recording is read as this process sees it, so the key says what this engine
/// can capture; the server app restarts the engine when either permission is granted.
#[cfg(target_os = "macos")]
pub(super) fn status() -> Vec<(String, serde_json::Value)> {
    keys(
        crate::platform::macos::is_can_screen_recording(false),
        crate::platform::macos::is_process_trusted(false),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    /// What the controller reads: `rd_host_screen`, then `rd_host_control`.
    fn read(screen: bool, control: bool) -> Vec<String> {
        let sent: HashMap<_, _> = keys(screen, control).into_iter().collect();
        ["rd_host_screen", "rd_host_control"]
            .iter()
            .map(|key| sent[*key].as_str().unwrap().to_owned())
            .collect()
    }

    #[test]
    fn the_controller_hears_whether_it_can_see_and_control() {
        assert_eq!(read(true, true), ["ready", "ready"]);
        // Screen Recording off: no picture, so the controller would wait for one.
        assert_eq!(read(false, true), ["unavailable", "ready"]);
        // Accessibility off: a picture, but the host drops clicks and keys.
        assert_eq!(read(true, false), ["ready", "unavailable"]);
        assert_eq!(read(false, false), ["unavailable", "unavailable"]);
    }

    #[test]
    fn they_reach_platform_additions_as_strings() {
        // As connection.rs adds them, next to `rd_host_sound`.
        let mut platform_additions = serde_json::Map::new();
        platform_additions.extend(keys(false, true));
        let sent: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&platform_additions).unwrap()).unwrap();
        assert_eq!(
            sent,
            serde_json::json!({"rd_host_screen": "unavailable", "rd_host_control": "ready"})
        );
    }
}
