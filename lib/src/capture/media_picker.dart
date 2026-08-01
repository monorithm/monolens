import 'package:image_picker/image_picker.dart';

import '../media/captured_media.dart';
import '../platform/monolens_platform.dart';

/// Imports existing media from the system gallery.
///
/// Separate from [CameraSession] because the two have nothing in common at
/// runtime: this is a one-shot call that hands back a file, the session is a
/// held device. An interface so a composer's tests never open a real picker;
/// [SystemMediaPicker] is the `image_picker` implementation.
abstract interface class MediaPicker {
  /// Picks one image. Null if the author cancelled.
  Future<CapturedImage?> pickImage();

  /// Picks one video. Null if the author cancelled.
  ///
  /// The clip is whatever the library holds — length and size are *not*
  /// checked here. A capped composer probes the result and either trims it or
  /// refuses it, which is why [CapturedVideo.duration] is populated on return.
  Future<CapturedVideo?> pickVideo();
}

class SystemMediaPicker implements MediaPicker {
  SystemMediaPicker({ImagePicker? picker, MonolensPlatform? platform})
    : _picker = picker ?? ImagePicker(),
      _platform = platform ?? MonolensPlatform.instance;

  final ImagePicker _picker;
  final MonolensPlatform _platform;

  @override
  Future<CapturedImage?> pickImage() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file == null) return null;
    final info = await _platform.probe(file.path);
    return CapturedImage.fromInfo(info, origin: MediaOrigin.gallery);
  }

  @override
  Future<CapturedVideo?> pickVideo() async {
    final file = await _picker.pickVideo(source: ImageSource.gallery);
    if (file == null) return null;
    final info = await _platform.probe(file.path);
    return CapturedVideo.fromInfo(info, origin: MediaOrigin.gallery);
  }
}
