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

  /// The camera's unique ID, or the microphone's name, while asking or on.
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

/// What the menu calls the host: the first label of the hostname it reports
/// ("mac-mini.local" → "mac-mini"), or "the computer you're controlling" when
/// it reports none, or a name that would point at no machine in particular:
/// "localhost" (the engine's fallback) or an address. "This Mac", read on the
/// controller, sounded like the controller itself (decision 0012).
String hostName(String? hostname) {
  final name = (hostname ?? '').trim();
  final label = name.split('.').first.trim();
  final unusable = label.isEmpty ||
      label.toLowerCase() == 'localhost' ||
      RegExp(r'^[0-9]+$').hasMatch(label) ||
      name.contains(':');
  return unusable ? "the computer you're controlling" : label;
}

/// [host] at the start of a sentence. The host's engine sends its name in
/// lower case ("mac-mini"), so the first letter is capitalized here.
String _start(String host) =>
    host.isEmpty ? host : '${host[0].toUpperCase()}${host.substring(1)}';

/// Why the host can't receive [kind], or null when it can. [status] is
/// [hostStatus]; [hostIsMac] tells a 1.0.x Mac host from a host that isn't a
/// Mac; [host] is [hostName].
String? hostReason(String? status, String kind,
    {required bool hostIsMac, required String host}) {
  if (status == null) {
    return hostIsMac
        ? 'Update Remote Display Server on $host'
        : 'Only a Mac can receive a ${_noun(kind)} for now';
  }
  switch (status) {
    case 'ready':
      return null;
    case 'not-allowed':
      return "${_start(host)} hasn't turned on ${_noun(kind)} sharing";
    case 'not-installed':
      return "${_device(kind)} isn't installed on $host";
    case 'not-approved':
      return '${_device(kind)} is waiting for approval on $host';
    default:
      return "${_start(host)} can't receive a ${_noun(kind)} right now";
  }
}

/// Why a forward of [kind] stopped on its own ([ForwardState.reason]), or null.
String? stopReason(String reason, String kind,
    {required bool hostIsMac, required String host}) {
  switch (reason) {
    case '':
      return null;
    case 'busy':
      return 'Another controller is sending its ${_noun(kind)} to $host';
    case 'bad-format':
      return "${_start(host)} can't take this ${_noun(kind)}'s picture size or frame rate";
    case 'no-answer':
      return "${_start(host)} didn't answer";
    case 'sink-failed':
      return "${_start(host)} couldn't start ${_device(kind)}";
    case 'camera-failed':
    case 'microphone-failed':
      return "The ${_noun(kind)} didn't start";
    case 'camera-lost':
    case 'microphone-lost':
      return 'The ${_noun(kind)} was disconnected or stopped working';
    case 'not-allowed':
    case 'not-installed':
    case 'not-approved':
      return hostReason(reason, kind, hostIsMac: hostIsMac, host: host);
    default:
      return '${_start(host)} turned the ${_noun(kind)} off';
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

/// One of the controller's cameras (`mainListCameras`) or microphones
/// (`mainListMicrophones`, whose ID is the input's name).
class CaptureDevice {
  const CaptureDevice(this.id, this.name);
  final String id;
  final String name;

  static List<CaptureDevice> parseList(String json) {
    try {
      return [
        for (final c in jsonDecode(json) as List)
          if (c is Map && c['id'] is String && c['name'] is String)
            CaptureDevice(c['id'] as String, c['name'] as String)
      ];
    } catch (_) {
      return const [];
    }
  }
}

typedef Camera = CaptureDevice;
typedef Microphone = CaptureDevice;

/// The engine's test card, listed as a camera when the app runs with
/// `--camera-test-pattern` (src/platform/macos_camera_capture.rs).
const kTestPatternCamera = 'remotedisplay-test-pattern';

/// Whether sending camera [id] needs this Mac's camera access: every camera but
/// the test card.
bool needsCameraAccess(String id) => id != kTestPatternCamera;

/// The camera to forward: the one on, else the one picked last time if it's
/// still there, else the first.
Camera? pickCamera(List<Camera> cameras, ForwardState state, String saved) =>
    _pick(cameras, state, saved);

/// The microphone to forward, picked the same way.
Microphone? pickMicrophone(
        List<Microphone> microphones, ForwardState state, String saved) =>
    _pick(microphones, state, saved);

CaptureDevice? _pick(
    List<CaptureDevice> devices, ForwardState state, String saved) {
  for (final id in [if (state.device.isNotEmpty) state.device, saved]) {
    for (final d in devices) {
      if (d.id == id) return d;
    }
  }
  return devices.isEmpty ? null : devices.first;
}

/// The spec's hint against echo (decision 0023): with the microphone going to
/// the host and the host's sound playing here, the speakers would reach the
/// microphone and the call would hear itself.
String? echoHint({required bool micOn, required bool soundOn}) =>
    micOn && soundOn ? 'Use headphones, or the call hears its own echo' : null;

/// Why the host's sound can't play here, or null when it can (decision 0028).
/// [audioAllowed] is the host's audio permission for this session; [hostSound]
/// its `rd_host_sound` from the login response, which a host without it doesn't
/// send; [host] is [hostName].
String? soundReason(
    {required bool audioAllowed, Object? hostSound, required String host}) {
  if (!audioAllowed) return "${_start(host)} doesn't share its sound";
  if (hostSound == 'unavailable') {
    return "${_start(host)} can't share its sound until Screen Recording is on there";
  }
  return null;
}
