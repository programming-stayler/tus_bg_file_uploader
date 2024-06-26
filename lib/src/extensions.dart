import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tus_bg_file_uploader/src/bg_file_uploader_manager.dart';
import 'package:tus_file_uploader/tus_file_uploader.dart';
import 'package:synchronized/synchronized.dart';

const pendingStoreKey = 'pending_uploading';
const readyForUploadingStoreKey = 'ready_for_uploading';
const processingStoreKey = 'processing_uploading';
const completeStoreKey = 'complete_uploading';
const failedStoreKey = 'failed_uploading';
const baseUrlStoreKey = 'base_files_uploading_url';
const failOnLostConnectionStoreKey = 'fail_on_lost_connection';
const compressParamsKey = 'compress_params';
const appIconStoreKey = 'app_icon';
const customSchemeKey = 'custom_scheme';
const metadataKey = 'metadata';
const headersKey = 'headers';
const timeoutKey = 'timeout';
const loggerLevel = 'logger_level';
const uploadAfterStartingServiceKey = 'upload_after_starting_service';

extension SharedPreferencesUtils on SharedPreferences {
  static final lock = Lock();

  // PUBLIC ----------------------------------------------------------------------------------------
  Future<void> init({required bool clearStorage}) async {
    return lock.synchronized(() async {
      if (clearStorage) {
        await remove(pendingStoreKey);
        await remove(readyForUploadingStoreKey);
        await remove(processingStoreKey);
        await remove(completeStoreKey);
        await remove(failedStoreKey);
        DirectoryUtils.deleteManagerDocumentsDir();
      }
    });
  }

  bool getUploadAfterStartingService() {
    return getBool(uploadAfterStartingServiceKey) ?? true;
  }

  Future<bool> setUploadAfterStartingService(bool value) async {
    return lock.synchronized(() => setBool(uploadAfterStartingServiceKey, value));
  }

  String? getBaseUrl() {
    return getString(baseUrlStoreKey);
  }

  Future<bool> setBaseUrl(String value) async {
    return lock.synchronized(() => setString(baseUrlStoreKey, value));
  }

  bool getFailOnLostConnection() {
    return getBool(failOnLostConnectionStoreKey) ?? false;
  }

  Future<bool> setFailOnLostConnection(bool value) async {
    return lock.synchronized(() => setBool(failOnLostConnectionStoreKey, value));
  }

  String? getAppIcon() {
    return getString(appIconStoreKey);
  }

  Future<bool> setAppIcon(String value) async {
    return lock.synchronized(() => setString(appIconStoreKey, value));
  }

  CompressParams? getCompressParams() {
    final encoded = getString(compressParamsKey);
    if (encoded == null) {
      return null;
    }
    final json = jsonDecode(encoded);
    if (json is Map<String, dynamic>) {
      return CompressParams.fromJson(json);
    }
    return null;
  }

  Future<bool> setCompressParams(CompressParams params) async {
    return lock.synchronized(() => setString(compressParamsKey, jsonEncode(params.toJson())));
  }

  List<UploadingModel> getPendingUploading() {
    return getFilesForKey(pendingStoreKey).toList();
  }

  List<UploadingModel> getReadyForUploading() {
    return getFilesForKey(readyForUploadingStoreKey).toList();
  }

  List<UploadingModel> getProcessingUploading() {
    return getFilesForKey(processingStoreKey).toList();
  }

  List<UploadingModel> getCompleteUploading() {
    return getFilesForKey(completeStoreKey).toList();
  }

  List<UploadingModel> getFailedUploading() {
    return getFilesForKey(failedStoreKey).toList();
  }

  Map<String, String> getMetadata() {
    String? encodedResult = getString(metadataKey);
    if (encodedResult != null) {
      return Map.castFrom<String, dynamic, String, String>(jsonDecode(encodedResult));
    }
    return {};
  }

