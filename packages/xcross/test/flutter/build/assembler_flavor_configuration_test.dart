import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';
import 'package:xcross/src/shared/flutter/flutter_bundle_assembler.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';

import '../flutter_test_runtime.dart';

Future<Map<String, String>> _substitutions({
  required String declaredConfiguration,
}) {
  final root = Directory.systemTemp.createTempSync('xcross-assembler-flavor-');

  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File(
    p.join(root.path, 'pubspec.yaml'),
  ).writeAsStringSync('name: fixture\nversion: 1.0.0+2\n');

  final flutter = Directory(p.join(root.path, 'ios', 'Flutter'))
    ..createSync(recursive: true);

  File(p.join(flutter.path, 'Generated.xcconfig')).writeAsStringSync(
    'FLUTTER_BUILD_NAME=0.1.0\n'
    'FLUTTER_BUILD_NUMBER=7\n',
  );

  File(p.join(flutter.path, 'Release.xcconfig')).writeAsStringSync(
    '#include "Generated.xcconfig"\n'
    'XCROSS_FLAVOR_MARKER=base\n'
    'XCROSS_FLAVOR_MARKER[config=Release-staging]=staging\n',
  );

  final pbxproj = File(
    p.join(root.path, 'ios', 'Runner.xcodeproj', 'project.pbxproj'),
  )..createSync(recursive: true);

  pbxproj.writeAsStringSync('''
{
  archiveVersion = 1;
  classes = {};
  objectVersion = 50;
  objects = {
    PP01 = {
      isa = PBXProject;
      targets = (AA01,);
      buildConfigurationList = LL01;
    };
    AA01 = {
      isa = PBXNativeTarget;
      name = Runner;
      productType = "com.apple.product-type.application";
      buildConfigurationList = LL01;
    };
    LL01 = {
      isa = XCConfigurationList;
      buildConfigurations = (CC01,);
    };
    CC01 = {
      isa = XCBuildConfiguration;
      name = "$declaredConfiguration";
      buildSettings = {};
    };
  };
  rootObject = PP01;
}
''');

  // Use native Windows paths/filesystem when running on Windows,
  // while retaining the existing Linux Flutter test runtime.
  final windows = Platform.isWindows
      ? WindowsHost(currentDirectory: root.path, temporaryDirectory: root.path)
      : null;

  final host = LinuxHost(
    architecture: 'arm64',
    currentDirectory: root.path,
    temporaryDirectory: root.path,
    paths: windows?.paths,
    fileSystem: windows?.fileSystem,
  );

  final runtime = testFlutterRuntime(IPhoneFlutterTarget(IPhoneTarget(host)));

  final projectPath = runtime.projects.findPbxproj(root.path);

  expect(projectPath, isNotNull);

  final project = runtime.projects.parseFile(projectPath!);

  expect(
    project?.configurationName('Release', 'staging'),
    declaredConfiguration,
  );

  final request = FlutterBuildRequest(
    runtime: runtime,
    projectRoot: root.path,
    bundleId: 'com.example.fixture',
    options: const FlutterBuildOptions(
      pub: false,
      buildMode: FlutterBuildMode.release,
      flavor: 'staging',
    ),
  );

  final context = FlutterBuildContext(request: request, flutterRoot: '/unused');

  expect(context.versions.bundleVersion, '2');

  return FlutterBundleAssembler(context).buildSubstitutionMap();
}

void main() {
  test('assembler falls back to Release when flavor is undeclared', () async {
    final values = await _substitutions(declaredConfiguration: 'Release');

    expect(values['XCROSS_FLAVOR_MARKER'], 'base');
    expect(values['FLUTTER_BUILD_NUMBER'], '2');
  });

  test('assembler evaluates declared Release-staging configuration', () async {
    final values = await _substitutions(
      declaredConfiguration: 'Release-staging',
    );

    expect(values['XCROSS_FLAVOR_MARKER'], 'staging');
    expect(values['FLUTTER_BUILD_NUMBER'], '2');
  });
}
