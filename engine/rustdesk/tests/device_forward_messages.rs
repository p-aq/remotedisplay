//! remotedisplay: the camera and microphone forwarding messages in `message.proto`
//! (docs/specs/camera-audio-forwarding.md, decision 0017).

use base::message_proto::{
    device_forward_request::Kind, message, video_frame, CameraControl, CameraFrame,
    DeviceForwardRequest, DeviceForwardResponse, DeviceStatus, EncodedVideoFrame,
    EncodedVideoFrames, Message, VideoFrame,
};
use hbb_common::protobuf::{CodedOutputStream, Message as _, MessageField, MessageFull};

const OURS: [(&str, i32); 5] = [
    ("device_forward_request", 200),
    ("device_forward_response", 201),
    ("camera_frame", 202),
    ("camera_control", 203),
    ("device_status", 204),
];

fn wrap(union: message::Union) -> Message {
    Message {
        union: Some(union),
        ..Default::default()
    }
}

fn round_trip(msg: &Message) -> Message {
    Message::parse_from_bytes(&msg.write_to_bytes().unwrap()).unwrap()
}

#[test]
fn numbers_are_remote_displays() {
    let descriptor = Message::descriptor();
    for (name, number) in OURS {
        let field = descriptor.field_by_name(name).unwrap();
        assert_eq!(field.number(), number, "{name}");
    }
    // An engine update that brings an upstream message into 200-219 fails here.
    for field in descriptor.fields() {
        if (200..220).contains(&field.number()) {
            assert!(
                OURS.iter().any(|(name, _)| *name == field.name()),
                "{} uses Remote Display's number {}",
                field.name(),
                field.number()
            );
        }
    }
}

#[test]
fn each_message_survives_the_wire() {
    let annex_b = vec![
        0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65, 0x88,
    ];
    let frame = VideoFrame {
        union: Some(video_frame::Union::H264s(EncodedVideoFrames {
            frames: vec![EncodedVideoFrame {
                data: annex_b.into(),
                key: true,
                pts: 33,
                ..Default::default()
            }],
            ..Default::default()
        })),
        ..Default::default()
    };
    let messages = [
        wrap(message::Union::DeviceForwardRequest(DeviceForwardRequest {
            kind: Kind::CAMERA.into(),
            on: true,
            width: 1280,
            height: 720,
            fps: 30,
            device_name: "FaceTime HD Camera".into(),
            ..Default::default()
        })),
        wrap(message::Union::DeviceForwardResponse(
            DeviceForwardResponse {
                kind: Kind::MICROPHONE.into(),
                accepted: false,
                reason: "busy".into(),
                ..Default::default()
            },
        )),
        wrap(message::Union::CameraFrame(CameraFrame {
            frame: MessageField::some(frame),
            capture_time_us: 1_700_000_000_000_000,
            ..Default::default()
        })),
        wrap(message::Union::CameraControl(CameraControl {
            key_frame_request: true,
            target_bitrate_kbps: 1200,
            ..Default::default()
        })),
        wrap(message::Union::DeviceStatus(DeviceStatus {
            kind: Kind::CAMERA.into(),
            status: "not-approved".into(),
            ..Default::default()
        })),
    ];
    for msg in &messages {
        assert_eq!(&round_trip(msg), msg);
    }
}

#[test]
fn a_peer_ignores_numbers_it_doesnt_know() {
    // To a 1.0.x peer, 200-204 are unknown, as 219 (reserved, unused) is to this build.
    let status = DeviceStatus {
        kind: Kind::CAMERA.into(),
        status: "ready".into(),
        ..Default::default()
    };
    let mut bytes = Vec::new();
    {
        let mut os = CodedOutputStream::vec(&mut bytes);
        os.write_bytes(219, &status.write_to_bytes().unwrap())
            .unwrap();
        os.flush().unwrap();
    }
    let msg = Message::parse_from_bytes(&bytes).unwrap();
    assert!(msg.union.is_none());
}
