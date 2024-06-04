import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:collection/collection.dart' '';
import 'package:flutter/material.dart';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart' as bsa;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tus_file_uploader/tus_file_uploader.dart';
import 'package:path_provider/path_provider.dart' as path_provider;

import 'extensions.dart';

const _progressStream = 'progress_stream';
const _completionStream = 'completion_stream';
const _failureStream = 'failure_stream';
const _authFailureStream = 'auth_stream';
const _serverErrorStream = 'server_error';
const managerDocumentsDir = 'bgFileUploaderManager';

@pragma('vm:entry-point')
enum _NotificationIds {
  uploadProgress(888),
  // uploadFailure(333)
  ;

  final int id;

  const _NotificationIds(this.id);
}

Future<void> initAndroidNotifChannel() async {
  await FlutterLocalNotificationsPlugin().initialize(
    const InitializationSettings(
      iOS: DarwinInitializationSettings(),
      android: AndroidInitializationSettings('ic_bg_service_small'),
    ),
    onDidReceiveNotificationResponse: (response) async {
      // print('onDidReceiveNotificationResponse');
    },
  );

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'my_foreground', // id
    'MY FOREGROUND SERVICE', // title
    description: 'This channel is used for important notifications.', // description
    importance: Importance.low, // importance must be at low or higher level
  );

  await FlutterLocalNotificationsPlugin()
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
}

class TusBGFileUploaderManager {
  @pragma('vm:entry-point')
  static final _instance = TusBGFileUploaderManager._();
  @pragma('vm:entry-point')
  static final _objectsCache = <String, dynamic>{};
  @pragma('vm:entry-point')
  static final cache = <int, TusFileUploader>{};

  @pragma('vm:entry-point')
  TusBGFileUploaderManager._();

  factory TusBGFileUploaderManager() {
    return _instance;
  }

  Stream<Map<String, dynamic>?> get progressStream => FlutterBackgroundService().on(
        _progressStream,
      );

  Stream<Map<String, dynamic>?> get completionStream => FlutterBackgroundService().on(
        _completionStream,
      );

  Stream<Map<String, dynamic>?> get failureStream => FlutterBackgroundService().on(
        _failureStream,
      );

  Stream<Map<String, dynamic>?> get authFailureStream => FlutterBackgroundService().on(
        _authFailureStream,
      );

  Stream<Map<String, dynamic>?> get serverErrorStream => FlutterBackgroundService().on(
        _serverErrorStream,
      );