  Map<String, String> getHeaders() {
    String? encodedResult = getString(headersKey);
    if (encodedResult != null) {
      return Map.castFrom<String, dynamic, String, String>(jsonDecode(encodedResult));
    }
    return {};
  }

  int? getTimeout() {
    return getInt(timeoutKey);
  }

  int getLoggerLevel() {
    return getInt(loggerLevel) ?? 0;
  }

  Future<bool> setLoggerLevel(int level) async {
    return lock.synchronized(() => setInt(loggerLevel, level));
  }

  Future<void> setHeadersMetadata({
    Map<String, String>? headers,
    Map<String, String>? metadata,
  }) async {
    await lock.synchronized(() async {
      if (metadata != null) {
        await setString(metadataKey, jsonEncode(metadata));
      }
      if (headers != null) {
        await setString(headersKey, jsonEncode(headers));
      }
    });
  }

  Future<bool> setTimeout(int? timeout) async {
    return lock.synchronized(() {
      if (timeout != null) {
        return setInt(timeoutKey, timeout);
      } else {
        return false;
      }
    });
  }

  Future<void> addFileToPending({required UploadingModel uploadingModel}) async {
    await _updateMapEntry(uploadingModel, pendingStoreKey);
  }

  Future<void> addFileToReadyForUpload({required UploadingModel uploadingModel}) async {
    await removeFile(uploadingModel, pendingStoreKey);
    await removeFile(uploadingModel, failedStoreKey);
    await _updateMapEntry(uploadingModel, readyForUploadingStoreKey);
  }

  Future<void> addFileToProcessing({required UploadingModel uploadingModel}) async {
    await removeFile(uploadingModel, readyForUploadingStoreKey);
    await removeFile(uploadingModel, failedStoreKey);
    await removeFile(uploadingModel, completeStoreKey);
    await _updateMapEntry(uploadingModel, processingStoreKey);
  }

  Future<void> addFileToComplete({required UploadingModel uploadingModel}) async {
    await removeFile(uploadingModel, readyForUploadingStoreKey);
    await removeFile(uploadingModel, processingStoreKey);
    await removeFile(uploadingModel, failedStoreKey);
    await _updateMapEntry(uploadingModel, completeStoreKey);
  }

  Future<void> addFileToFailed({required UploadingModel uploadingModel}) async {
    await removeFile(uploadingModel, readyForUploadingStoreKey);
    await removeFile(uploadingModel, processingStoreKey);
    await removeFile(uploadingModel, completeStoreKey);
    await _updateMapEntry(uploadingModel, failedStoreKey);
  }

  Future<void> removeFileFromEveryStore(UploadingModel uploadingModel) async {
    await removeFile(uploadingModel, pendingStoreKey);
    await removeFile(uploadingModel, readyForUploadingStoreKey);
    await removeFile(uploadingModel, processingStoreKey);
    await removeFile(uploadingModel, completeStoreKey);
    await removeFile(uploadingModel, failedStoreKey);
  }

  Future<bool> removeFile(UploadingModel uploadingModel, String storeKey) async {
    return lock.synchronized(() {
      final encodedResult = getStringList(storeKey);
      if (encodedResult != null) {
        final result = encodedResult.map((e) => UploadingModel.fromJson(jsonDecode(e))).toList();
        result.remove(uploadingModel);
        return setStringList(storeKey, result.map((e) => jsonEncode(e.toJson())).toList());
      } else {
        return false;
      }
    });
  }

  Future<bool> resetUploading() async {
    return lock.synchronized(() async {
      return remove(completeStoreKey);
    });
  }

  Future<List<UploadingModel>> actualizeUnfinishedUploads() async {
    final readyForUploadingUploads = await _actualizeUploadsForKey(readyForUploadingStoreKey);
    final processingUploads = await _actualizeUploadsForKey(processingStoreKey);
    final failedUploads = await _actualizeUploadsForKey(failedStoreKey);
    return [
      ...readyForUploadingUploads,
      ...processingUploads,
      ...failedUploads,
    ];
  }

