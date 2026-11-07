import 'dart:io';

import 'package:apple_developer_kit/shared/appstoreconnect/asc_client.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/asc_config.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/distribution_provisioning.dart';
import 'package:apple_developer_kit/shared/signing/bundle_signer.dart';
import 'package:apple_developer_kit/shared/signing/signing_asset.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/artifact/app_entitlements.dart';
import 'package:xcross/src/shared/artifact/plist_mutations.dart';
import 'package:xcross/src/shared/auth/signing_session.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/target/iphone/device/signed_bundle_preparer.dart';

/// Signs a built iOS app with a separate App Store Distribution identity.
@internal
final class AppStoreIpaSigningOperation<T extends PlatformHostInterface> {
  const AppStoreIpaSigningOperation(this.runtime);

  final XcrossRuntime<T> runtime;

  /// Checks the built app's actual Bundle ID before any Apple API call.
  @visibleForTesting
  static Future<void> verifyBundleId({
    required String appPath,
    required String bundleId,
    required HostFileSystemInterface fileSystem,
    required HostPathsInterface paths,
  }) async {
    final plistFile = fileSystem.file(
      paths.context.join(appPath, 'Info.plist'),
    );

    if (!plistFile.existsSync()) {
      throw XcrossError('App Store signing refused: Info.plist is missing.');
    }

    final actual = PlistMutations.readBundleIdentifier(
      await plistFile.readAsString(),
    );

    if (actual != bundleId) {
      throw XcrossError(
        'App Store signing refused: expected Bundle ID "$bundleId", '
        'but the app declares "${actual ?? 'missing'}".',
      );
    }
  }

  Future<void> sign({required String appPath, required String bundleId}) async {
    final host = runtime.host;
    final hostServices = runtime.appleHostServices;
    final paths = host.paths.context;
    final fs = host.fileSystem;

    await verifyBundleId(
      appPath: appPath,
      bundleId: bundleId,
      fileSystem: fs,
      paths: host.paths,
    );

    // Extensions require their own App Store profiles.
    // Never sign them with the host application's certificate/profile.
    final plugIns = fs.directory(paths.join(appPath, 'PlugIns'));
    if (plugIns.existsSync() &&
        plugIns.listSync().any(
          (entity) => entity is Directory && entity.path.endsWith('.appex'),
        )) {
      throw XcrossError(
        'App Store IPA signing of embedded app extensions '
        'is not supported yet.',
      );
    }

    final credentials = await AscCredentialsLoader(
      hostServices: hostServices,
    ).load();

    final configPath = AscCredentials.defaultConfigPath(
      hostServices: hostServices,
    );

    final configDir = paths.dirname(configPath);

    final identity = SigningIdentity(
      identityId: credentials.issuerId,
      identityDir: SigningSession.identityDirFor(
        configDir,
        'appstoreconnect-${credentials.issuerId}',
      ),
    );

    final profileDir = paths.join(identity.profilesDir, bundleId);

    final certPath = paths.join(identity.identityDir, 'distribution-cert.pem');

    final keyPath = paths.join(identity.identityDir, 'distribution-key.pem');

    final statePath = paths.join(
      identity.identityDir,
      'distribution-state.json',
    );

    final profilePath = paths.join(
      profileDir,
      'distribution-profile.mobileprovision',
    );

    final certificateExists = fs.file(certPath).existsSync();
    final keyExists = fs.file(keyPath).existsSync();
    final stateExists = fs.file(statePath).existsSync();
    final profileExists = fs.file(profilePath).existsSync();

    final identityComplete = certificateExists && keyExists && stateExists;

    final anyIdentityFile = certificateExists || keyExists || stateExists;

    // Never replace incomplete or inconsistent signing material.
    if (!identityComplete && (anyIdentityFile || profileExists)) {
      throw XcrossError(
        'Incomplete App Store Distribution identity. '
        'Existing signing files were preserved.',
      );
    }

    if (!profileExists) {
      final client = AscClient(
        credentials,
        httpClient: runtime.signingHttpClients.create(),
      );

      try {
        final provisioning = AscDistributionProvisioning(
          hostServices: hostServices,
          client: client,
        );

        if (identityComplete) {
          // Reuse the certificate; create only the missing profile.
          await provisioning.provisionProfileForExistingIdentity(
            bundleId: bundleId,
            identityDir: identity.identityDir,
            outputDir: profileDir,
          );
        } else {
          // First use: create the certificate and profile.
          await provisioning.provisionIdentity(
            bundleId: bundleId,
            identityDir: identity.identityDir,
            outputDir: profileDir,
          );
        }
      } finally {
        client.close();
      }
    }

    final entitlements = AppEntitlements(
      fileSystem: fs,
      paths: host.paths,
    ).of(appPath);

    final asset = await SigningAssetLoader(hostServices: hostServices).load(
      privateKeyPemPath: keyPath,
      certificatePemPath: certPath,
      provisioningProfilePath: profilePath,
      declaredEntitlements: entitlements,
      requireAppStoreProfile: true,
    );

    final signer = BundleSigner(asset, hostServices: hostServices);

    // Validate the complete bundle before changing signing contents.
    await signer.preflight(appPath);

    await SignedBundlePreparer(
      fileSystem: fs,
      paths: host.paths,
    ).stripPrivateKeys(appPath);

    await signer.signApp(appPath);
  }
}
