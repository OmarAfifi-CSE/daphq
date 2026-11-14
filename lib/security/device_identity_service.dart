import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Immutable cryptographic identity for this Daphq installation.
class DeviceIdentity {
  /// 16-char lowercase hex identifier derived from the certificate fingerprint.
  final String peerId;

  /// Full 64-char lowercase hex SHA-256 digest of the X.509 DER certificate.
  final String certFingerprint;

  final String certificatePem;
  final String privateKeyPem;

  const DeviceIdentity({
    required this.peerId,
    required this.certFingerprint,
    required this.certificatePem,
    required this.privateKeyPem,
  });

  /// Builds a fresh [SecurityContext] configured with this device's X.509
  /// certificate chain and private key in memory (no disk reads per handshake).
  SecurityContext createServerContext() {
    final context = SecurityContext();
    context.useCertificateChainBytes(utf8.encode(certificatePem));
    context.usePrivateKeyBytes(utf8.encode(privateKeyPem));
    return context;
  }

  /// Derives a symmetric 4-digit Short Authentication String (SAS) code
  /// guaranteed identical on both sides when given the two cert fingerprints.
  String computeSasWith(String remoteFingerprint) {
    return DeviceIdentityService.computeSasCode(
      certFingerprint,
      remoteFingerprint,
    );
  }
}

/// Manages generation, atomic persistence, and verification helpers for the
/// device's local ECDSA P-256 TLS identity.
class DeviceIdentityService {
  static const String _certFileName = 'daphq_identity_cert_v2.pem';
  static const String _keyFileName = 'daphq_identity_key_v2.pem';

  final Future<Directory> Function() _directoryProvider;
  Future<DeviceIdentity>? _inFlight;

  DeviceIdentityService({
    Future<Directory> Function()? directoryProvider,
  }) : _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  /// Loads the persisted TLS identity from disk, or generates and persists a
  /// new EC P-256 self-signed X.509 certificate if missing or corrupt.
  Future<DeviceIdentity> loadOrCreate() {
    _inFlight ??= _loadOrCreateInternal().whenComplete(() {
      _inFlight = null;
    });
    return _inFlight!;
  }

  Future<DeviceIdentity> _loadOrCreateInternal() async {
    final dir = await _directoryProvider();
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final certFile = File(p.join(dir.path, _certFileName));
    final keyFile = File(p.join(dir.path, _keyFileName));

    if (certFile.existsSync() && keyFile.existsSync()) {
      try {
        final certPem = await certFile.readAsString();
        final keyPem = await keyFile.readAsString();
        final derBytes = decodePemBody(certPem);
        if (derBytes.isNotEmpty && keyPem.contains('PRIVATE KEY')) {
          final fingerprint = sha256.convert(derBytes).toString();
          final identity = DeviceIdentity(
            peerId: fingerprint.substring(0, 16),
            certFingerprint: fingerprint,
            certificatePem: certPem,
            privateKeyPem: keyPem,
          );
          // Validate BoringSSL accepts the persisted material before returning.
          identity.createServerContext();
          return identity;
        }
      } catch (_) {
        // Corrupted identity files will be cleanly regenerated below.
      }
    }

    final pair = CryptoUtils.generateEcKeyPair(curve: 'prime256v1');
    final priv = pair.privateKey as ECPrivateKey;
    final pub = pair.publicKey as ECPublicKey;

    final csrPem = X509Utils.generateEccCsrPem(
      const {'CN': 'Daphq Peer', 'O': 'Daphq'},
      priv,
      pub,
      signingAlgorithm: 'SHA-256',
    );
    final certPem = X509Utils.generateSelfSignedCertificate(
      priv,
      csrPem,
      3650,
    );
    final keyPem = CryptoUtils.encodeEcPrivateKeyToPem(priv);

    await _atomicWrite(certFile, certPem);
    await _atomicWrite(keyFile, keyPem);

    final derBytes = decodePemBody(certPem);
    final fingerprint = sha256.convert(derBytes).toString();
    return DeviceIdentity(
      peerId: fingerprint.substring(0, 16),
      certFingerprint: fingerprint,
      certificatePem: certPem,
      privateKeyPem: keyPem,
    );
  }

