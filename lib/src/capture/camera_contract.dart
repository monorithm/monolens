import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show ValueListenable;

import '../media/captured_media.dart';

/// Which capture the viewfinder is armed for. Switching re-opens the device,
/// because video needs the microphone and a still does not — asking for the mic
/// up front makes a photo-only author grant a permission they never use.
enum CameraCaptureMode { photo, video }

enum CameraFacing { back, front }

enum CameraFlash { off, auto, on }

/// The result of opening the device.
///
/// monolens deliberately does not depend on a permissions plugin: an app
/// usually already has one, and two competing requesters produce two prompts.
/// The session reports what it found and the host decides what to show.
enum CameraAccess {
  granted,
  denied,

  /// Denied with "don't ask again" — the host should deep-link to Settings.
  permanentlyDenied,

  /// No camera on the device, or it is held by another app.
  unavailable,
}

/// The viewfinder as data: everything needed to draw it, without monolens
/// drawing it.
///
/// The plugin is headless: it hands back the texture the platform is streaming
/// frames into and the geometry needed to orient it, and the host renders
/// `Texture(textureId: …)` inside whatever its own design system dictates.
class PreviewTexture {
  const PreviewTexture({
    required this.textureId,
    required this.size,
    required this.sensorOrientation,
    required this.facing,
  });

  /// Pass to a `Texture` widget.
  ///
  /// Zero is a perfectly valid id — an iPhone reports exactly that for its
  /// first session — so test for a null [CameraSession.preview] rather than for
  /// a falsy id.
  final int textureId;

  /// The stream's dimensions, in sensor orientation — so for a phone held
  /// upright this is usually landscape even though the preview reads portrait.
  final Size size;

  /// Degrees clockwise the sensor is mounted relative to the device's natural
  /// orientation. Combine with the current device orientation to rotate the
  /// texture; on iOS this is 90 for both lenses and the platform has already
  /// applied it, so only Android normally needs the correction.
  final int sensorOrientation;

  /// Which lens is streaming. A front lens is mirrored on screen by
  /// convention — the host applies that, since it is a presentation choice.
  final CameraFacing facing;

  /// [size] turned into the aspect ratio the preview should occupy on screen.
  double get aspectRatio {
    final turned = sensorOrientation == 90 || sensorOrientation == 270;
    final width = turned ? size.height : size.width;
    final height = turned ? size.width : size.height;
    return height == 0 ? 1 : width / height;
  }
}

/// A live camera — a stateful, lifecycle-bound resource, unlike the stateless
/// [MediaPicker] that returns a file and forgets.
///
/// An interface so a composer is testable without a device;
/// [MonolensCameraSession] is the implementation and `FakeCameraSession` (in
/// `package:monolens/testing.dart`) is the test double.
abstract interface class CameraSession {
  /// Opens the device for [mode], claiming the microphone only when [mode] is
  /// [CameraCaptureMode.video]. Safe to call again to switch mode.
  Future<CameraAccess> initialize(CameraCaptureMode mode);

  /// The texture and geometry to render, or null before [initialize] completes.
  PreviewTexture? get preview;

  bool get isInitialized;
  CameraCaptureMode get mode;
  CameraFacing get facing;
  CameraFlash get flash;

  /// True while a recording is running. Also the auto-stop signal: the session
  /// clears this on its own when [startVideoRecording]'s cap is reached, and
  /// the host then calls [stopVideoRecording] to collect the file.
  ValueListenable<bool> get isRecording;

  /// How long the running recording has been going, for an on-screen timer.
  /// Resets to zero when recording stops.
  ValueListenable<Duration> get recordedDuration;

  Future<void> flip();
  Future<void> cycleFlash();

  Future<CapturedImage> capturePhoto();

  /// Starts recording, auto-stopping at [maxDuration] so a capped composer
  /// never has to police the length after the fact.
  Future<void> startVideoRecording({Duration? maxDuration});

  Future<CapturedVideo> stopVideoRecording();

  /// Releases the device when the app backgrounds or an edit step opens;
  /// [resumePreview] reopens it.
  Future<void> pausePreview();
  Future<void> resumePreview();

  Future<void> dispose();
}

/// Mints a fresh [CameraSession]. Provided by the host so tests inject a fake.
typedef CameraSessionFactory = CameraSession Function();
