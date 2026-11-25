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
String _capitalNoun(String kind) => kind == 'camera' ? 'Camera' : 'Microphone';
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

/// Why the host can't receive [kind], or null when it can, said as where to fix
/// it. [status] is [hostStatus]; [hostIsMac] tells a 1.0.x Mac host from a host
/// that isn't a Mac; [host] is [hostName].
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
      // The owner's switch in the server app's Settings.
      return "Turn on ${_noun(kind)} sharing in Remote Display Server's Settings on $host";
    case 'not-installed':
      // What hosts send for any camera or microphone that isn't working yet:
      // not installed, or installed and waiting for an admin. Setup's row says
      // which and offers the step (Install…, or Open Settings…).
      return "Finish setting up ${_device(kind)} in Remote Display Server's Setup on $host";
    case 'not-approved': // not sent by hosts yet
      return 'An admin needs to allow ${_device(kind)} in System Settings on $host';
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
      return '${_capitalNoun(kind)} access is restricted on this device';
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
    micOn && soundOn
        ? 'If the call hears itself, use headphones at a low volume'
        : null;

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

/// The login response's platform additions as the engine's latest `peer_info`
/// event carried them (`FfiModel.cachedPeerData.peerInfo`), or empty. The
/// engine keeps the event as soon as it arrives; `PeerInfo.platformAdditions`
/// follows only after its handler has waited on other calls, so on a
/// reconnection it can still hold the last connection's when the waiting box
/// shows.
Map<String, dynamic> loginAdditions(Map<String, dynamic> peerInfo) {
  try {
    final additions = jsonDecode(peerInfo['platform_additions'] as String);
    return additions is Map<String, dynamic> ? additions : const {};
  } catch (_) {
    return const {};
  }
}

/// What the session shows in place of the engine's "Connected, waiting for
/// image..." when the host can't share its screen, or null when it can
/// (decision 0018). [hostScreen] is its `rd_host_screen` from the login
/// response, "unavailable" without Screen Recording; a host older than the key
/// doesn't send it, and nothing changes. [host] is [hostName].
({String title, String text})? screenReason(Object? hostScreen,
        {required String host}) =>
    hostScreen == 'unavailable'
        ? (
            title: "${_start(host)} can't share its screen",
            text: 'Turn on Screen Recording for Remote Display Server on $host'
          )
        : null;

/// What the status line says, once the picture shows, when the host drops
/// clicks and keys, or null (decision 0018). [hostControl] is its
/// `rd_host_control` from the login response, "unavailable" without
/// Accessibility; a host older than the key doesn't send it. [host] is
/// [hostName].
String? controlReason(Object? hostControl, {required String host}) =>
    hostControl == 'unavailable'
        ? "Clicks and keys won't reach $host · turn on Accessibility for Remote Display Server there"
        : null;

/// What the status line over the session says when a forward of [kind] goes from
/// [before] to [after], or null when the change needs no line (decision 0018).
/// The menu closes when tapped, so this is where the result of a tap shows:
///
/// - on: "Camera on", and while [tip] (the first time in a session) which
///   device to choose in the call on [host];
/// - refused, or stopped on its own: [stopReason];
/// - the host's status changed while it was on or starting: [hostReason].
///
/// Starting, switching off and the host's status while off say nothing: the
/// Devices button and the menu show those. Whether a forward that went off
/// without a reason was switched off or went with its connection is for
/// [ForwardNotices] to tell.
String? forwardNotice(ForwardState before, ForwardState after, String kind,
    {required bool hostIsMac, required String host, bool tip = false}) {
  if (after.on && !before.on) {
    final on = '${_capitalNoun(kind)} on';
    return tip ? '$on · choose ${_device(kind)} in the call on $host' : on;
  }
  if (after.reason.isNotEmpty && after.reason != before.reason) {
    return stopReason(after.reason, kind, hostIsMac: hostIsMac, host: host);
  }
  final sending = (before.on || before.asking) && (after.on || after.asking);
  if (sending && after.host.isNotEmpty && after.host != before.host) {
    return hostReason(after.host, kind, hostIsMac: hostIsMac, host: host);
  }
  return null;
}

/// What the status line says once the session is back from a connection that
/// dropped while [kinds] were on (issue #70): the engine ends every forward with
/// its connection and reports them off without a reason, so the menu alone
/// can't say why.
String? droppedNotice(Set<String> kinds) {
  final nouns = [
    for (final kind in const ['camera', 'microphone'])
      if (kinds.contains(kind)) _noun(kind)
  ];
  return nouns.isEmpty
      ? null
      : 'The connection dropped, so the ${nouns.join(' and ')} turned off';
}

