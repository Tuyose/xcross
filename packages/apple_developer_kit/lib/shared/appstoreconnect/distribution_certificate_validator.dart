import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:apple_developer_kit/src/shared/signing/der.dart';
import 'package:apple_developer_kit/src/shared/signing/x509.dart';

/// Verifies that an RSA signing certificate belongs to its private key.
abstract final class DistributionCertificateValidator {
  static void validate({
    required String certificatePem,
    required String privateKeyPem,
  }) {
    final certificate = parseCertificatePem(
      certificatePem,
      'distribution-cert.pem',
    );

    final privateKey = parsePrivateKey(privateKeyPem, 'distribution-key.pem');

    final publicKey = certificate.publicKey;

    if (publicKey == null ||
        privateKey.modulus != publicKey.modulus ||
        privateKey.publicExponent != publicKey.publicExponent) {
      throw const AppleError(
        'Distribution private key does not match certificate.',
      );
    }
  }

  /// Verifies that the Apple API/state serial belongs to the PEM certificate.
  static void validateSerialNumber({
    required String certificatePem,
    required String expectedSerialNumber,
  }) {
    final certificate = parseCertificatePem(
      certificatePem,
      'distribution-cert.pem',
    );

    final encoded = Der.single(
      certificate.serialNumber,
      DerTag.integer,
      'Distribution certificate serial number',
    );

    final actual = Der.positiveInteger(
      encoded,
      'Distribution certificate serial number',
    );

    // Apple certificate serial numbers use hexadecimal notation.
    // Numeric comparison permits different case and leading zeroes.
    final expected = BigInt.tryParse(expectedSerialNumber.trim(), radix: 16);

    if (expected == null || expected != actual) {
      throw const AppleError(
        'Distribution certificate serial number does not match '
        'Apple identity state.',
      );
    }
  }
}
