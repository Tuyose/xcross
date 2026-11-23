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
import 'package:xcross/src/shared/flutter/build/bundle_entitlements.dart';
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
    final hostPaths = host.paths;
    final fs = host.fileSystem;

    await verifyBundleId(
      appPath: appPath,
      bundleId: bundleId,
      fileSystem: fs,
      paths: host.paths,
    );

    // Extensions require their own App Store profiles. Discover them before
    // contacting Apple so malformed bundles fail without creating signing
    // material for a partial request.
    final extensions = embeddedExtensions(
      appPath: appPath,
      fileSystem: fs,
      paths: host.paths,
    );
    if (extensions.containsKey(bundleId)) {
      throw XcrossError(
        'App extension "$bundleId" has the same Bundle ID as the host app.',
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

    final certPath = paths.join(identity.identityDir, 'distribution-cert.pem');

    final keyPath = paths.join(identity.identityDir, 'distribution-key.pem');

    final statePath = paths.join(
      identity.identityDir,
      'distribution-state.json',
    );

    final certificateExists = fs.file(certPath).existsSync();
    final keyExists = fs.file(keyPath).existsSync();
    final stateExists = fs.file(statePath).existsSync();
    final profilePaths = <String, String>{
      bundleId: _profilePath(identity.profilesDir, bundleId, hostPaths),
      for (final extension in extensions.entries)
        extension.key: _profilePath(
          identity.profilesDir,
          extension.key,
          hostPaths,
        ),
    };
    final anyProfileExists = profilePaths.values.any(
      (path) => fs.file(path).existsSync(),
    );

    final identityComplete = certificateExists && keyExists && stateExists;

    final anyIdentityFile = certificateExists || keyExists || stateExists;

    // Never replace incomplete or inconsistent signing material.
    if (!identityComplete && (anyIdentityFile || anyProfileExists)) {
      throw XcrossError(
        'Incomplete App Store Distribution identity. '
        'Existing signing files were preserved.',
      );
    }

    final client = AscClient(
      credentials,
      httpClient: runtime.signingHttpClients.create(),
    );

    try {
      final provisioning = AscDistributionProvisioning(
        hostServices: hostServices,
        client: client,
      );

      if (!identityComplete) {
        // First use: create the certificate and the host profile. The
        // extension profiles below reuse this same Distribution certificate.
        await provisioning.provisionIdentity(
          bundleId: bundleId,
          identityDir: identity.identityDir,
          outputDir: paths.dirname(profilePaths[bundleId]!),
        );
      } else if (!fs.file(profilePaths[bundleId]!).existsSync()) {
        await provisioning.provisionProfileForExistingIdentity(
          bundleId: bundleId,
          identityDir: identity.identityDir,
          outputDir: paths.dirname(profilePaths[bundleId]!),
        );
      }

      for (final extension in extensions.entries) {
        final profilePath = profilePaths[extension.key]!;
        if (fs.file(profilePath).existsSync()) continue;
        await provisioning.provisionProfileForExistingIdentity(
          bundleId: extension.key,
          identityDir: identity.identityDir,
          outputDir: paths.dirname(profilePath),
        );
      }
    } finally {
      client.close();
    }

    final assetLoader = SigningAssetLoader(hostServices: hostServices);
    final appEntitlements = AppEntitlements(fileSystem: fs, paths: host.paths);
    final asset = await assetLoader.load(
      privateKeyPemPath: keyPath,
      certificatePemPath: certPath,
      provisioningProfilePath: profilePaths[bundleId]!,
      declaredEntitlements: appEntitlements.of(appPath),
      requireAppStoreProfile: true,
    );
    final extensionAssets = <String, SigningAsset>{};
    for (final extension in extensions.entries) {
      extensionAssets[extension.key] = await assetLoader.load(
        privateKeyPemPath: keyPath,
        certificatePemPath: certPath,
        provisioningProfilePath: profilePaths[extension.key]!,
        declaredEntitlements: appEntitlements.of(extension.value),
        requireAppStoreProfile: true,
      );
    }

    final signer = BundleSigner(
      asset,
      hostServices: hostServices,
      extensionAssets: extensionAssets,
    );

    // Validate the complete bundle before changing signing contents.
    await signer.preflight(appPath);

    await SignedBundlePreparer(
      fileSystem: fs,
      paths: host.paths,
    ).stripPrivateKeys(appPath);

    await signer.signApp(appPath);
  }

  /// Returns direct `PlugIns/*.appex` bundles keyed by their declared Bundle
  /// ID. The map is also used by tests to prove the host and every extension
  /// are discovered before provisioning starts.
  @visibleForTesting
  static Map<String, String> embeddedExtensions({
    required String appPath,
    required HostFileSystemInterface fileSystem,
    required HostPathsInterface paths,
  }) {
    final plugIns = fileSystem.directory(
      paths.context.join(appPath, 'PlugIns'),
    );
    if (!plugIns.existsSync()) return const {};

    final extensions = <String, String>{};
    for (final entity in plugIns.listSync(followLinks: false)) {
      if (entity is! Directory || !entity.path.endsWith('.appex')) continue;
      final infoPath = paths.context.join(entity.path, 'Info.plist');
      final info = fileSystem.file(infoPath);
      if (!info.existsSync()) {
        throw XcrossError('App extension Info.plist is missing: $infoPath');
      }

      final Object plist;
      try {
        plist = BundleEntitlements.parsePlist(info.readAsBytesSync());
      } on Object catch (error) {
        throw XcrossError(
          'App extension Info.plist is malformed: $infoPath ($error)',
        );
      }
      final bundleId = plist is Map ? plist['CFBundleIdentifier'] : null;
      if (bundleId is! String || bundleId.trim().isEmpty) {
        throw XcrossError(
          'App extension Info.plist has no CFBundleIdentifier: $infoPath',
        );
      }
      final normalized = bundleId.trim();
      if (extensions.containsKey(normalized)) {
        throw XcrossError(
          'Duplicate embedded app extension Bundle ID: $normalized',
        );
      }
      extensions[normalized] = entity.path;
    }
    return Map.unmodifiable(extensions);
  }

  static String _profilePath(
    String profilesDir,
    String bundleId,
    HostPathsInterface paths,
  ) => paths.context.join(
    profilesDir,
    bundleId,
    'distribution-profile.mobileprovision',
  );
}