/// What the badge beside the pill says while this Mac's [camera] or
/// [microphone] goes to [host] ([hostName]), or null while neither does and
/// the badge is hidden (UX audit of 2026-11-21, item 3). Asking counts, as for
/// the Devices button.
String? sendingTooltip(ForwardState camera, ForwardState microphone,
    {required String host}) {
  final nouns = [
    if (camera.on || camera.asking) _noun('camera'),
    if (microphone.on || microphone.asking) _noun('microphone'),
  ];
  return nouns.isEmpty ? null : 'Sending your ${nouns.join(' and ')} to $host';
}

/// The status line's memory for one session (decision 0018). The toolbar feeds
/// it the engine's forward state and the session's events, and shows what it
/// returns: lines keyed by what they are about ("camera", "microphone", "echo",
/// "connection", "control"), so a newer line replaces an older one about the
/// same thing. It says each change once, gives the device tip, the echo hint
/// and a host's missing Accessibility once a session, and keeps a forward that
/// went off with its connection until the session is back.
class ForwardNotices {
  ForwardNotices([this._forwards = '']);

  /// The engine's state as last heard (`FfiModel.deviceForward`).
  String _forwards;
  final _tipped = <String>{};
  bool _echoed = false;
  bool _controlSaid = false;

  /// The line last said per kind. A new try clears it, so a refusal that
  /// follows the host's status saying the same thing isn't said twice, but the
  /// same refusal on the next try is.
  final _said = <String, String>{};

  /// Kinds switched off from this toolbar, until the engine reports them off.
  final _switchingOff = <String>{};

  /// The connection (`FfiModel.peerInfoEpoch`) each kind was last on or
  /// starting in.
  final _onEpoch = <String, int>{};

  /// Kinds that went off without a reason and without a switch-off from here,
  /// with the connection they were on.
  final _dropped = <String, int>{};

  /// The user switched [kind] off from this toolbar: its going off isn't the
  /// connection's doing.
  void switchingOff(String kind) => _switchingOff.add(kind);

  /// The engine's new state [json], heard during connection [epoch]. [soundOn]
  /// is whether the host's sound plays here, for the echo hint.
  Map<String, String> forwards(String json,
      {required int epoch,
      required bool hostIsMac,
      required String host,
      required bool soundOn}) {
    final micWasOn = ForwardState.parse(_forwards, 'microphone').on;
    final lines = <String, String>{};
    for (final kind in const ['camera', 'microphone']) {
      final line = _change(kind, ForwardState.parse(_forwards, kind),
          ForwardState.parse(json, kind),
          epoch: epoch, hostIsMac: hostIsMac, host: host);
      if (line != null) lines[kind] = line;
    }
    _forwards = json;
    if (!micWasOn) lines.addAll(_echo(soundOn: soundOn));
    // The old connection's end can be heard after the next one began.
    return lines..addAll(_back(epoch));
  }

  /// The user turned the host's sound on.
  Map<String, String> soundTurnedOn() => _echo(soundOn: true);

  /// The session shows a picture from connection [epoch]. [control] is
  /// [controlReason] for that connection, said the first time it comes.
  Map<String, String> connected(int epoch, {String? control}) {
    final lines = {..._back(epoch)};
    if (control != null && !_controlSaid) {
      _controlSaid = true;
      lines['control'] = control;
    }
    return lines;
  }

  /// The line for the forwards an earlier connection than [epoch] took with
  /// it, once.
  Map<String, String> _back(int epoch) {
    final gone = {
      for (final e in _dropped.entries)
        if (epoch > e.value) e.key
    };
    _dropped.removeWhere((kind, _) => gone.contains(kind));
    final line = droppedNotice(gone);
    return line == null ? const {} : {'connection': line};
  }

  String? _change(String kind, ForwardState before, ForwardState after,
      {required int epoch, required bool hostIsMac, required String host}) {
    final wasSending = before.on || before.asking;
    final sending = after.on || after.asking;
    if (sending) _onEpoch[kind] = epoch;
    if (after.asking && !before.asking) {
      // A new try, or another camera: its result is said whatever came before.
      _said.remove(kind);
      _switchingOff.remove(kind);
      _dropped.remove(kind);
    }
    if (wasSending && !sending && after.reason.isEmpty) {
      // Off without a reason: switched off from here, or its connection ended
      // (decision 0018). A switch-off from another window of the same session
      // reads as the latter.
      if (!_switchingOff.remove(kind)) _dropped[kind] = _onEpoch[kind] ?? epoch;
      return null;
    }
    final line = forwardNotice(before, after, kind,
        hostIsMac: hostIsMac, host: host, tip: !_tipped.contains(kind));
    if (line == null || _said[kind] == line) return null;
    if (after.on && !before.on) _tipped.add(kind);
    _said[kind] = line;
    return line;
  }

  /// The echo hint, once a session, when the microphone is on and the host's
  /// sound plays here.
  Map<String, String> _echo({required bool soundOn}) {
    final hint = echoHint(
        micOn: ForwardState.parse(_forwards, 'microphone').on,
        soundOn: soundOn);
    if (_echoed || hint == null) return const {};
    _echoed = true;
    return {'echo': hint};
  }
}
