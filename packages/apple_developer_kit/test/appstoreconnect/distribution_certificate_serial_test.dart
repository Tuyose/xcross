import 'package:apple_developer_kit/shared/appstoreconnect/distribution_certificate_validator.dart';
import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:apple_developer_kit/src/shared/appstoreconnect/asc_csr.dart';
import 'package:basic_utils/basic_utils.dart';
import 'package:test/test.dart';

void main() {
  late String certificatePem;

  setUpAll(() {
    final csr = AscCsr.generate(commonName: 'xcross Distribution');

    certificatePem = X509Utils.generateSelfSignedCertificate(
      csr.privateKey,
      csr.csrPem,
      365,
      serialNumber: '11256099',
    );
  });

  test('accepts the correct certificate serial number', () {
    expect(
      () => DistributionCertificateValidator.validateSerialNumber(
        certificatePem: certificatePem,
        expectedSerialNumber: 'ABC123',
      ),
      returnsNormally,
    );
  });

  test('accepts lowercase hex and leading zeroes', () {
    expect(
      () => DistributionCertificateValidator.validateSerialNumber(
        certificatePem: certificatePem,
        expectedSerialNumber: '00abc123',
      ),
      returnsNormally,
    );
  });

  test('rejects a mismatched certificate serial number', () {
    expect(
      () => DistributionCertificateValidator.validateSerialNumber(
        certificatePem: certificatePem,
        expectedSerialNumber: 'DEADBEEF',
      ),
      throwsA(isA<AppleError>()),
    );
  });

  test('rejects malformed certificate serial numbers', () {
    expect(
      () => DistributionCertificateValidator.validateSerialNumber(
        certificatePem: certificatePem,
        expectedSerialNumber: 'NOT-A-SERIAL',
      ),
      throwsA(isA<AppleError>()),
    );
  });
}
