import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:example/src/file_model.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:tus_bg_file_uploader/tus_bg_file_uploader.dart';
import 'package:path_provider/path_provider.dart';
import 'package:internet_connection_checker/internet_connection_checker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tile.dart';

class App extends StatefulWidget {
  const App({Key? key}) : super(key: key);

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  final uploadingManager = TusBGFileUploaderManager();
  var files = <FileModel>{};
  var newFiles = <FileModel>{};

  late SharedPreferences sharedPreferences;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((sp) async {
      sharedPreferences = sp;
      final filesJson = sharedPreferences.getStringList('files');
      if (filesJson != null) {
        files = filesJson.map((e) => FileModel.fromJson(jsonDecode(e))).toSet();
        final unfinishedModels = await uploadingManager.checkForUnfinishedUploads();
        final failedModels = await uploadingManager.checkForUnfinishedUploads();
        for (final model in failedModels) {
          final file = files.firstWhere((element) => element.path == model.path);
          file.failed = true;
        }

        for (var file in files) {
          if (!unfinishedModels.any((e) => e.path == file.path) &&
              !failedModels.any((e) => e.path == file.path)) {
            file.progress = 1;
          }
        }

        setState(() {});
      }
    });
    subscribeUpdates();
    subscribeFileCompletion();
    subscribeConnectionState();
    subscribeFailure();
    uploadingManager
        .setup(
          'https://master.tus.io/files/',
          timeout: 10,
        )
        .whenComplete(() => resumeAll());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Upload images'),
          actions: [
            IconButton(
              onPressed: () async {
                final result = await FilePicker.platform.pickFiles(
                  allowMultiple: true,
                );

                if (result != null) {
                  for (final file in result.files) {
                    final path = await getFilePath(file);
                    if (!files.any((file) => file.path == path)) {
                      newFiles.add(FileModel(path));
                    }
                  }
                }
                setState(() {});
              },
              icon: const Icon(Icons.file_copy),
            ),
            if (files.isNotEmpty || newFiles.isNotEmpty)
              IconButton(onPressed: clearUploads, icon: const Icon(Icons.clear))
          ],
        ),
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [...files, ...newFiles].map((file) {
              return ImageTile(
                file.path,
                progress: file.progress,
                failed: file.failed,
                onRetry: (path) => retryUpload(path),
              );
            }).toList(),
          ),
        ),
        bottomNavigationBar: newFiles.isNotEmpty
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: ElevatedButton(
                    onPressed: uploadAll,
                    child: const Text('Upload Files'),
                  ),
                ),
              )
            : null,
        // : null,
      ),
    );
  }

  void uploadAll() async {
    await sharedPreferences.setStringList(
      'files',
      (files..addAll(newFiles)).map((e) => jsonEncode(e)).toList(),
    );
    uploadingManager.uploadFiles(
      uploadingModels: newFiles
          .map(
            (e) => UploadingModel(path: e.path),
          )
          .toList(),
      metadata: {
        'notes': 'Test notes',
        'tags': 'receipt;critical',
      },
    );
    setState(() => newFiles.clear());
  }

  Future<void> clearUploads() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove('pending_uploading');
    await sp.remove('processing_uploading');
    await sp.remove('complete_uploading');
    await sp.remove('files');
    files.clear();
    newFiles.clear();
    setState(() {});
  }

  void subscribeUpdates() {
    uploadingManager.progressStream.listen((event) {
      final data = event as Map<String, dynamic>;
      final progress = data['progress'] as int;
      // final id = data['id'] as String?;
      //
      // if (id != null) {
      //   onUploadingProgress(id, progress / 100);
      // }
    });
  }

  void subscribeFileCompletion() {
    uploadingManager.completionStream.listen((event) {
      final data = event as Map<String, dynamic>;
      // final filePath = data['filePath'] as String;
      final uploadUrl = data['url'] as String;
      // files.firstWhere((element) => element.path == filePath).url = uploadUrl;
      updateUploadingStatus();
    });
  }

  void subscribeConnectionState() {
    InternetConnectionChecker.createInstance(
      checkInterval: const Duration(seconds: 5),
      checkTimeout: const Duration(seconds: 4),
    ).onStatusChange.skip(1).listen((status) {
      if (status == InternetConnectionStatus.connected) {
        print('Internet connection restored');
        resumeAll();
      } else {
        print('Internet connection lost');
      }
    });
  }

  void subscribeFailure() {
    uploadingManager.failureStream.listen((event) {
      final data = event as Map<String, dynamic>;
      // final filePath = data['filePath'] as String;
      // setState(() {
      //   onUploadingFailed(filePath);
      // });
    });
  }

  Future<String> getFilePath(PlatformFile platformFile) async {
    String? path;
    if (Platform.isAndroid) {
      path = platformFile.path;
    } else {
      final documentPath = (await getApplicationDocumentsDirectory()).path;
      final newFilePath = '$documentPath/upl_${platformFile.name}';

      if (await File(newFilePath).exists()) return newFilePath;

      final file = await File(platformFile.path!).copy('$documentPath/upl_${platformFile.name}');
      path = file.path;
    }
    return path!;
  }

  void retryUpload(String filePath) async {
    final file = files.firstWhere((file) => file.path == filePath);
    setState(() {
      file.failed = false;
    });
    sharedPreferences.setStringList('files', files.map((e) => jsonEncode(e)).toList());
    uploadingManager.uploadFiles(uploadingModels: [UploadingModel(path: filePath)]);
  }

  void resumeAll() {
    uploadingManager.resumeAllUploads();
  }

  void onUploadingProgress(String filePath, double progress) {
    setState(() {
      files.firstWhere((file) => file.path == filePath).progress = progress;
    });
  }

  void onUploadingFailed(String filePath) {
    setState(() {
      files.firstWhere((file) => file.path == filePath).failed = true;
    });

    updateUploadingStatus();
  }

  void updateUploadingStatus() {
    sharedPreferences.setStringList('files', files.map((e) => jsonEncode(e)).toList());
  }
}
