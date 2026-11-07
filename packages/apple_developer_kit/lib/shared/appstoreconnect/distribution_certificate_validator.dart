import 'package:apple_developer_kit/shared/errors/errors.dart';
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
}