  /// Extracts and decodes the Base64 DER payload from a PEM block.
  static Uint8List decodePemBody(String pem) {
    final lines = const LineSplitter()
        .convert(pem)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .join();
    if (lines.isEmpty) return Uint8List(0);
    return base64.decode(lines);
  }

  /// Computes the SHA-256 hex digest of an [X509Certificate]'s DER bytes.
  static String fingerprintOfCertificate(X509Certificate cert) {
    return sha256.convert(cert.der).toString();
  }

  /// Computes a symmetric, order-independent 4-digit SAS verification code
  /// from two peers' certificate SHA-256 hex fingerprints.
  static String computeSasCode(String fpA, String fpB) {
    final normalizedA = fpA.trim().toLowerCase();
    final normalizedB = fpB.trim().toLowerCase();
    final pair = normalizedA.compareTo(normalizedB) <= 0
        ? '$normalizedA|$normalizedB'
        : '$normalizedB|$normalizedA';
    final digest = Hmac(
      sha256,
      utf8.encode('daphq-sas-v2'),
    ).convert(utf8.encode(pair));
    final bytes = digest.bytes;
    final value =
        ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
        0x7fffffff;
    return (value % 10000).toString().padLeft(4, '0');
  }

  static String fingerprintFromCertificate(X509Certificate cert) {
    return sha256.convert(cert.der).toString().toLowerCase();
  }

  static String buildAuthProofMessage({
    required String sessionId,
    required String senderPeerId,
    required String senderFingerprint,
    required String serverFingerprint,
  }) {
    return 'daphq-v2-auth|${sessionId.trim()}|'
        '${senderPeerId.trim().toLowerCase()}|'
        '${senderFingerprint.trim().toLowerCase()}|'
        '${serverFingerprint.trim().toLowerCase()}';
  }

  /// Signs a TLS-bound v2 auth message using the device's EC P-256 private key.
  static String signAuthProof({
    required String privateKeyPem,
    required String message,
  }) {
    final privKey = CryptoUtils.ecPrivateKeyFromPem(privateKeyPem);
    final payloadBytes = Uint8List.fromList(utf8.encode(message));
    final sig = CryptoUtils.ecSign(
      privKey,
      payloadBytes,
      algorithmName: 'SHA-256/ECDSA',
    );
    return CryptoUtils.ecSignatureToBase64(sig);
  }

  /// Verifies [signatureB64] over [message] using [senderCertPem]'s EC public key
  /// and confirms the certificate DER SHA-256 matches [expectedFingerprint].
  static bool verifyAuthProof({
    required String senderCertPem,
    required String expectedFingerprint,
    required String message,
    required String signatureB64,
  }) {
    try {
      final normFp = expectedFingerprint.trim().toLowerCase();
      if (normFp.length != 64 || signatureB64.trim().isEmpty) return false;

      final certDer = CryptoUtils.getBytesFromPEMString(senderCertPem);
      final actualFp = sha256.convert(certDer).toString().toLowerCase();
      if (actualFp != normFp) return false;

      final x509 = X509Utils.x509CertificateFromPem(senderCertPem);
      final spkiHex = x509.tbsCertificate?.subjectPublicKeyInfo.bytes;
      if (spkiHex == null || spkiHex.isEmpty) return false;

      final pubKey = CryptoUtils.ecPublicKeyFromDerBytes(
        HexUtils.decode(spkiHex),
      );
      final payloadBytes = Uint8List.fromList(utf8.encode(message));
      return CryptoUtils.ecVerifyBase64(
        pubKey,
        payloadBytes,
        signatureB64,
        algorithm: 'SHA-256/ECDSA',
      );
    } catch (_) {
      return false;
    }
  }

  static Future<void> _atomicWrite(File target, String contents) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    try {
      tmp.renameSync(target.path);
    } on FileSystemException {
      final bak = File('${target.path}.bak');
      if (bak.existsSync()) {
        try {
          bak.deleteSync();
        } catch (_) {}
      }
      if (target.existsSync()) {
        target.renameSync(bak.path);
      }
      try {
        tmp.renameSync(target.path);
        if (bak.existsSync()) {
          try {
            bak.deleteSync();
          } catch (_) {}
        }
      } catch (e) {
        if (!target.existsSync() && bak.existsSync()) {
          try {
            bak.renameSync(target.path);
          } catch (_) {}
        }
        rethrow;
      }
    }
  }
}
