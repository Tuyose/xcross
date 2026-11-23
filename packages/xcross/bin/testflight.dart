import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/asc_config.dart';
import 'package:apple_developer_kit/shared/appstoreconnect/build_upload.dart';
import 'package:archive/archive_io.dart';
import 'package:args/args.dart';
import 'package:cli_kit/composition/native_host.dart';
import 'package:path/path.dart' as p;
import 'package:propertylistserialization/propertylistserialization.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('project', defaultsTo: Directory.current.path)
    ..addOption('ipa')
    ..addFlag('build', negatable: false)
    ..addFlag('upload', negatable: false)
    ..addFlag('wait', negatable: false)
    ..addOption('app-id', defaultsTo: Platform.environment['XCROSS_ASC_APP_ID'])
    ..addOption(
      'issuer-id',
      defaultsTo: Platform.environment['XCROSS_ASC_ISSUER_ID'],
    )
    ..addOption('key-id', defaultsTo: Platform.environment['XCROSS_ASC_KEY_ID'])
    ..addOption(
      'private-key',
      defaultsTo: Platform.environment['XCROSS_ASC_PRIVATE_KEY'],
    )
    ..addOption('xcross-command', defaultsTo: 'xcross')
    ..addOption('concurrency', defaultsTo: '4')
    ..addOption('poll-seconds', defaultsTo: '30')
    ..addOption('timeout-minutes', defaultsTo: '60')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(parser.usage);
    exitCode = 2;
    return;
  }
  if (options['help'] as bool) {
    stdout.writeln(parser.usage);
    return;
  }

  final project = Directory(options['project'] as String).absolute;
  if (!project.existsSync()) {
    throw StateError('Project not found: ${project.path}');
  }
  final shouldBuild = options['build'] as bool;
  var ipaPath = options['ipa'] as String?;
  if (!shouldBuild && (ipaPath == null || ipaPath.trim().isEmpty)) {
    throw const FormatException('Provide --build or --ipa.');
  }
  if (options['wait'] as bool && !(options['upload'] as bool)) {
    throw const FormatException('--wait requires --upload.');
  }

  final lockDirectory = Directory(
    '${project.path}${Platform.pathSeparator}.dart_tool',
  );
  await lockDirectory.create(recursive: true);
  final lockFile = await File(
    '${lockDirectory.path}${Platform.pathSeparator}xcross-testflight.lock',
  ).open(mode: FileMode.write);
  var lockHeld = false;
  try {
    stdout.writeln('=== xcross cross-platform TestFlight pipeline ===');
    stdout.writeln('Project: ${project.path}');
    stdout.writeln(
      'Concurrency: active local run is waited for; cancellation is disabled.',
    );
    await lockFile.lock();
    lockHeld = true;

    if (shouldBuild) {
      await _runBuild(
        project: project,
        command: options['xcross-command'] as String,
      );
    }
    ipaPath = await _resolveIpa(project, ipaPath);
    final ipa = File(ipaPath);
    final metadata = await _readMetadata(ipa);
    stdout.writeln('IPA: ${ipa.path}');
    stdout.writeln(
      'Bundle: ${metadata.bundleId}  Version: '
      '${metadata.shortVersion} (${metadata.buildVersion})',
    );
    if (!(options['upload'] as bool)) {
      stdout.writeln('Build completed; upload was not requested.');
      return;
    }

    final issuerId = options['issuer-id'] as String?;
    final keyId = options['key-id'] as String?;
    final privateKey = options['private-key'] as String?;
    if ([
      issuerId,
      keyId,
      privateKey,
    ].any((value) => value == null || value.trim().isEmpty)) {
      throw const FormatException(
        'ASC credentials are missing. Set XCROSS_ASC_ISSUER_ID, '
        'XCROSS_ASC_KEY_ID and XCROSS_ASC_PRIVATE_KEY.',
      );
    }
    final snapshot = detectPlatformHostSnapshot();
    final credentials = AscCredentials(
      hostServices: _hostServices(snapshot),
      issuerId: issuerId!,
      keyId: keyId!,
      privateKeyPath: File(privateKey!).absolute.path,
    );
    final uploader = AscBuildUploadClient(
      credentials,
      maxConcurrentOperations: int.parse(options['concurrency'] as String),
    );
    try {
      final suppliedAppId = options['app-id'] as String?;
      final appId = suppliedAppId == null || suppliedAppId.trim().isEmpty
          ? await uploader.resolveAppId(metadata.bundleId)
          : suppliedAppId;
      stdout.writeln('App Store Connect app id: $appId');
      final result = await uploader.uploadIpa(
        ipa: ipa,
        appId: appId,
        shortVersion: metadata.shortVersion,
        buildVersion: metadata.buildVersion,
      );
      stdout.writeln(
        'Upload committed: ${result.buildUploadId} '
        '(${result.operationCount} operation, MD5 ${result.md5})',
      );
      if (options['wait'] as bool) {
        await _waitForProcessing(
          uploader,
          result.buildUploadId,
          pollSeconds: int.parse(options['poll-seconds'] as String),
          timeoutMinutes: int.parse(options['timeout-minutes'] as String),
        );
      }
    } finally {
      uploader.close();
    }
    stdout.writeln('TESTFLIGHT PIPELINE PASS');
  } finally {
    if (lockHeld) await lockFile.unlock();
    await lockFile.close();
  }
}

