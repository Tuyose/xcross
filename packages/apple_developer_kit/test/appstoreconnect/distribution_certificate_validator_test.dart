import 'package:apple_developer_kit/shared/appstoreconnect/distribution_certificate_validator.dart';
import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:test/test.dart';

void main() {
  late String certificatePem;
  late String matchingKeyPem;
  late String unrelatedKeyPem;

  setUpAll(() {
    // Small RSA keys are used only to keep unit tests fast.
    // Production CSR generation uses 2048-bit RSA.
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 1024);
    final privateKey = pair.privateKey as RSAPrivateKey;
    final publicKey = pair.publicKey as RSAPublicKey;

    final csr = X509Utils.generateRsaCsrPem(
      {'CN': 'xcross Test Distribution'},
      privateKey,
      publicKey,
    );

    certificatePem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      365,
      notBefore: DateTime.utc(2026),
    );

    matchingKeyPem = CryptoUtils.encodeRSAPrivateKeyToPem(privateKey);

    final unrelatedPair = CryptoUtils.generateRSAKeyPair(keySize: 1024);
    unrelatedKeyPem = CryptoUtils.encodeRSAPrivateKeyToPem(
      unrelatedPair.privateKey as RSAPrivateKey,
    );
  });

  test('accepts matching certificate and private key', () {
    expect(
      () => DistributionCertificateValidator.validate(
        certificatePem: certificatePem,
        privateKeyPem: matchingKeyPem,
      ),
      returnsNormally,
    );
  });

  test('rejects certificate and private key mismatch', () {
    expect(
      () => DistributionCertificateValidator.validate(
        certificatePem: certificatePem,
        privateKeyPem: unrelatedKeyPem,
      ),
      throwsA(
        isA<AppleError>().having(
          (AppleError error) => error.message,
          'message',
          contains('does not match'),
        ),
      ),
    );
  });

  test('rejects malformed certificate', () {
    expect(
      () => DistributionCertificateValidator.validate(
        certificatePem: 'INVALID CERTIFICATE',
        privateKeyPem: matchingKeyPem,
      ),
      throwsA(isA<AppleError>()),
    );
  });
}
