import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:daphq/services/update_service.dart';

void main() {
  group('UpdateService checksum & asset helpers (T-011)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('daphq_update_test_');
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    test('computeFileSha256 awaits full digest and returns lowercase 64-char hex', () async {
      final sampleFile = File(p.join(tempDir.path, 'installer.exe'));
      final bytes = utf8.encode('daphq release payload 2.3.1');
      await sampleFile.writeAsBytes(bytes);

      final expected = sha256.convert(bytes).toString().toLowerCase();
      final actual = await UpdateService.computeFileSha256(sampleFile.path);

      expect(actual, expected);
      expect(actual.length, 64);
      expect(actual, isNot(contains('Future')));
    });

    test('parseSha256Digest parses sha256sum line format and rejects invalid formats', () {
      const validHash =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

      expect(
        UpdateService.parseSha256Digest('${validHash.toUpperCase()}  daphq-v2.3.1.apk\n'),
        validHash,
      );
      expect(UpdateService.parseSha256Digest('  $validHash  '), validHash);
      expect(UpdateService.parseSha256Digest('not-a-hash'), isNull);
      expect(UpdateService.parseSha256Digest(''), isNull);
      expect(UpdateService.parseSha256Digest('abcd1234'), isNull);
    });

    test('findSha256AssetUrl finds matching sibling sha256 asset case-insensitively', () {
      final assets = [
        {
          'name': 'Daphq-v2.3.1-arm64.apk',
          'browser_download_url': 'https://example.com/Daphq-v2.3.1-arm64.apk',
        },
        {
          'name': 'Daphq-v2.3.1-arm64.apk.SHA256',
          'browser_download_url': 'https://example.com/Daphq-v2.3.1-arm64.apk.SHA256',
        },
      ];

      expect(
        UpdateService.findSha256AssetUrl(
          assets,
          'https://example.com/Daphq-v2.3.1-arm64.apk?download=1',
        ),
        'https://example.com/Daphq-v2.3.1-arm64.apk.SHA256',
      );
      expect(
        UpdateService.findSha256AssetUrl(assets, 'https://example.com/other.exe'),
        isEmpty,
      );
    });
  });
}