  Future<void> setup(
    String baseUrl, {
    int? timeout,
    Level loggerLevel = Level.all,
    bool failOnLostConnection = false,
    bool clearStorageOnInit = true,
    CompressParams? compressParams = const CompressParams(),
  }) async {
    final prefs = await SharedPreferences.getInstance();
    prefs.init(clearStorage: clearStorageOnInit);
    prefs.setBaseUrl(baseUrl);
    prefs.setFailOnLostConnection(failOnLostConnection);
    prefs.setTimeout(timeout);
    prefs.setLoggerLevel(loggerLevel.value);
    prefs.setUploadAfterStartingService(false);
    if (compressParams != null) {
      prefs.setCompressParams(compressParams);
    }
    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: 'my_foreground',
        initialNotificationTitle: 'Upload files',
        initialNotificationContent: 'Preparing to upload',
        foregroundServiceNotificationId: _NotificationIds.uploadProgress.id,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  Future<List<UploadingModel>> checkForUnfinishedUploads() async {
    final prefs = await SharedPreferences.getInstance();
    final readyForUploadingUploads = prefs.getReadyForUploading();
    final processingUploads = prefs.getProcessingUploading();
    final failedUploads = prefs.getFailedUploading();

    return readyForUploadingUploads
      ..addAll(processingUploads)
      ..addAll(failedUploads);
  }

  Future<List<UploadingModel>> checkForFailedUploads() async {
    final prefs = await SharedPreferences.getInstance();
    final failedUploads = prefs.getFailedUploading();
    return failedUploads;
  }

  Future<void> uploadFiles({
    required List<UploadingModel> uploadingModels,
    Map<String, String>? headers,
    Map<String, String>? metadata,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await prefs.setUploadAfterStartingService(true);

    for (final model in uploadingModels) {
      await prefs.addFileToPending(uploadingModel: model);
    }

    await prefs.setHeadersMetadata(headers: headers, metadata: metadata);
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    } else {
      _persistFilesForUpload(uploadingModels: uploadingModels, sharedPreferences: prefs);
    }
  }

  Future<void> retryUploadingFiles({
    required List<int> modelIds,
    Map<String, String>? headers,
    Map<String, String>? metadata,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await prefs.setUploadAfterStartingService(true);
    await prefs.setHeadersMetadata(headers: headers, metadata: metadata);
    final allFailedFiles = prefs.getFailedUploading();
    for (final model in allFailedFiles) {
      if (modelIds.contains(model.id)) {
        prefs.addFileToProcessing(uploadingModel: model);
      }
    }
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }
  }

  Future<void> removeFileById(int modelId) async {
    final prefs = await SharedPreferences.getInstance();
    final allModels = [
      ...prefs.getPendingUploading(),
      ...prefs.getReadyForUploading(),
      ...prefs.getProcessingUploading(),
      ...prefs.getCompleteUploading(),
      ...prefs.getFailedUploading(),
    ];
    UploadingModel? model = allModels.firstWhereOrNull(
      (e) => e.id == modelId,
    );
    if (model != null) {
      prefs.removeFileFromEveryStore(model);
    }
  }

  static Future<void> _persistFilesForUpload({
    List<UploadingModel>? uploadingModels,
    required SharedPreferences sharedPreferences,
  }) async {
    final models = uploadingModels ?? sharedPreferences.getPendingUploading();
    final compressParams = sharedPreferences.getCompressParams();
    for (final model in models) {
      final notPersistedFile = File(model.path);
      final persistedFile = await notPersistedFile.saveToDocumentsDir();
      File? compressedFile;
      if (compressParams != null) {
        compressedFile = await compressImageIfNeeded(
          sharedPreferences,
          persistedFile.path,
          compressParams,
        );
      }
      model.path = compressedFile?.path ?? persistedFile.path;
      sharedPreferences.addFileToReadyForUpload(uploadingModel: model);
    }
  }

  void resumeAllUploading() async {
    final unfinishedFiles = await checkForUnfinishedUploads();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setUploadAfterStartingService(true);
    buildLogger(prefs).d(
      "RESUME UPLOADING\n=> Unfinished files: ${unfinishedFiles.length}",
    );
    if (unfinishedFiles.isEmpty) return;

    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }
  }

  // BACKGROUND ------------------------------------------------------------------------------------
  @pragma('vm:entry-point')
  static _onStart(ServiceInstance service) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await _persistFilesForUpload(sharedPreferences: prefs);
    if (!prefs.getUploadAfterStartingService()) {
      _dispose(service);
      return;
    }
    ui.DartPluginRegistrant.ensureInitialized();
    if (service is bsa.AndroidServiceInstance) {
      service.setAsForegroundService();
    }
    service.on('stopService').listen((_) => _dispose(service));

