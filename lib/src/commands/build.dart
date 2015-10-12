// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:args/command_runner.dart';
import 'package:yaml/yaml.dart';

import '../artifacts.dart';

const String _kSnapshotKey = 'snapshot_blob.bin';
const List<String> _kDensities = const ['drawable-xxhdpi'];
const List<String> _kThemes = const ['white', 'black'];
const List<int> _kSizes = const [24];

class _Asset {
  final String base;
  final String key;

  _Asset({ this.base, this.key });
}

Iterable<_Asset> _parseAssets(Map manifestDescriptor, String manifestPath) sync* {
  if (manifestDescriptor == null || !manifestDescriptor.containsKey('assets'))
    return;
  String basePath = new File(manifestPath).parent.path;
  for (String asset in manifestDescriptor['assets'])
    yield new _Asset(base: basePath, key: asset);
}

class _MaterialAsset {
  final String name;
  final String density;
  final String theme;
  final int size;

  _MaterialAsset(Map descriptor)
    : name = descriptor['name'],
      density = descriptor['density'],
      theme = descriptor['theme'],
      size = descriptor['size'];

  String get key {
    List<String> parts = name.split('/');
    String category = parts[0];
    String subtype = parts[1];
    return '$category/$density/ic_${subtype}_${theme}_${size}dp.png';
  }
}

List _generateValues(Map assetDescriptor, String key, List defaults) {
  if (assetDescriptor.containsKey(key))
    return [assetDescriptor[key]];
  return defaults;
}

Iterable<_MaterialAsset> _generateMaterialAssets(Map assetDescriptor) sync* {
  Map currentAssetDescriptor = new Map.from(assetDescriptor);
  for (String density in _generateValues(assetDescriptor, 'density', _kDensities)) {
    currentAssetDescriptor['density'] = density;
    for (String theme in _generateValues(assetDescriptor, 'theme', _kThemes)) {
      currentAssetDescriptor['theme'] = theme;
      for (int size in _generateValues(assetDescriptor, 'size', _kSizes)) {
        currentAssetDescriptor['size'] = size;
        yield new _MaterialAsset(currentAssetDescriptor);
      }
    }
  }
}

Iterable<_MaterialAsset> _parseMaterialAssets(Map manifestDescriptor) sync* {
  if (manifestDescriptor == null || !manifestDescriptor.containsKey('material-design-icons'))
    return;
  for (Map assetDescriptor in manifestDescriptor['material-design-icons']) {
    for (_MaterialAsset asset in _generateMaterialAssets(assetDescriptor)) {
      yield asset;
    }
  }
}

Future _loadManifest(String manifestPath) async {
  if (manifestPath == null)
    return null;
  String manifestDescriptor = await new File(manifestPath).readAsString();
  return loadYaml(manifestDescriptor);
}

Future<ArchiveFile> _createFile(String key, String assetBase) async {
  File file = new File('${assetBase}/${key}');
  if (!await file.exists())
    return null;
  List<int> content = await file.readAsBytes();
  return new ArchiveFile.noCompress(key, content.length, content);
}

Future _compileSnapshot({
  String compilerPath,
  String mainPath,
  String packageRoot,
  String snapshotPath
}) async {
  if (compilerPath == null) {
    compilerPath = await ArtifactStore.getPath(Artifact.flutterCompiler);
  }
  ProcessResult result = await Process.run(compilerPath, [
    mainPath,
    '--package-root=$packageRoot',
    '--snapshot=$snapshotPath'
  ]);
  if (result.exitCode != 0) {
    print(result.stdout);
    print(result.stderr);
    exit(result.exitCode);
  }
}

Future<ArchiveFile> _createSnapshotFile(String snapshotPath) async {
  File file = new File(snapshotPath);
  List<int> content = await file.readAsBytes();
  return new ArchiveFile(_kSnapshotKey, content.length, content);
}

class BuildCommand extends Command {
  final name = 'build';
  final description = 'Create a Flutter app.';
  BuildCommand() {
    argParser.addOption('asset-base', defaultsTo: 'packages/material_design_icons/icons');
    argParser.addOption('compiler');
    argParser.addOption('main', defaultsTo: 'lib/main.dart');
    argParser.addOption('manifest');
    argParser.addOption('output-file', abbr: 'o', defaultsTo: 'app.flx');
    argParser.addOption('snapshot', defaultsTo: 'snapshot_blob.bin');
  }

  @override
  Future<int> run() async {
    String manifestPath = argResults['manifest'];
    Map manifestDescriptor = await _loadManifest(manifestPath);
    Iterable<_Asset> assets = _parseAssets(manifestDescriptor, manifestPath);
    Iterable<_MaterialAsset> materialAssets = _parseMaterialAssets(manifestDescriptor);

    Archive archive = new Archive();

    String snapshotPath = argResults['snapshot'];
    await _compileSnapshot(
      compilerPath: argResults['compiler'],
      mainPath: argResults['main'],
      packageRoot: globalResults['package-root'],
      snapshotPath: snapshotPath);
    archive.addFile(await _createSnapshotFile(snapshotPath));

    for (_Asset asset in assets)
      archive.addFile(await _createFile(asset.key, asset.base));

    for (_MaterialAsset asset in materialAssets) {
      ArchiveFile file = await _createFile(asset.key, argResults['asset-base']);
      if (file != null)
        archive.addFile(file);
    }

    File outputFile = new File(argResults['output-file']);
    await outputFile.writeAsString('#!mojo mojo:sky_viewer\n');
    await outputFile.writeAsBytes(new ZipEncoder().encode(archive), mode: FileMode.APPEND);
    return 0;
  }
}
