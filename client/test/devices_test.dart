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
          "The computer you're controlling hasn't turned on camera sharing");
      expect(
          hostReason('not-installed', 'camera',
              hostIsMac: true, host: fallback),
          "Remote Display Camera isn't installed on the computer you're controlling");
    });

    test('the host', () {
      expect(hostReason('ready', 'camera', hostIsMac: true, host: 'Mac-mini'),
          isNull);
      expect(
          hostReason('not-allowed', 'camera',
              hostIsMac: true, host: 'Mac-mini'),
          "Mac-mini hasn't turned on camera sharing");
      expect(
          hostReason('not-installed', 'microphone',
              hostIsMac: true, host: 'Mac-mini'),
          "Remote Display Microphone isn't installed on Mac-mini");
      expect(
          hostReason('not-approved', 'camera',
              hostIsMac: true, host: 'Mac-mini'),
          'Remote Display Camera is waiting for approval on Mac-mini');
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
          'Use headphones, or the call hears its own echo');
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
}
