import 'dart:io';

import 'package:cli_kit/host/linux/linux_host.dart';
import 'package:cli_kit/host/windows/windows_host.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/shared/flutter/build/info_plist.dart';
import 'package:xcross/src/shared/flutter/flutter_build_steps.dart';
import 'package:xcross/src/shared/flutter/flutter_bundle_assembler.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/shared/flutter/project/ios_bundle_versions_resolver.dart';
import 'package:xcross/src/shared/flutter/project/pbx_project_reader.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';

import '../../host_operations_fixtures.dart';
import '../flutter_test_runtime.dart';

Future<(Map<String, String>, String)> _resolveVersions({
  String? version,
  String generatedBuildNumber = '1',
  String generatedBuildName = '1.0.0',
  String? buildNumber,
  String? buildName,
  FlutterBuildMode buildMode = FlutterBuildMode.debug,
}) async {
  final root = Directory.systemTemp.createTempSync('xcross-version-');
  addTearDown(() => root.deleteSync(recursive: true));

  final fs = FixtureMappedFileSystem(root);
  const project = '/selected-project';

  void write(String path, String content) {
    fs.file('$project/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  write(
    'pubspec.yaml',
    'name: fixture\n'
        '${version == null ? '' : 'version: $version\n'}',
  );

  write(
    'ios/Flutter/Generated.xcconfig',
    'FLUTTER_BUILD_NAME=$generatedBuildName\n'
        'FLUTTER_BUILD_NUMBER=$generatedBuildNumber\n',
  );

  write('ios/Flutter/Debug.xcconfig', '#include "Generated.xcconfig"\n');

  write(
    'ios/Flutter/Release.xcconfig',
    '#include "Generated.xcconfig"\n'
        'XCROSS_MODE_MARKER=release\n',
  );

  write(
    'ios/Flutter/Profile.xcconfig',
    '#include "Generated.xcconfig"\n'
        'XCROSS_MODE_MARKER=profile\n',
  );
  final host = LinuxHost(
    fileSystem: fs,
    currentDirectory: project,
    temporaryDirectory: '/selected-temp',
  );

  final runtime = testFlutterRuntime(IPhoneFlutterTarget(IPhoneTarget(host)));

  final request = FlutterBuildRequest(
    runtime: runtime,
    projectRoot: project,
    bundleId: 'com.example.fixture',
    options: FlutterBuildOptions(
      pub: false,
      buildMode: buildMode,
      buildNumber: buildNumber,
      buildName: buildName,
    ),
  );

  final context = FlutterBuildContext(request: request, flutterRoot: '/unused');

  final values = await FlutterBundleAssembler(context).buildSubstitutionMap();

  return (values, context.versions.bundleVersion);
}

void main() {
  test('assembler reads Release xcconfig', () async {
    final (values, bundleVersion) = await _resolveVersions(
      version: '1.0.0+2',
      buildMode: FlutterBuildMode.release,
    );

    expect(values['XCROSS_MODE_MARKER'], 'release');
    expect(values['FLUTTER_BUILD_NUMBER'], '2');
    expect(bundleVersion, '2');
  });

  test('assembler reads Profile xcconfig', () async {
    final (values, bundleVersion) = await _resolveVersions(
      version: '1.0.0+2',
      buildMode: FlutterBuildMode.profile,
    );

    expect(values['XCROSS_MODE_MARKER'], 'profile');
    expect(values['FLUTTER_BUILD_NUMBER'], '2');
    expect(bundleVersion, '2');
  });
  test('pubspec overrides stale generated configuration', () async {
    final (values, bundleVersion) = await _resolveVersions(version: '1.0.0+2');

    expect(values['FLUTTER_BUILD_NUMBER'], '2');
    expect(values['CURRENT_PROJECT_VERSION'], '2');
    expect(bundleVersion, '2');
  });

  test('explicit CLI version overrides pubspec and generated', () async {
    final (values, bundleVersion) = await _resolveVersions(
      version: '1.0.0+2',
      buildNumber: '9',
      buildName: '2.0.0',
    );

    expect(values['FLUTTER_BUILD_NUMBER'], '9');
    expect(values['CURRENT_PROJECT_VERSION'], '9');
    expect(values['FLUTTER_BUILD_NAME'], '2.0.0');
    expect(values['MARKETING_VERSION'], '2.0.0');
    expect(bundleVersion, '9');
  });

  test('stock Info.plist resolves pubspec build version', () async {
    final (values, bundleVersion) = await _resolveVersions(version: '1.0.0+2');

    const template = r'''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
<key>CFBundleShortVersionString</key>
<string>$(FLUTTER_BUILD_NAME)</string>
<key>CFBundleVersion</key>
<string>$(FLUTTER_BUILD_NUMBER)</string>
</dict>
</plist>
''';

    final xml = InfoPlist.expandXmlVars(template, values);

    expect(
      xml,
      contains(
        '<key>CFBundleShortVersionString</key>\n'
        '<string>1.0.0</string>',
      ),
    );

    expect(
      xml,
      contains(
        '<key>CFBundleVersion</key>\n'
        '<string>2</string>',
      ),
    );

    expect(bundleVersion, '2');
    expect(xml, isNot(contains(r'$(FLUTTER_BUILD_NUMBER)')));
  });

  test('native Windows Xcode application version resolves correctly', () {
    final root = Directory.systemTemp.createTempSync('xcross-pbx-native-');

    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    final project = Directory(p.join(root.path, 'ios', 'Runner.xcodeproj'))
      ..createSync(recursive: true);

    File(p.join(project.path, 'project.pbxproj')).writeAsStringSync('''
{
  objects = {
    AA02 = {
      isa = PBXNativeTarget;
      buildConfigurationList = BB02;
      name = Runner;
      productType = "com.apple.product-type.application";
    };
    CC02 = {
      isa = XCBuildConfiguration;
      buildSettings = {
        MARKETING_VERSION = 2.4.1;
        CURRENT_PROJECT_VERSION = 37;
      };
      name = Debug;
    };
    BB02 = {
      isa = XCConfigurationList;
      buildConfigurations = (CC02,);
    };
  };
  rootObject = PP01;
}
''');

    final flutter = Directory(p.join(root.path, 'ios', 'Flutter'))
      ..createSync(recursive: true);

    File(p.join(flutter.path, 'Generated.xcconfig')).writeAsStringSync(
      'FLUTTER_BUILD_NAME=0.1.0\n'
      'FLUTTER_BUILD_NUMBER=7\n',
    );

    File(p.join(flutter.path, 'Debug.xcconfig')).writeAsStringSync(
      '#include "Generated.xcconfig"\n'
      'FLUTTER_BUILD_NAME=9.9.9\n'
      'FLUTTER_BUILD_NUMBER=99\n',
    );
    final host = WindowsHost(
      currentDirectory: root.path,
      temporaryDirectory: root.path,
    );

    final reader = PbxProjectReader(host.fileSystem, host.paths.context);

    final found = reader.findPbxproj(root.path);

    expect(found, isNotNull);

    final parsed = reader.parseFile(found!);

    expect(parsed?.applicationTarget, isNotNull);

    final versions = IosBundleVersionsResolver(
      host.fileSystem,
      reader,
    ).resolve(root.path);

    expect(versions.shortVersion, '2.4.1');
    expect(versions.bundleVersion, '37');
    final cliVersions = IosBundleVersionsResolver(
      host.fileSystem,
      reader,
    ).resolve(root.path, buildName: '5.0.0', buildNumber: '88');

    expect(cliVersions.shortVersion, '5.0.0');
    expect(cliVersions.bundleVersion, '88');
  }, testOn: 'windows');

  test('missing pubspec version preserves generated fallback', () async {
    final (values, bundleVersion) = await _resolveVersions(
      generatedBuildNumber: '7',
      generatedBuildName: '1.3.0',
    );

    expect(values['FLUTTER_BUILD_NUMBER'], '7');
    expect(values['FLUTTER_BUILD_NAME'], '1.3.0');
    expect(bundleVersion, '7');
  });
}
