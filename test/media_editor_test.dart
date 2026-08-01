import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:monolens/monolens.dart';
import 'package:monolens/testing.dart';

void main() {
  late FakeMonolensPlatform platform;
  late MediaEditor editor;

  setUp(() {
    platform = FakeMonolensPlatform();
    editor = MonolensEditor(
      platform: platform,
      outputPath: (extension) async => '/out/result.$extension',
    );
  });

  tearDown(() => platform.dispose());

  group('applyImageEdit', () {
    test('sends the crop normalized, without probing the source', () async {
      await editor.applyImageEdit(
        '/in/photo.jpg',
        const ImageEdit(
          crop: CropRect(left: 0.5, top: 0, width: 0.5, height: 1),
        ),
      );

      final request = platform.imageEdits.single;
      expect(request.crop!.left, 0.5);
      expect(request.crop!.width, 0.5);
      expect(request.crop!.height, 1.0);
      expect(
        platform.probes,
        isEmpty,
        reason: 'the platform resolves the crop, so an edit is a single call',
      );
    });

    test('sends no crop at all for a full-frame edit', () async {
      // A null crop lets the native side skip the copy entirely.
      await editor.applyImageEdit(
        '/in/photo.jpg',
        const ImageEdit(rotation: MonoRotation.halfTurn),
      );
      expect(platform.imageEdits.single.crop, isNull);
    });

    test('picks the extension from the requested format', () async {
      await editor.applyImageEdit('/in/a.jpg', ImageEdit.none);
      expect(platform.imageEdits.last.outputPath, endsWith('.jpg'));

      await editor.applyImageEdit(
        '/in/a.jpg',
        const ImageEdit(format: MonoImageFormat.png),
      );
      expect(platform.imageEdits.last.outputPath, endsWith('.png'));
    });

    test('marks the result as an edit', () async {
      final result = await editor.applyImageEdit('/in/a.jpg', ImageEdit.none);
      expect(result.origin, MediaOrigin.edit);
      expect(result.path, '/out/result.jpg');
    });

    test('surfaces a platform failure as MediaEditException', () async {
      platform.nextImageEditError = PlatformException(
        code: 'monolens/decode-failed',
        message: 'Could not decode',
      );
      await expectLater(
        editor.applyImageEdit('/in/a.jpg', ImageEdit.none),
        throwsA(
          isA<MediaEditException>()
              .having((e) => e.code, 'code', 'monolens/decode-failed')
              .having((e) => e.message, 'message', 'Could not decode'),
        ),
      );
    });
  });

  group('startTrim', () {
    test('sends the range in milliseconds', () async {
      final job = editor.startTrim(
        '/in/clip.mp4',
        const VideoEdit(
          trim: VideoTrim(
            start: Duration(milliseconds: 1500),
            end: Duration(milliseconds: 3500),
          ),
          muteAudio: true,
        ),
      );
      await job.result;

      final request = platform.trims.single;
      expect(request.startMs, 1500);
      expect(request.endMs, 3500);
      expect(request.muteAudio, isTrue);
      expect(request.outputPath, endsWith('.mp4'));
    });

    test('reports the trimmed duration on the result', () async {
      final job = editor.startTrim(
        '/in/clip.mp4',
        const VideoEdit(
          trim: VideoTrim(
            start: Duration(seconds: 1),
            end: Duration(seconds: 4),
          ),
        ),
      );
      final result = await job.result;
      expect(result.duration, const Duration(seconds: 3));
      expect(result.origin, MediaOrigin.edit);
    });

    test('forwards progress for its own job only', () async {
      platform.progressTicks = const [0.2, 0.6, 0.9];
      final job = editor.startTrim('/in/clip.mp4', _range);

      final ticks = <double>[];
      job.progress.listen(ticks.add);
      await job.result;
      // Let the stream drain before asserting.
      await Future<void>.delayed(Duration.zero);

      expect(ticks, [0.2, 0.6, 0.9]);
    });

    test(
      'two concurrent exports do not cross their progress streams',
      () async {
        platform.progressTicks = const [0.5];
        final first = editor.startTrim('/in/a.mp4', _range);
        final second = editor.startTrim('/in/b.mp4', _range);

        final firstTicks = <double>[];
        final secondTicks = <double>[];
        first.progress.listen(firstTicks.add);
        second.progress.listen(secondTicks.add);

        await Future.wait([first.result, second.result]);
        await Future<void>.delayed(Duration.zero);

        expect(first.id, isNot(second.id));
        expect(firstTicks, hasLength(1));
        expect(secondTicks, hasLength(1));
      },
    );

    test('cancel completes the job with TrimCancelled', () async {
      platform.exportDuration = const Duration(milliseconds: 20);
      final job = editor.startTrim('/in/clip.mp4', _range);

      await job.cancel();
      await expectLater(job.result, throwsA(isA<TrimCancelled>()));
      expect(platform.cancellations, [job.id]);
    });

    test(
      'a failed export surfaces as MediaEditException, not TrimCancelled',
      () async {
        platform.nextTrimError = PlatformException(
          code: 'monolens/export-failed',
          message: 'Encoder busy',
        );
        final job = editor.startTrim('/in/clip.mp4', _range);
        await expectLater(job.result, throwsA(isA<MediaEditException>()));
      },
    );
  });

  group('filmstrip', () {
    test('samples frame centres rather than the clip edges', () async {
      // The first and last frames of a clip are often a black lead-in or a
      // blurred stop; centres give a strip that reads as the content.
      final platform = _RecordingPlatform();
      final editor = MonolensEditor(platform: platform);

      await editor.filmstrip(
        '/in/clip.mp4',
        duration: const Duration(milliseconds: 1000),
        frames: 4,
      );

      expect(platform.requestedAt, [125, 375, 625, 875]);
      platform.dispose();
    });

    test('returns one frame per requested timestamp', () async {
      final frames = await editor.filmstrip(
        '/in/clip.mp4',
        duration: const Duration(seconds: 5),
        frames: 6,
      );
      expect(frames, hasLength(6));
    });
  });
}

const VideoEdit _range = VideoEdit(
  trim: VideoTrim(start: Duration.zero, end: Duration(seconds: 2)),
);

class _RecordingPlatform extends FakeMonolensPlatform {
  List<int> requestedAt = const [];

  @override
  Future<List<Uint8List>> videoThumbnails(
    String path,
    List<int> atMs,
    int maxDimension,
  ) {
    requestedAt = atMs;
    return super.videoThumbnails(path, atMs, maxDimension);
  }
}
