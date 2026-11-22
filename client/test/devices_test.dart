import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotedisplay_client/session/devices.dart';

void main() {
  // The engine's rd_device_forward event (src/client/device_forward.rs).
  const asking =
      '{"camera":{"forward":"asking","device":"cam-1","reason":"","host":""}}';
  const refused =
      '{"camera":{"forward":"off","device":"","reason":"busy","host":"ready"}}';
  const both =
      '{"camera":{"forward":"off","device":"","reason":"","host":""},"microphone":{"forward":"on","device":"USB Mic","reason":"","host":"ready"}}';

  group('ForwardState', () {
    test('reads the camera out of the engine event', () {
      final s = ForwardState.parse(asking, 'camera');
      expect((s.forward, s.device, s.asking, s.on),
          ('asking', 'cam-1', true, false));
      final r = ForwardState.parse(refused, 'camera');
      expect((r.forward, r.reason, r.host), ('off', 'busy', 'ready'));
    });

    test('reads the microphone beside the camera', () {
      final m = ForwardState.parse(both, 'microphone');
      expect((m.on, m.device, m.host), (true, 'USB Mic', 'ready'));
      expect(ForwardState.parse(both, 'camera').forward, 'off');
    });

    test(
        'is off before the first event, for a kind not reported, and for bad JSON',
        () {
      for (final json in ['', asking, '{', '[]', '{"camera":3}']) {
        final s =
            ForwardState.parse(json, json == asking ? 'microphone' : 'camera');
        expect((s.forward, s.device, s.reason, s.host), ('off', '', '', ''));
      }
    });
  });

  group('hostStatus', () {
    const login = {
      'rd_device_forward': 1,
      'rd_camera_sink': 'not-allowed',
      'rd_mic_sink': 'not-installed'
    };

    test('takes the login response until a DeviceStatus arrives', () {
      expect(hostStatus(const ForwardState(), login, 'camera'), 'not-allowed');
      expect(hostStatus(const ForwardState(), login, 'microphone'),
          'not-installed');
      expect(hostStatus(const ForwardState(host: 'ready'), login, 'camera'),
          'ready');
    });

    test('is null for a host without forwarding', () {
      expect(hostStatus(const ForwardState(), {}, 'camera'), isNull);
      // A DeviceStatus can only come from a host that has it.
      expect(
          hostStatus(const ForwardState(host: 'ready'), {}, 'camera'), 'ready');
    });
  });

  group('reasons', () {
    test('name the host, not "this Mac"', () {
      expect(hostName('Mac-mini.local'), 'Mac-mini');
      expect(hostName('Mac-mini'), 'Mac-mini');
      expect(hostName(''), "the computer you're controlling");
      expect(hostName(null), "the computer you're controlling");
      final fallback = hostName(null);
      expect(
          hostReason('not-allowed', 'camera', hostIsMac: true, host: fallback),
          "Turn on camera sharing in Remote Display Server's Settings on the computer you're controlling");
      expect(
          hostReason('not-installed', 'camera',
              hostIsMac: true, host: fallback),
          "Install Remote Display Camera from Setup in Remote Display Server on the computer you're controlling");
      // At the start of a sentence, capitalized.
      expect(
          hostReason('something-new', 'camera',
              hostIsMac: true, host: fallback),
          "The computer you're controlling can't receive a camera right now");
    });

    test('the host, with where to fix it', () {
      expect(hostReason('ready', 'camera', hostIsMac: true, host: 'Mac-mini'),
          isNull);
      expect(
          hostReason('not-allowed', 'camera',
              hostIsMac: true, host: 'Mac-mini'),
          "Turn on camera sharing in Remote Display Server's Settings on Mac-mini");
      expect(
          hostReason('not-allowed', 'microphone',
              hostIsMac: true, host: 'Mac-mini'),
          "Turn on microphone sharing in Remote Display Server's Settings on Mac-mini");
      expect(
          hostReason('not-installed', 'camera',
              hostIsMac: true, host: 'Mac-mini'),
          'Install Remote Display Camera from Setup in Remote Display Server on Mac-mini');
      expect(
          hostReason('not-installed', 'microphone',
              hostIsMac: true, host: 'Mac-mini'),
          'Install Remote Display Microphone from Setup in Remote Display Server on Mac-mini');
      expect(
          hostReason('not-approved', 'camera',
              hostIsMac: true, host: 'Mac-mini'),
          'An admin needs to allow Remote Display Camera in System Settings on Mac-mini');
      expect(
          hostReason('not-approved', 'microphone',
              hostIsMac: true, host: 'Mac-mini'),
          'An admin needs to allow Remote Display Microphone in System Settings on Mac-mini');
      expect(hostReason(null, 'camera', hostIsMac: true, host: 'Mac-mini'),
          'Update Remote Display Server on Mac-mini');
      expect(hostReason(null, 'camera', hostIsMac: false, host: 'Mac-mini'),
          'Only a Mac can receive a camera for now');
      expect(
          hostReason('something-new', 'camera',
              hostIsMac: true, host: 'Mac-mini'),
          "Mac-mini can't receive a camera right now");
    });

    test('a forward that stopped on its own', () {
      expect(
          stopReason('', 'camera', hostIsMac: true, host: 'Mac-mini'), isNull);
      expect(stopReason('busy', 'camera', hostIsMac: true, host: 'Mac-mini'),
          'Another controller is sending its camera to Mac-mini');
      expect(
          stopReason('no-answer', 'camera', hostIsMac: true, host: 'Mac-mini'),
          "Mac-mini didn't answer");
      expect(
          stopReason('sink-failed', 'camera',
              hostIsMac: true, host: 'Mac-mini'),
          "Mac-mini couldn't start Remote Display Camera");
      expect(
          stopReason('camera-failed', 'camera',
              hostIsMac: true, host: 'Mac-mini'),
          "The camera didn't start");
      expect(
          stopReason('camera-lost', 'camera',
              hostIsMac: true, host: 'Mac-mini'),
          'The camera was disconnected or stopped working');
      expect(
          stopReason('not-allowed', 'camera',
              hostIsMac: true, host: 'Mac-mini'),
          hostReason('not-allowed', 'camera',
              hostIsMac: true, host: 'Mac-mini'));
      expect(stopReason('refused', 'camera', hostIsMac: true, host: 'Mac-mini'),
          'Mac-mini turned the camera off');
    });

    test('a microphone forward that stopped on its own', () {
      expect(
          stopReason('microphone-failed', 'microphone',
              hostIsMac: true, host: 'Mac-mini'),
          "The microphone didn't start");
      expect(
          stopReason('sink-failed', 'microphone',
              hostIsMac: true, host: 'Mac-mini'),
          "Mac-mini couldn't start Remote Display Microphone");
      expect(
          stopReason('microphone-lost', 'microphone',
              hostIsMac: true, host: 'Mac-mini'),
          'The microphone was disconnected or stopped working');
      expect(
          stopReason('busy', 'microphone', hostIsMac: true, host: 'Mac-mini'),
          'Another controller is sending its microphone to Mac-mini');
      expect(permissionReason('denied', 'microphone'),
          'Allow microphone access in System Settings');
    });

    test('headphones while the microphone and the sound are both on', () {
      expect(echoHint(micOn: true, soundOn: true),
          'If the call hears itself, use headphones at a low volume');
      expect(echoHint(micOn: true, soundOn: false), isNull);
      expect(echoHint(micOn: false, soundOn: true), isNull);
    });

    test("the host's sound", () {
      expect(
          soundReason(audioAllowed: true, hostSound: 'ready', host: 'Mac-mini'),
          isNull);
      // A 1.0.x host, or one that doesn't say.
      expect(soundReason(audioAllowed: true, host: 'Mac-mini'), isNull);
      expect(
          soundReason(
              audioAllowed: true, hostSound: 'unavailable', host: 'Mac-mini'),
          "Mac-mini can't share its sound until Screen Recording is on there");
      expect(
          soundReason(
              audioAllowed: false, hostSound: 'ready', host: 'Mac-mini'),
          "Mac-mini doesn't share its sound");
    });

    test("the host's screen and control, with where to fix them", () {
      expect(screenReason('unavailable', host: 'Mac-mini'), (
        title: "Mac-mini can't share its screen",
        text: 'Turn on Screen Recording for Remote Display Server on Mac-mini'
      ));
      expect(controlReason('unavailable', host: 'Mac-mini'),
          "Clicks and keys won't reach Mac-mini · turn on Accessibility for Remote Display Server there");
      expect(screenReason('unavailable', host: hostName(null))?.title,
          "The computer you're controlling can't share its screen");
      expect(controlReason('unavailable', host: hostName(null)),
          "Clicks and keys won't reach the computer you're controlling · turn on Accessibility for Remote Display Server there");
      // Ready, or a host older than the keys: nothing to say.
      for (final status in ['ready', null]) {
        expect(screenReason(status, host: 'Mac-mini'), isNull);
        expect(controlReason(status, host: 'Mac-mini'), isNull);
      }
    });

    test("reads the login keys out of the engine's peer_info event", () {
      final additions = loginAdditions({
        'hostname': 'Mac-mini.local',
        'platform_additions':
            '{"rd_host_screen":"unavailable","rd_host_control":"ready"}'
      });
      expect((additions['rd_host_screen'], additions['rd_host_control']),
          ('unavailable', 'ready'));
      // Before the first event, a host that sends none, and bad JSON.
      for (final event in <Map<String, dynamic>>[
        {},
        {'platform_additions': ''},
        {'platform_additions': '[1]'},
        {'platform_additions': '{'}
      ]) {
        expect(loginAdditions(event), isEmpty);
      }
    });

    test("the controller's own access", () {
      expect(permissionReason('allowed', 'camera'), isNull);
      expect(permissionReason('not-determined', 'camera'), isNull);
      expect(permissionReason('denied', 'camera'),
          'Allow camera access in System Settings');
      expect(permissionReason('restricted', 'camera'),
          'Camera access is restricted on this device');
      expect(permissionReason('unsupported', 'camera'),
          'Not available on this device yet');
    });
  });

  group('cameras', () {
    const list =
        '[{"id":"a","name":"FaceTime HD Camera"},{"id":"b","name":"LifeCam"},{"id":3}]';

    test('reads the engine list and skips bad entries', () {
      expect(Camera.parseList(list).map((c) => c.name),
          ['FaceTime HD Camera', 'LifeCam']);
      expect(Camera.parseList('nonsense'), isEmpty);
    });

    test('only the test card goes without camera access', () {
      expect(needsCameraAccess('0x1100000046d0821'), isTrue);
      expect(needsCameraAccess(kTestPatternCamera), isFalse);
      expect(kTestPatternCamera, 'remotedisplay-test-pattern');
    });

    test('picks the one on, else the saved one, else the first', () {
      final cameras = Camera.parseList(list);
      expect(
          pickCamera(
                  cameras, const ForwardState(forward: 'on', device: 'b'), 'a')
              ?.id,
          'b');
      expect(pickCamera(cameras, const ForwardState(), 'b')?.id, 'b');
      expect(pickCamera(cameras, const ForwardState(), 'unplugged')?.id, 'a');
      expect(pickCamera(const [], const ForwardState(), 'a'), isNull);
    });
  });

  group('microphones', () {
    const list =
        '[{"id":"MacBook Pro Microphone","name":"MacBook Pro Microphone"},{"id":"USB Mic","name":"USB Mic"}]';

    test('reads the engine list and picks like cameras', () {
      final mics = Microphone.parseList(list);
      expect(mics.map((m) => m.name), ['MacBook Pro Microphone', 'USB Mic']);
      expect(
          pickMicrophone(mics, const ForwardState(), 'USB Mic')?.id, 'USB Mic');
      expect(pickMicrophone(mics, const ForwardState(), 'unplugged')?.id,
          'MacBook Pro Microphone');
    });
  });

  group('the sending badge', () {
    const off = ForwardState();
    const on = ForwardState(forward: 'on', device: 'cam-1');
    const asking = ForwardState(forward: 'asking', device: 'USB Mic');

    test('says what is sent and where, asking included', () {
      expect(sendingTooltip(on, off, host: 'Mac-mini'),
          'Sending your camera to Mac-mini');
      expect(sendingTooltip(off, asking, host: 'Mac-mini'),
          'Sending your microphone to Mac-mini');
      expect(sendingTooltip(asking, on, host: 'Mac-mini'),
          'Sending your camera and microphone to Mac-mini');
      expect(sendingTooltip(on, off, host: hostName(null)),
          "Sending your camera to the computer you're controlling");
    });

    test('is hidden while nothing is sent', () {
      expect(sendingTooltip(off, off, host: 'Mac-mini'), isNull);
      // Stopped on its own: off, whatever the reason.
      expect(
          sendingTooltip(const ForwardState(reason: 'busy'), off,
              host: 'Mac-mini'),
          isNull);
    });

    test('reads both kinds out of one engine event', () {
      const event =
          '{"camera":{"forward":"asking","device":"cam-1","reason":"","host":""},"microphone":{"forward":"on","device":"USB Mic","reason":"","host":"ready"}}';
      expect(
          sendingTooltip(ForwardState.parse(event, 'camera'),
              ForwardState.parse(event, 'microphone'),
              host: hostName('Mac-mini.local')),
          'Sending your camera and microphone to Mac-mini');
    });
  });

  group('the status line', () {
    // The engine's rd_device_forward state with the camera and the microphone.
    String state(
            {String camera = 'off',
            String cameraReason = '',
            String cameraHost = '',
            String mic = 'off',
            String micHost = ''}) =>
        jsonEncode({
          'camera': {
            'forward': camera,
            'device': camera == 'off' ? '' : 'cam-1',
            'reason': cameraReason,
            'host': cameraHost
          },
          'microphone': {
            'forward': mic,
            'device': mic == 'off' ? '' : 'USB Mic',
            'reason': '',
            'host': micHost
          },
        });
    String? notice(String before, String after,
            {String kind = 'camera',
            bool tip = false,
            String host = 'Mac-mini'}) =>
        forwardNotice(ForwardState.parse(before, kind),
            ForwardState.parse(after, kind), kind,
            hostIsMac: true, host: host, tip: tip);
    Map<String, String> feed(ForwardNotices notices, String json,
            {int epoch = 1, bool soundOn = false}) =>
        notices.forwards(json,
            epoch: epoch, hostIsMac: true, host: 'Mac-mini', soundOn: soundOn);
    const cameraTip =
        'Camera on · choose Remote Display Camera in the call on Mac-mini';
    const micTip =
        'Microphone on · choose Remote Display Microphone in the call on Mac-mini';
    const sharing =
        "Turn on camera sharing in Remote Display Server's Settings on Mac-mini";
    const echo = 'If the call hears itself, use headphones at a low volume';

    test('says the result of a tap', () {
      final asking = state(camera: 'asking');
      final on = state(camera: 'on');
      expect(notice(asking, on, tip: true), cameraTip);
      expect(notice(asking, on), 'Camera on');
      expect(
          notice(state(mic: 'asking'), state(mic: 'on'),
              kind: 'microphone', tip: true),
          micTip);
      expect(notice(asking, on, tip: true, host: hostName(null)),
          "Camera on · choose Remote Display Camera in the call on the computer you're controlling");
      expect(notice(asking, state(cameraReason: 'busy')),
          'Another controller is sending its camera to Mac-mini');
      expect(notice(asking, state(cameraReason: 'no-answer')),
          "Mac-mini didn't answer");
      // A camera that doesn't start never asks the host.
      expect(notice(state(), state(cameraReason: 'camera-failed')),
          "The camera didn't start");
    });

    test('says what stopped a forward, or changed under it', () {
      final on = state(camera: 'on');
      expect(notice(on, state(cameraReason: 'camera-lost')),
          'The camera was disconnected or stopped working');
      expect(
          notice(on, state(camera: 'on', cameraHost: 'not-allowed')), sharing);
      expect(
          notice(on,
              state(cameraReason: 'not-allowed', cameraHost: 'not-allowed')),
          sharing);
      expect(notice(on, state(camera: 'on', cameraHost: 'ready')), isNull);
    });

    test('leaves the rest to the menu', () {
      // Starting, switched off, another camera.
      expect(notice(state(), state(camera: 'asking')), isNull);
      expect(notice(state(camera: 'on'), state()), isNull);
      expect(notice(state(camera: 'on'), state(camera: 'asking')), isNull);
      // The host's status while off, and a reason already said.
      expect(notice(state(), state(cameraHost: 'not-allowed')), isNull);
      expect(
          notice(state(cameraReason: 'busy'),
              state(cameraReason: 'busy', cameraHost: 'ready')),
          isNull);
    });

    test('a dropped connection', () {
      expect(droppedNotice({'camera'}),
          'The connection dropped, so the camera turned off');
      expect(droppedNotice({'microphone'}),
          'The connection dropped, so the microphone turned off');
      expect(droppedNotice({'microphone', 'camera'}),
          'The connection dropped, so the camera and microphone turned off');
      expect(droppedNotice({}), isNull);
    });

    test('gives the device tip once a session', () {
      final n = ForwardNotices();
      expect(feed(n, state(camera: 'asking')), isEmpty);
      expect(feed(n, state(camera: 'on')), {'camera': cameraTip});
      n.switchingOff('camera');
      expect(feed(n, state()), isEmpty);
      feed(n, state(camera: 'asking'));
      expect(feed(n, state(camera: 'on')), {'camera': 'Camera on'});
      // The microphone has its own.
      feed(n, state(camera: 'on', mic: 'asking'));
      expect(feed(n, state(camera: 'on', mic: 'on')), {'microphone': micTip});
    });

    test("doesn't repeat itself, but answers each try", () {
      final n = ForwardNotices();
      feed(n, state(camera: 'asking'));
      feed(n, state(camera: 'on'));
      // The owner turns sharing off: the host's status, then the forward ends.
      expect(feed(n, state(camera: 'on', cameraHost: 'not-allowed')),
          {'camera': sharing});
      expect(
          feed(
              n, state(cameraReason: 'not-allowed', cameraHost: 'not-allowed')),
          isEmpty);
      // And on again; then refused twice, and said both times.
      expect(feed(n, state(cameraReason: 'not-allowed', cameraHost: 'ready')),
          isEmpty);
      const busy = 'Another controller is sending its camera to Mac-mini';
      for (var i = 0; i < 2; i++) {
        expect(feed(n, state(camera: 'asking', cameraHost: 'ready')), isEmpty);
        expect(feed(n, state(cameraReason: 'busy', cameraHost: 'ready')),
            {'camera': busy});
      }
    });

    test('gives the echo hint once a session', () {
      final n = ForwardNotices();
      feed(n, state(mic: 'asking'), soundOn: true);
      expect(feed(n, state(mic: 'on'), soundOn: true),
          {'microphone': micTip, 'echo': echo});
      n.switchingOff('microphone');
      feed(n, state(), soundOn: true);
      feed(n, state(mic: 'asking'), soundOn: true);
      expect(feed(n, state(mic: 'on'), soundOn: true),
          {'microphone': 'Microphone on'});
      expect(n.soundTurnedOn(), isEmpty);
    });

    test('gives the echo hint when the sound comes on with the microphone', () {
      final n = ForwardNotices();
      expect(n.soundTurnedOn(), isEmpty);
      feed(n, state(mic: 'asking'));
      expect(feed(n, state(mic: 'on')), {'microphone': micTip});
      expect(n.soundTurnedOn(), {'echo': echo});
      expect(n.soundTurnedOn(), isEmpty);
    });

    test('says a dropped connection turned the forwards off, once it is back',
        () {
      final n = ForwardNotices();
      feed(n, state(camera: 'asking', mic: 'asking'));
      feed(n, state(camera: 'on', mic: 'on'));
      // The connection ends: the engine reports both off, without a reason.
      expect(feed(n, state()), isEmpty);
      // A picture again from the same connection isn't the session coming back.
      expect(n.connected(1), isEmpty);
      expect(n.connected(2), {
        'connection':
            'The connection dropped, so the camera and microphone turned off'
      });
      expect(n.connected(3), isEmpty);
    });

    test('a switch-off from here is not a dropped connection', () {
      final n = ForwardNotices();
      feed(n, state(camera: 'asking'));
      feed(n, state(camera: 'on'));
      n.switchingOff('camera');
      expect(feed(n, state()), isEmpty);
      expect(n.connected(2), isEmpty);
    });

    test('an end heard after the next connection began is said at once', () {
      final n = ForwardNotices();
      feed(n, state(camera: 'asking'));
      feed(n, state(camera: 'on'));
      expect(feed(n, state(), epoch: 2),
          {'connection': 'The connection dropped, so the camera turned off'});
      expect(n.connected(2), isEmpty);
    });

    test('a forward turned on again is no longer counted as dropped', () {
      final n = ForwardNotices();
      feed(n, state(camera: 'asking'));
      feed(n, state(camera: 'on'));
      feed(n, state());
      feed(n, state(camera: 'asking'));
      expect(n.connected(2), isEmpty);
    });

    test("says once a session that the host won't take clicks and keys", () {
      final control = controlReason('unavailable', host: 'Mac-mini')!;
      final n = ForwardNotices();
      expect(n.connected(1), isEmpty);
      expect(n.connected(1, control: control), {'control': control});
      // The next connection's picture: the drop is said, the host isn't again.
      feed(n, state(camera: 'asking'));
      feed(n, state(camera: 'on'));
      feed(n, state());
      expect(n.connected(2, control: control),
          {'connection': 'The connection dropped, so the camera turned off'});
      // Forward lines keep their own key, so the status line shows both.
      expect(feed(n, state(camera: 'asking'), epoch: 2), isEmpty);
      expect(feed(n, state(camera: 'on'), epoch: 2), {'camera': 'Camera on'});
    });
  });
}
