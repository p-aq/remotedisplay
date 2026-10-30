import 'dart:convert';

/// What the Devices menu knows about forwarding one device (camera or microphone)
/// to the host (decisions 0012 and 0018):
///
/// - the engine's latest `rd_device_forward` event (`FfiModel.deviceForward`):
///   whether the forward is off, waiting for the host's answer or on, which
///   camera, why it last stopped, and the host's status from `DeviceStatus`;
/// - the host's status from its login response (`rd_camera_sink`,
///   `rd_mic_sink` in the platform additions), until a `DeviceStatus` replaces it.
class ForwardState {
  const ForwardState(
      {this.forward = 'off',
      this.device = '',
      this.reason = '',
      this.host = ''});

  /// "off", "asking" or "on".
  final String forward;

  /// The camera's unique ID while asking or on.
  final String device;

  /// Why the forward stopped without being switched off, or "".
  final String reason;

  /// The host's status from its latest `DeviceStatus`, or "" before one.
  final String host;

  bool get on => forward == 'on';
  bool get asking => forward == 'asking';

  /// [kind] ("camera" or "microphone") out of the engine's JSON; off when the
  /// engine hasn't said anything yet or the JSON doesn't parse.
  static ForwardState parse(String json, String kind) {
    if (json.isEmpty) return const ForwardState();
    try {
      final m = (jsonDecode(json) as Map<String, dynamic>)[kind];
      if (m is! Map<String, dynamic>) return const ForwardState();
      String s(String k) => m[k] is String ? m[k] as String : '';
      return ForwardState(
          forward: s('forward').isEmpty ? 'off' : s('forward'),
          device: s('device'),
          reason: s('reason'),
          host: s('host'));
    } catch (_) {
      return const ForwardState();
    }
  }
}

/// The host's status for [kind]: its latest `DeviceStatus` if one came, else
/// what its login response said; null for a host without forwarding (1.0.x,
/// or not a Mac).
String? hostStatus(
    ForwardState state, Map<String, dynamic> platformAdditions, String kind) {
  if (state.host.isNotEmpty) return state.host;
  if (platformAdditions['rd_device_forward'] == null) return null;
  final login =
      platformAdditions[kind == 'camera' ? 'rd_camera_sink' : 'rd_mic_sink'];
  return login is String && login.isNotEmpty ? login : 'not-installed';
}

String _noun(String kind) => kind == 'camera' ? 'camera' : 'microphone';
String _device(String kind) =>
    kind == 'camera' ? 'Remote Display Camera' : 'Remote Display Microphone';

/// Why the host can't receive [kind], or null when it can. [status] is
/// [hostStatus]; [hostIsMac] tells a 1.0.x Mac host from a host that isn't a Mac.
String? hostReason(String? status, String kind, {required bool hostIsMac}) {
  if (status == null) {
    return hostIsMac
        ? 'Update Remote Display Server on this Mac'
        : 'Only a Mac can receive a ${_noun(kind)} for now';
  }
  switch (status) {
    case 'ready':
      return null;
    case 'not-allowed':
      return "This Mac hasn't turned on ${_noun(kind)} sharing";
    case 'not-installed':
      return "${_device(kind)} isn't installed on this Mac";
    case 'not-approved':
      return '${_device(kind)} is waiting for approval on this Mac';
    default:
      return "This Mac can't receive a ${_noun(kind)} right now";
  }
}

/// Why a forward of [kind] stopped on its own ([ForwardState.reason]), or null.
String? stopReason(String reason, String kind, {required bool hostIsMac}) {
  switch (reason) {
    case '':
      return null;
    case 'busy':
      return 'Another controller is sending its ${_noun(kind)} to this Mac';
    case 'bad-format':
      return "This Mac can't take this ${_noun(kind)}'s picture size or frame rate";
    case 'no-answer':
      return "This Mac didn't answer";
    case 'camera-failed':
      return "The ${_noun(kind)} didn't start";
    case 'not-allowed':
    case 'not-installed':
    case 'not-approved':
      return hostReason(reason, kind, hostIsMac: hostIsMac);
    default:
      return 'This Mac turned the ${_noun(kind)} off';
  }
}

/// The controller's own access to [kind], as the engine reports it: what the row
/// says when it stops the switch, or null when the switch can be used.
String? permissionReason(String permission, String kind) {
  switch (permission) {
    case 'allowed':
    case 'not-determined': // macOS asks when the switch is turned on
      return null;
    case 'denied':
      return 'Allow ${_noun(kind)} access in System Settings';
    case 'restricted':
      return '${_noun(kind)[0].toUpperCase()}${_noun(kind).substring(1)} access is restricted on this device';
    default:
      return 'Not available on this device yet';
  }
}

/// One of the controller's cameras, from `mainListCameras`.
class Camera {
  const Camera(this.id, this.name);
  final String id;
  final String name;

  static List<Camera> parseList(String json) {
    try {
      return [
        for (final c in jsonDecode(json) as List)
          if (c is Map && c['id'] is String && c['name'] is String)
            Camera(c['id'] as String, c['name'] as String)
      ];
    } catch (_) {
      return const [];
    }
  }
}

/// The camera to forward: the one on, else the one picked last time if it's
/// still there, else the first.
Camera? pickCamera(List<Camera> cameras, ForwardState state, String saved) {
  for (final id in [if (state.device.isNotEmpty) state.device, saved]) {
    for (final c in cameras) {
      if (c.id == id) return c;
    }
  }
  return cameras.isEmpty ? null : cameras.first;
}
