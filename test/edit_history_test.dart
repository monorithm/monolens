import 'package:flutter_test/flutter_test.dart';
import 'package:monolens/monolens.dart';

void main() {
  group('EditHistory', () {
    test('starts with nothing to undo', () {
      final history = EditHistory(ImageEdit.none);
      expect(history.canUndo, isFalse);
      expect(history.canRedo, isFalse);
      history.dispose();
    });

    test('undo and redo walk the values', () {
      final history = EditHistory(ImageEdit.none);
      final rotated = ImageEdit.none.rotatedClockwise();
      final flipped = rotated.copyWith(flipHorizontal: true);

      history.push(rotated);
      history.push(flipped);
      expect(history.value, flipped);

      history.undo();
      expect(history.value, rotated);
      history.undo();
      expect(history.value, ImageEdit.none);
      expect(history.canUndo, isFalse);

      history.redo();
      expect(history.value, rotated);
      history.dispose();
    });

    test('pushing the same value is not a step', () {
      final history = EditHistory(ImageEdit.none);
      history.push(ImageEdit.none);
      expect(history.canUndo, isFalse);
      history.dispose();
    });

    test('a value equal to the current one is not a step either', () {
      // The test above passes on identity alone: `ImageEdit.none` is a const,
      // so both references are the same canonical instance and `==` is never
      // consulted. This one builds a distinct instance that is merely *equal*,
      // which is what every real edit produces -- `copyWith` never returns the
      // receiver.
      final history = EditHistory(ImageEdit.none);

      // Four quarter turns is a full turn, so this lands back on the identity
      // edit by value while being a different object.
      var turned = ImageEdit.none;
      for (var i = 0; i < 4; i++) {
        turned = turned.rotatedClockwise();
      }

      expect(identical(turned, ImageEdit.none), isFalse);
      history.push(turned);
      expect(
        history.canUndo,
        isFalse,
        reason: 'a no-op edit should not cost an undo press',
      );
      history.dispose();
    });

    test('a drag sample that did not move is not a step', () {
      // A drag emits a value per pointer sample, and a finger that pauses emits
      // several identical ones. Those must compare equal through the whole
      // aggregate -- edit, annotation list, and the annotation itself -- or a
      // pause mid-drag quietly costs undo presses.
      final sticker = StickerAnnotation(
        imagePath: 'sticker.png',
        rect: const CropRect(left: 0.1, top: 0.1, width: 0.2, height: 0.2),
      );
      final start = ImageEdit.none.withAnnotation(sticker);
      final history = EditHistory(start);

      final unmoved = ImageEdit.none.withAnnotation(
        sticker.copyWith(rect: sticker.rect),
      );
      expect(identical(unmoved, start), isFalse);

      history.push(unmoved);
      expect(
        history.canUndo,
        isFalse,
        reason: 'an unchanged sample should not cost an undo press',
      );
      history.dispose();
    });

    test('a new edit drops the redo stack', () {
      // Otherwise redo would jump to a future that no longer follows from the
      // present.
      final history = EditHistory(ImageEdit.none);
      history.push(ImageEdit.none.rotatedClockwise());
      history.undo();
      expect(history.canRedo, isTrue);

      history.push(const ImageEdit(flipHorizontal: true));
      expect(history.canRedo, isFalse);
      history.dispose();
    });

    test('a coalesced run is one undo step', () {
      // A drag emits hundreds of values; going back should undo the gesture,
      // not one sample of it.
      final history = EditHistory(ImageEdit.none);
      for (var i = 1; i <= 50; i++) {
        history.push(
          ImageEdit(crop: CropRect(left: 0, top: 0, width: i / 100, height: 1)),
          coalesceKey: 'crop',
        );
      }
      expect(history.depth, 1);

      history.undo();
      expect(history.value, ImageEdit.none);
      history.dispose();
    });

    test('commit ends a run so the next drag is its own step', () {
      final history = EditHistory(ImageEdit.none);
      history.push(const ImageEdit(quality: 80), coalesceKey: 'q');
      history.commit();
      history.push(const ImageEdit(quality: 60), coalesceKey: 'q');
      expect(history.depth, 2);
      history.dispose();
    });

    test('the depth limit discards the oldest entries', () {
      final history = EditHistory(ImageEdit.none, limit: 3);
      for (var i = 1; i <= 10; i++) {
        history.push(ImageEdit(quality: i));
      }
      expect(history.depth, 3);
      history.dispose();
    });

    test('notifies listeners on every change', () {
      final history = EditHistory(ImageEdit.none);
      var notifications = 0;
      history.addListener(() => notifications++);

      history.push(const ImageEdit(quality: 50));
      history.undo();
      history.redo();
      expect(notifications, 3);
      history.dispose();
    });

    test('reset is itself undoable', () {
      final history = EditHistory(ImageEdit.none);
      history.push(const ImageEdit(flipHorizontal: true));
      history.reset();
      expect(history.value, ImageEdit.none);

      history.undo();
      expect(history.value.flipHorizontal, isTrue);
      history.dispose();
    });

    test('clearHistory keeps the value and drops the steps', () {
      final history = EditHistory(ImageEdit.none);
      history.push(const ImageEdit(flipHorizontal: true));
      history.clearHistory();

      expect(history.value.flipHorizontal, isTrue);
      expect(history.canUndo, isFalse);
      history.dispose();
    });

    test('drives a VideoEdit just as well as an ImageEdit', () {
      // The control is generic because both are plain values.
      final history = EditHistory(VideoEdit.full(const Duration(seconds: 10)));
      history.push(history.value.toggledMute());
      expect(history.value.muteAudio, isTrue);

      history.undo();
      expect(history.value.muteAudio, isFalse);
      history.dispose();
    });
  });
}
