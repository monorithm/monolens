import 'package:flutter_test/flutter_test.dart';
import 'package:monolens/monolens.dart';

void main() {
  group('CropRect', () {
    test('centered fits the target ratio inside a wider source', () {
      // A 16:9 source, a 1:1 crop: full height, inset horizontally.
      final crop = CropRect.centered(aspectRatio: 1, sourceAspectRatio: 16 / 9);
      expect(crop.height, 1);
      expect(crop.width, closeTo(9 / 16, 1e-9));
      expect(crop.left, closeTo((1 - 9 / 16) / 2, 1e-9));
    });

    test('centered fits the target ratio inside a taller source', () {
      // A 9:16 source, a 1:1 crop: full width, inset vertically.
      final crop = CropRect.centered(aspectRatio: 1, sourceAspectRatio: 9 / 16);
      expect(crop.width, 1);
      expect(crop.height, closeTo(9 / 16, 1e-9));
      expect(crop.top, closeTo((1 - 9 / 16) / 2, 1e-9));
    });

    test('toRequest passes the fractions through untouched', () {
      const crop = CropRect(left: 0.25, top: 0.5, width: 0.5, height: 0.25);
      final rect = crop.toRequest();
      expect(rect.left, 0.25);
      expect(rect.top, 0.5);
      expect(rect.width, 0.5);
      expect(rect.height, 0.25);
    });

    test('toRequest clamps a rect that runs past the frame', () {
      // The platform should never have to reason about an out-of-range rect.
      const crop = CropRect(left: 0.9, top: 0.9, width: 0.5, height: 0.5);
      final rect = crop.toRequest();
      expect(rect.left + rect.width, lessThanOrEqualTo(1.0));
      expect(rect.top + rect.height, lessThanOrEqualTo(1.0));
    });

    test('clampedToBounds slides a rect back inside without resizing it', () {
      const crop = CropRect(left: 0.8, top: -0.2, width: 0.4, height: 0.4);
      final clamped = crop.clampedToBounds();
      expect(clamped.width, closeTo(0.4, 1e-9));
      expect(clamped.height, closeTo(0.4, 1e-9));
      expect(clamped.left, closeTo(0.6, 1e-9));
      expect(clamped.top, 0);
    });
  });

  group('ImageEdit', () {
    test('is identity only when nothing would change the pixels', () {
      expect(ImageEdit.none.isIdentity, isTrue);
      // Quality alone is a re-encode, not a transform.
      expect(const ImageEdit(quality: 50).isIdentity, isTrue);
      expect(
        const ImageEdit(rotation: MonoRotation.quarterTurn).isIdentity,
        isFalse,
      );
      expect(const ImageEdit(flipHorizontal: true).isIdentity, isFalse);
      expect(
        const ImageEdit(
          crop: CropRect(left: 0, top: 0, width: 0.5, height: 1),
        ).isIdentity,
        isFalse,
      );
    });

    test('rotatedClockwise cycles through all four turns', () {
      var edit = ImageEdit.none;
      expect(edit.rotation, MonoRotation.none);
      edit = edit.rotatedClockwise();
      expect(edit.rotation, MonoRotation.quarterTurn);
      edit = edit.rotatedClockwise();
      expect(edit.rotation, MonoRotation.halfTurn);
      edit = edit.rotatedClockwise();
      expect(edit.rotation, MonoRotation.threeQuarterTurns);
      edit = edit.rotatedClockwise();
      expect(edit.rotation, MonoRotation.none);
    });
  });

  group('VideoTrim', () {
    const source = Duration(seconds: 10);

    test('is identity only when it keeps the whole clip untouched', () {
      expect(VideoTrim.full(source).isIdentityFor(source), isTrue);
      expect(
        VideoEdit.full(source).isIdentityFor(source),
        isTrue,
        reason: 'an untouched clip needs no export',
      );
      expect(
        VideoEdit.full(source).toggledMute().isIdentityFor(source),
        isFalse,
        reason: 'muting changes the file even with the full range',
      );
      expect(
        const VideoTrim(
          start: Duration(seconds: 1),
          end: source,
        ).isIdentityFor(source),
        isFalse,
      );
    });

    test('clamps to the source', () {
      const trim = VideoTrim(
        start: Duration(seconds: -2),
        end: Duration(seconds: 30),
      );
      final clamped = trim.clamped(source);
      expect(clamped.start, Duration.zero);
      expect(clamped.end, source);
    });

    test('enforces the minimum by pushing the end when anchored to start', () {
      const trim = VideoTrim(
        start: Duration(seconds: 4),
        end: Duration(seconds: 4),
      );
      final clamped = trim.clamped(
        source,
        minimum: const Duration(milliseconds: 500),
      );
      expect(clamped.start, const Duration(seconds: 4));
      expect(clamped.end, const Duration(milliseconds: 4500));
    });

    test('enforces the minimum by pulling the start when anchored to end', () {
      const trim = VideoTrim(
        start: Duration(seconds: 4),
        end: Duration(seconds: 4),
      );
      final clamped = trim.clamped(
        source,
        minimum: const Duration(milliseconds: 500),
        anchorStart: false,
      );
      expect(clamped.start, const Duration(milliseconds: 3500));
      expect(clamped.end, const Duration(seconds: 4));
    });

    test('a minimum wider than the source collapses onto the source', () {
      final clamped = VideoTrim.full(
        const Duration(milliseconds: 300),
      ).clamped(const Duration(milliseconds: 300));
      expect(clamped.start, Duration.zero);
      expect(clamped.end, const Duration(milliseconds: 300));
    });

    test('caps the selection at the maximum, holding the anchored handle', () {
      const trim = VideoTrim(start: Duration(seconds: 1), end: source);
      final clamped = trim.clamped(source, maximum: const Duration(seconds: 5));
      expect(clamped.start, const Duration(seconds: 1));
      expect(clamped.end, const Duration(seconds: 6));

      final fromEnd = trim.clamped(
        source,
        maximum: const Duration(seconds: 5),
        anchorStart: false,
      );
      expect(fromEnd.start, const Duration(seconds: 5));
      expect(fromEnd.end, source);
    });
  });
}