  // PRIVATE ---------------------------------------------------------------------------------------
  Future<List<UploadingModel>> _actualizeUploadsForKey(String key) async {
    final docsPath = (await getApplicationDocumentsDirectory()).path;
    final uploads = getFilesForKey(key).toList();
    await _actualizeUploadsRecursively(uploads, key, docsPath);
    return uploads;
  }

  Future<void> _actualizeUploadsRecursively(
    List<UploadingModel> models,
    String key,
    String rootPath, [
    int index = 0,
  ]) async {
    if (index >= models.length) {
      return;
    }
    final model = models[index];
    await _actualizeModel(model, key, rootPath);
    await _actualizeUploadsRecursively(models, key, rootPath, index + 1);
  }

  Future<void> _actualizeModel(UploadingModel model, String key, String rootPath) async {
    var file = File(model.path);
    if (file.existsSync()) {
      return;
    }
    final pathParts = model.path.split('$managerDocumentsDir/');
    if (pathParts.length != 2) {
      return;
    }
    final fileName = pathParts.last;
    final nextPath = '$rootPath/$managerDocumentsDir/$fileName';
    file = File(nextPath);
    if (file.existsSync()) {
      await removeFile(model, key);
      model.path = nextPath;
      await _updateMapEntry(model, key);
    }
  }

  Set<UploadingModel> getFilesForKey(String storeKey) {
    final encodedResult = getStringList(storeKey);
    final Set<UploadingModel> result;
    if (encodedResult == null) {
      result = {};
    } else {
      result = encodedResult.map((e) => UploadingModel.fromJson(jsonDecode(e))).toSet();
    }

    return result;
  }

  Future<bool> _updateMapEntry(UploadingModel uploadingModel, String storeKey) async {
    return lock.synchronized(() async {
      final result = getFilesForKey(storeKey);
      result.remove(uploadingModel);
      result.add(uploadingModel);

      return setStringList(storeKey, result.map((e) => jsonEncode(e.toJson())).toList());
    });
  }
}

const oneKB = 1000;

class CompressParams {
  final int relativeWidth;
  final int idealSize;
  final bool saveExif;

  const CompressParams({
    this.relativeWidth = 1920,
    this.idealSize = 1000 * oneKB,
    this.saveExif = true,
  });

  Map<String, dynamic> toJson() {
    return {
      'relativeWidth': relativeWidth,
      'idealSize': idealSize,
      'saveExif': saveExif,
    };
  }

  factory CompressParams.fromJson(Map<String, dynamic> map) {
    return CompressParams(
      relativeWidth: map['relativeWidth'] as int,
      idealSize: map['idealSize'] as int,
      saveExif: (map['saveExif'] ?? true) as bool,
    );
  }
}

extension FileUtils on File {
  Future<File> saveToDocumentsDir() async {
    final dirPath = '${(await getApplicationDocumentsDirectory()).path}/$managerDocumentsDir';
    Directory(dirPath).createSync(recursive: true);
    final documentsFullPath = '$dirPath/${DateTime.now().millisecondsSinceEpoch}$hashCode.jpg';
    final result = await copy(documentsFullPath);
    await delete();
    return result;
  }

  Future<bool> safeDelete() async {
    if (existsSync()) {
      try {
        await delete();
        return true;
      } catch (e) {
        return false;
      }
    }
    return false;
  }
}

extension DirectoryUtils on Directory {
  static Future<bool> deleteManagerDocumentsDir() async {
    final documentsDir = '${(await getApplicationDocumentsDirectory()).path}/$managerDocumentsDir';
    final dir = Directory(documentsDir);
    if (dir.existsSync()) {
      try {
        await dir.delete(recursive: true);
        return true;
      } catch (e) {
        return false;
      }
    }
    return false;
  }
}