    _uploadFilesCallback(service);
  }

  @pragma('vm:entry-point')
  static FutureOr<bool> onIosBackground(ServiceInstance service) async {
    const workTime = 30;
    WidgetsFlutterBinding.ensureInitialized();
    ui.DartPluginRegistrant.ensureInitialized();
    await Future.delayed(const Duration(seconds: workTime));
    return true;
  }

  @pragma('vm:entry-point')
  static Future<void> _uploadFilesCallback(ServiceInstance service) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final processingUploads = _getProcessingUploads(prefs, service);
    await _uploadFiles(prefs, service, processingUploads);
    await prefs.reload();
    await prefs.resetUploading();
    _dispose(service);
  }

  @pragma('vm:entry-point')
  static Future<void> _onNextFileComplete({
    required ServiceInstance service,
    required UploadingModel uploadingModel,
    required String uploadUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    File(uploadingModel.path).safeDelete();
    await prefs.addFileToComplete(uploadingModel: uploadingModel);
    await _updateProgress(currentFileProgress: 1);
    service.invoke(_completionStream, {'id': uploadingModel.id, 'url': uploadUrl});
  }

  @pragma('vm:entry-point')
  static Future<void> _onProgress({
    required UploadingModel uploadingModel,
    required double progress,
    required ServiceInstance service,
  }) async {
    service.invoke(_progressStream, {
      "id": uploadingModel.id,
      "progress": (progress * 100).toInt(),
    });
    await _updateProgress(currentFileProgress: progress);
  }

  @pragma('vm:entry-point')
  static Future<void> _updateProgress({required double currentFileProgress}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final readyForUploadFiles = prefs.getReadyForUploading().length;
    final uploadingFiles = prefs.getProcessingUploading().length;
    final completeFiles = prefs.getCompleteUploading().length;
    final failedFiles = prefs.getFailedUploading().length;
    final allFiles = readyForUploadFiles + uploadingFiles + completeFiles + failedFiles;
    final int progress;
    final String message;
    final bool iosShowProgress;
    if (allFiles == 1) {
      progress = (currentFileProgress * 100).toInt();
      message = 'Uploading file';
      iosShowProgress = true;
    } else {
      progress = (completeFiles / allFiles * 100).toInt();
      message = 'Uploaded $completeFiles of $allFiles files';
      iosShowProgress = false;
    }
    await updateNotification(
      title: message,
      progress: progress,
      iosShowProgress: iosShowProgress,
    );
  }

  @pragma('vm:entry-point')
  static Future<void> _onNextFileFailed({
    required UploadingModel uploadingModel,
    required ServiceInstance service,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.addFileToFailed(uploadingModel: uploadingModel);
    service.invoke(_failureStream, {'id': uploadingModel.id});
  }

  @pragma('vm:entry-point')
  static Future<void> _onAuthFailed({
    required UploadingModel uploadingModel,
    required ServiceInstance service,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.addFileToFailed(uploadingModel: uploadingModel);
    service.invoke(_authFailureStream, {'id': uploadingModel.id});
  }

  @pragma('vm:entry-point')
  static Future<void> _onServerError({
    required UploadingModel uploadingModel,
    required ServiceInstance service,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.addFileToFailed(uploadingModel: uploadingModel);
    service.invoke(_serverErrorStream, {'id': uploadingModel.id});
  }

  // PRIVATE ---------------------------------------------------------------------------------------
  @pragma('vm:entry-point')
  static Future<void> _uploadFiles(
    SharedPreferences prefs,
    ServiceInstance service, [
    Iterable<Future<TusFileUploader>> processingUploads = const [],
    Iterable<Future<TusFileUploader>> failedUploads = const [],
  ]) async {
    await prefs.reload();
    final readyForUploadingUploads = _getreadyForUploadingUploads(prefs, service);
    final headers = prefs.getHeaders();
    final total = processingUploads.length + readyForUploadingUploads.length + failedUploads.length;
    buildLogger(prefs).d(
      "UPLOADING FILES\n=> Processing files: ${processingUploads.length}\n=> Ready for upload files: ${readyForUploadingUploads.length}\n=> Failed files: ${failedUploads.length}",
    );
    if (total > 0) {
      final uploaderList = await Future.wait([
        ...processingUploads,
        ...readyForUploadingUploads,
        ...failedUploads,
      ]);
      await Future.wait(uploaderList.map((uploader) => uploader.upload(headers: headers)));
      await _uploadFiles(prefs, service);
    }
  }

  @pragma('vm:entry-point')
  static Iterable<Future<TusFileUploader>> _getProcessingUploads(
    SharedPreferences prefs,
    ServiceInstance service,
  ) {
    final allUploadingFiles = prefs.getProcessingUploading();
    final filesToUpload = <UploadingModel>[];
    final filesToRemove = <UploadingModel>[];
    for (var model in allUploadingFiles) {
      if (model.existsSync) {
        filesToUpload.add(model);
      } else {
        filesToRemove.add(model);
      }
    }
    for (var path in filesToRemove) {
      prefs.removeFile(path, processingStoreKey);
    }
    final metadata = prefs.getMetadata();
    final headers = prefs.getHeaders();
    return allUploadingFiles
        .where((e) => !cache.containsKey(e) && filesToUpload.contains(e))
        .map((model) async {
      final uploader = await _uploaderFromPath(
        service,
        model,
        metadata: metadata,
        headers: headers,
      );
      cache[model.id] = uploader;
      return uploader;
    });
  }

  @pragma('vm:entry-point')
  static Iterable<Future<TusFileUploader>> _getreadyForUploadingUploads(
    SharedPreferences prefs,
    ServiceInstance service,
  ) {
    final allReadyForUploadingFiles = prefs.getReadyForUploading();
    final filesToUpload = <UploadingModel>[];
    final filesToRemove = <UploadingModel>[];
    for (var model in allReadyForUploadingFiles) {
      if (model.existsSync) {
        filesToUpload.add(model);
      } else {
        filesToRemove.add(model);
      }
    }
    for (var path in filesToRemove) {
      prefs.removeFile(path, readyForUploadingStoreKey);
    }
    final metadata = prefs.getMetadata();
    final headers = prefs.getHeaders();
    return allReadyForUploadingFiles
        .where((e) => !cache.containsKey(e) && filesToUpload.contains(e))
        .map((model) async {
      final uploader = await _uploaderFromPath(
        service,
        model,
        metadata: metadata,
        headers: headers,
      );
      cache[model.id] = uploader;
      final uploadUrl = await uploader.setupUploadUrl();
      if (uploadUrl != null) {
        prefs.addFileToProcessing(uploadingModel: model);
      } else {
        prefs.removeFile(model, processingStoreKey);
      }
      return uploader;
    });
  }

  @pragma('vm:entry-point')
  static Iterable<Future<TusFileUploader>> _getFailedUploads(
    SharedPreferences prefs,
    ServiceInstance service,
  ) {
    final allFailedFiles = prefs.getFailedUploading();
    final filesToUpload = <UploadingModel>[];
    final filesToRemove = <UploadingModel>[];
    for (var model in allFailedFiles) {
      if (model.existsSync) {
        filesToUpload.add(model);
      } else {
        filesToRemove.add(model);
      }
    }
    for (var path in filesToRemove) {
      prefs.removeFile(path, failedStoreKey);
    }
    final metadata = prefs.getMetadata();
    final headers = prefs.getHeaders();
    return allFailedFiles
        .where((e) => !cache.containsKey(e) && filesToUpload.contains(e))
        .map((model) async {
      final uploader = await _uploaderFromPath(
        service,
        model,
        metadata: metadata,
        headers: headers,
      );
      cache[model.id] = uploader;
      final uploadUrl = await uploader.setupUploadUrl();
      if (uploadUrl != null) {
        prefs.addFileToProcessing(uploadingModel: model);
      } else {
        prefs.removeFile(model, processingStoreKey);
      }
      return uploader;
    });
  }

  @pragma('vm:entry-point')
  static Future<TusFileUploader> _uploaderFromPath(
    ServiceInstance service,
    UploadingModel uploadingModel, {
    Map<String, String>? headers,
    Map<String, String>? metadata,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    var filePath = uploadingModel.path;
    final xFile = XFile(filePath);
    final totalBytes = await xFile.length();
    final uploadMetadata = xFile.generateMetadata(originalMetadata: metadata);
    final resultHeaders = Map<String, String>.from(headers ?? {})
      ..addAll({
        "Tus-Resumable": tusVersion,
        "Upload-Metadata": uploadMetadata,
        "Upload-Length": "$totalBytes",
      });
    final baseUrl = prefs.getBaseUrl();
    final timeout = prefs.getTimeout();
    if (baseUrl == null) {
      throw Exception('baseUrl is required');
    }
    final failOnLostConnection = prefs.getFailOnLostConnection();
    final loggerLevel = _objectsCache["logger_level"] ?? Level.off;
    return TusFileUploader(
      uploadingModel: uploadingModel,
      timeout: timeout,
      baseUrl: baseUrl,
      headers: resultHeaders,
      failOnLostConnection: failOnLostConnection,
      loggerLevel: loggerLevel,
      progressCallback: (uploadingModel, progress) async => _onProgress(
        uploadingModel: uploadingModel,
        progress: progress,
        service: service,
      ),
      completeCallback: (uploadingModel, uploadUrl) async => _onNextFileComplete(
        service: service,
        uploadingModel: uploadingModel,
        uploadUrl: uploadUrl,
      ),
      failureCallback: (uploadingModel, _) async => _onNextFileFailed(
        uploadingModel: uploadingModel,
        service: service,
      ),
      authCallback: (uploadingModel, _) async => _onAuthFailed(
        uploadingModel: uploadingModel,
        service: service,
      ),
      serverErrorCallback: (uploadingModel, _) async => _onServerError(
        uploadingModel: uploadingModel,
        service: service,
      ),
    );
  }

  @pragma('vm:entry-point')
  static Logger buildLogger(SharedPreferences prefs) {
    var logger = _objectsCache["logger"];
    if (logger == null) {
      final loggerLevel = prefs.getLoggerLevel();
      final Level level;
      switch (loggerLevel) {
        case 0:
          level = Level.all;
          break;
        case 2000:
          level = Level.debug;
          break;
        case 5000:
          level = Level.error;
          break;
        default:
          level = Level.off;
          break;
      }
      logger = Logger(
        level: level,
        printer: PrettyPrinter(
          methodCount: 0,
        ),
      );
      _objectsCache["logger"] = logger;
      _objectsCache["logger_level"] = level;
    }
    return logger!;
  }

  @pragma('vm:entry-point')
  static Future<void> updateNotification({
    required String title,
    required int progress,
    required bool iosShowProgress,
    String? appIcon,
  }) async {
    await FlutterLocalNotificationsPlugin().show(
      _NotificationIds.uploadProgress.id,
      title,
      '',
      NotificationDetails(
        android: AndroidNotificationDetails(
          'my_foreground',
          'MY FOREGROUND SERVICE',
          showProgress: true,
          progress: progress,
          maxProgress: 100,
          icon: appIcon ?? 'ic_bg_service_small',
          ongoing: true,
        ),
        iOS: DarwinNotificationDetails(
            presentAlert: true,
            subtitle: iosShowProgress ? 'Progress $progress%' : null,
            interruptionLevel: InterruptionLevel.passive),
      ),
    );
  }

  @pragma('vm:entry-point')
  static Future<File?> compressImageIfNeeded(
    SharedPreferences prefs,
    String path,
    CompressParams params,
  ) async {
    final file = File(path);
    final length = await file.length();
    final logger = buildLogger(prefs);
    logger.d('ORIGINAL FILE SIZE: ${length ~/ 1000}KB');
    File? compressedFile;
    if (length > params.idealSize) {
      final rootDir = await path_provider.getApplicationDocumentsDirectory();
      final timeStamp = DateTime.now().millisecondsSinceEpoch;
      final targetPath = '${rootDir.path}/$managerDocumentsDir/$timeStamp${file.hashCode}.jpg';
      final relation = params.idealSize / length;
      final qualityKoef = 0.75 * relation;
      final quality = (qualityKoef + relation) * 100;
      final bytes = await file.readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      var finalWidth = descriptor.width;
      var finalHeight = descriptor.height;
      if (max(finalWidth, finalHeight) > params.relativeWidth) {
        if (finalWidth > finalHeight) {
          finalHeight = (params.relativeWidth / finalWidth * finalHeight).toInt();
          finalWidth = params.relativeWidth;
        } else {
          finalWidth = (params.relativeWidth / finalHeight * finalWidth).toInt();
          finalHeight = params.relativeWidth;
        }
      }
      final xFile = await FlutterImageCompress.compressAndGetFile(
        file.absolute.path,
        targetPath,
        minWidth: finalWidth,
        minHeight: finalHeight,
        quality: quality.toInt(),
        keepExif: true,
      );
      if (xFile != null) {
        final resultLength = await xFile.length();
        logger.d('COMPRESSED FILE SIZE: ${resultLength ~/ 1000}KB');
        final File fileToDelete;
        if (resultLength < length) {
          compressedFile = File(xFile.path);
          fileToDelete = file;
        } else {
          fileToDelete = File(xFile.path);
        }

        await fileToDelete.safeDelete();
      }
    }
    return compressedFile;
  }

  @pragma('vm:entry-point')
  static Future _dispose(ServiceInstance service) async {
    await Future.delayed(const Duration(seconds: 2)).whenComplete(
        () => FlutterLocalNotificationsPlugin().cancel(_NotificationIds.uploadProgress.id));
    service.stopSelf();
    cache.clear();
  }
}