Future<void> _runBuild({
  required Directory project,
  required String command,
}) async {
  stdout.writeln('Building App Store IPA with xcross...');
  final process = await Process.start(
    command,
    const [
      'flutter',
      'build',
      'ipa',
      '--release',
      '--ipa',
      '--target-platform',
      'iphone',
      '--app-store',
    ],
    workingDirectory: project.path,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  if (code != 0) throw StateError('xcross build failed: exit $code');
}

Future<String> _resolveIpa(Directory project, String? supplied) async {
  if (supplied != null && supplied.trim().isNotEmpty) {
    final file = p.isAbsolute(supplied)
        ? File(supplied)
        : File(p.join(project.path, supplied));
    if (!file.existsSync()) throw StateError('IPA not found: ${file.path}');
    return file.path;
  }
  final root = Directory(
    '${project.path}${Platform.pathSeparator}build${Platform.pathSeparator}xcross-ios',
  );
  final candidates = [
    for (final entity
        in root.existsSync()
            ? root.listSync(recursive: true)
            : const <FileSystemEntity>[])
      if (entity is File && entity.path.toLowerCase().endsWith('.ipa')) entity,
  ]..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  if (candidates.isEmpty) throw StateError('No IPA found below ${root.path}');
  return candidates.first.path;
}

Future<_IpaMetadata> _readMetadata(File ipa) async {
  final archive = ZipDecoder().decodeStream(InputFileStream(ipa.path));
  final entry = archive.files.firstWhere(
    (file) => RegExp(r'^Payload/[^/]+\.app/Info\.plist$').hasMatch(file.name),
    orElse: () => throw const FormatException('IPA has no app Info.plist.'),
  );
  final bytes = entry.content as List<int>;
  Object? plist;
  final isBinary =
      bytes.length >= 8 &&
      utf8.decode(bytes.sublist(0, 8), allowMalformed: true) == 'bplist00';
  if (isBinary) {
    plist = PropertyListSerialization.propertyListWithData(
      ByteData.sublistView(Uint8List.fromList(bytes)),
    );
  } else {
    plist = PropertyListSerialization.propertyListWithString(
      utf8.decode(bytes),
    );
  }
  if (plist is! Map) throw const FormatException('Invalid app Info.plist.');
  final root = plist.cast<Object?, Object?>();
  String requiredString(String key) {
    final value = root[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Info.plist is missing $key.');
    }
    return value;
  }

  return _IpaMetadata(
    bundleId: requiredString('CFBundleIdentifier'),
    shortVersion: requiredString('CFBundleShortVersionString'),
    buildVersion: requiredString('CFBundleVersion'),
  );
}

Future<void> _waitForProcessing(
  AscBuildUploadClient uploader,
  String uploadId, {
  required int pollSeconds,
  required int timeoutMinutes,
}) async {
  if (pollSeconds < 1 || timeoutMinutes < 1) {
    throw const FormatException('Polling values must be positive.');
  }
  final deadline = DateTime.now().add(Duration(minutes: timeoutMinutes));
  while (true) {
    await Future<void>.delayed(Duration(seconds: pollSeconds));
    final status = await uploader.status(uploadId);
    stdout.writeln(
      'Status: upload=${status.uploadState} build=${status.processingState}',
    );
    if (status.isFailed) {
      throw StateError('App Store Connect processing failed.');
    }
    if (status.isValid ||
        (status.uploadState == 'COMPLETE' && status.processingState == null)) {
      stdout.writeln('TestFlight processing: VALID');
      return;
    }
    if (DateTime.now().isAfter(deadline)) {
      throw StateError(
        'Build processing timed out after $timeoutMinutes minutes.',
      );
    }
  }
}

AppleHostServices _hostServices(NativeHostSnapshot snapshot) =>
    AppleHostServices(
      host: snapshot.host,
      abi: snapshot.abi,
      machineIdentity: _NoopMachineIdentity(),
      permissions: _NoopPermissions(),
    );

final class _NoopMachineIdentity implements MachineIdentityProvider {
  @override
  Future<String> read() async => '';
}

final class _NoopPermissions implements AppleFilePermissions {
  @override
  void harden(String path) {}

  @override
  void preserve(String path, int mode) {}
}

final class _IpaMetadata {
  const _IpaMetadata({
    required this.bundleId,
    required this.shortVersion,
    required this.buildVersion,
  });

  final String bundleId;
  final String shortVersion;
  final String buildVersion;
}
