import 'package:flutter_test/flutter_test.dart';

import 'package:daphq/controllers/receiver_controller.dart';

/// Security regression tests for plan T-001 (path traversal).
///
/// A malicious sender must never be able to place files outside the
/// receive directory via crafted relative paths in the transfer metadata.
void main() {
  group('ReceiverController.safeRelativePath — traversal rejection', () {
    test('rejects parent traversal (unix separators)', () {
      expect(ReceiverController.safeRelativePath('../../etc/passwd'), isNull);
    });

    test('rejects parent traversal (windows separators)', () {
      expect(
        ReceiverController.safeRelativePath(r'..\..\Windows\System32\evil.exe'),
        isNull,
      );
    });

    test('rejects traversal buried mid-path', () {
      expect(ReceiverController.safeRelativePath('docs/../../evil.txt'), isNull);
    });

    test('rejects bare parent reference', () {
      expect(ReceiverController.safeRelativePath('..'), isNull);
    });

    test('collapses current-directory prefix into a safe relative path', () {
      // './stealth.txt' normalizes to 'stealth.txt' — inside the receive
      // folder, so it is safe rather than rejected.
      expect(
        ReceiverController.safeRelativePath('./stealth.txt'),
        'stealth.txt',
      );
    });

    test('rejects absolute windows path with drive letter', () {
      expect(
        ReceiverController.safeRelativePath('C:/Windows/System32/evil.bat'),
        isNull,
      );
    });

    test('rejects absolute posix path', () {
      expect(ReceiverController.safeRelativePath('/etc/shadow'), isNull);
    });

    test('rejects empty path', () {
      expect(ReceiverController.safeRelativePath(''), isNull);
    });
  });

  group('ReceiverController.safeRelativePath — legitimate paths pass', () {
    test('plain file passes through unchanged', () {
      expect(
        ReceiverController.safeRelativePath('myFolder/sub/file.txt'),
        'myFolder/sub/file.txt',
      );
    });

    test('nested folder structure passes through', () {
      expect(
        ReceiverController.safeRelativePath('holiday/2026/beach/photo.jpg'),
        'holiday/2026/beach/photo.jpg',
      );
    });

    test('collapses redundant separators but stays inside', () {
      expect(
        ReceiverController.safeRelativePath('myFolder//nested///file.txt'),
        'myFolder/nested/file.txt',
      );
    });

    test('cleans windows-reserved names instead of failing', () {
      expect(
        ReceiverController.safeRelativePath('docs/CON.txt'),
        'docs/file_CON.txt',
      );
    });

    test('cleans illegal characters in inner segments', () {
      final result = ReceiverController.safeRelativePath('music/file:1.txt');
      expect(result, isNotNull);
      expect(result, isNot(contains(':')));
    });
  });
}
