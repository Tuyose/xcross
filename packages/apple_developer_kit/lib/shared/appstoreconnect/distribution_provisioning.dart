import 'dart:convert';

import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/appstoreconnect.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/distribution_certificate_validator.dart';
import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:apple_developer_kit/src/shared/appstoreconnect/asc_csr.dart';
import 'package:apple_developer_kit/src/shared/secure/secure_file.dart';

/// Paths to a separately stored Apple Distribution signing identity.
final class DistributionIdentityPaths {
  const DistributionIdentityPaths({
    required this.certificatePemPath,
    required this.privateKeyPemPath,
    required this.profilePath,
  });

  final String certificatePemPath;
  final String privateKeyPemPath;
  final String profilePath;
}

/// Provisions App Store signing material without revoking certificates
/// or deleting existing provisioning profiles.
final class AscDistributionProvisioning {
  const AscDistributionProvisioning({
    required this.hostServices,
    required this.client,
  });

  final AppleHostServices hostServices;
  final AscClient client;

  Future<DistributionIdentityPaths> provisionIdentity({
    required String bundleId,
    required String identityDir,
    required String outputDir,
  }) async {
    final fs = hostServices.host.fileSystem;
    final paths = hostServices.host.paths.context;

    final certPath = paths.join(identityDir, 'distribution-cert.pem');
    final keyPath = paths.join(identityDir, 'distribution-key.pem');
    final statePath = paths.join(identityDir, 'distribution-state.json');
    final profilePath = paths.join(
      outputDir,
      'distribution-profile.mobileprovision',
    );

    // Never overwrite existing Distribution signing material.
    for (final path in [certPath, keyPath, statePath, profilePath]) {
      if (fs.file(path).existsSync()) {
        throw AppleError(
          'Distribution signing file already exists: $path. '
          'Refusing to overwrite existing signing material.',
        );
      }
    }

    final bundle = await client.findBundleId(bundleId);
    if (bundle == null) {
      throw AppleError(
        'Bundle ID "$bundleId" is not registered with Apple. '
        'Register it before creating a Distribution identity.',
      );
    }

    await fs.directory(identityDir).create(recursive: true);
    await fs.directory(outputDir).create(recursive: true);

    // Keep the private key locally. Apple only receives the CSR.
    final csr = AscCsr.generate(commonName: 'xcross Distribution');

    await AscCsr.writePrivateKeyPem(
      keyPath,
      AscCsr.privateKeyToPem(csr.privateKey),
      hostServices: hostServices,
    );

    // No certificate revocation or automatic quota retry.
    final certificate = await client.createDistributionCertificate(
      csrPem: csr.csrPem,
    );

    final certificatePem = AscProvisioning.wrapDerAsPem(
      certificate.certificateContentBase64,
    );

    // Reject mismatched certificates before creating a profile.
    DistributionCertificateValidator.validate(
      certificatePem: certificatePem,
      privateKeyPem: await fs.file(keyPath).readAsString(),
    );

    await fs.file(certPath).writeAsString(certificatePem);

    await SecureFile(hostServices: hostServices).writeString(
      statePath,
      jsonEncode({
        'certificateId': certificate.id,
        'certificateSerialNumber': certificate.serialNumber,
        'certificateExpirationDate': certificate.expirationDate,
      }),
    );

    final serialNumber = certificate.serialNumber;
    if (serialNumber == null || serialNumber.isEmpty) {
      throw const AppleError(
        'Apple Distribution certificate has no serial number. '
        'Signing material was preserved for recovery.',
      );
    }

    // Resolve the team-side certificate resource ID by serial number.
    final certificateIds = await client.findCertificateIdsBySerial(
      serialNumber,
    );

    if (certificateIds.length != 1) {
      throw AppleError(
        'Expected exactly one Distribution certificate with serial '
        '$serialNumber, found ${certificateIds.length}. '
        'Existing signing material was preserved.',
      );
    }

    final profile = await client.createProfile(
      name: 'xcross Distribution ${DateTime.now().microsecondsSinceEpoch}',
      bundleIdResourceId: bundle.id,
      certificateResourceIds: certificateIds,
      deviceResourceIds: const [],
      profileType: 'IOS_APP_STORE',
    );

    await fs
        .file(profilePath)
        .writeAsBytes(base64.decode(profile.profileContentBase64));

    return DistributionIdentityPaths(
      certificatePemPath: certPath,
      privateKeyPemPath: keyPath,
      profilePath: profilePath,
    );
  }
}
