import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart' as bsa;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tus_bg_file_uploader/src/image_compressor.dart';
import 'package:tus_file_uploader/tus_file_uploader.dart';

import 'extensions.dart';

const _progressStream = 'progress_stream';
const _completionStream = 'completion_stream';
const _failureStream = 'failure_stream';
const _authFailureStream = 'auth_stream';
const _serverErrorStream = 'server_error';
const _updatePathStream = 'update_path_stream';
const _allFilesUploadedStream = 'all_files_uploaded_stream';
const _logsStream = 'logs_stream';
const notifChannelId = 'my_foreground';
const managerDocumentsDir = 'bgFileUploaderManager';

@pragma('vm:entry-point')
enum _NotificationIds {
  uploadProgress(888),
  // uploadFailure(333)
  ;

  final int id;

  const _NotificationIds(this.id);
}

class TusBGFileUploaderManager {
  @pragma('vm:entry-point')
  static final _instance = TusBGFileUploaderManager._();
  @pragma('vm:entry-point')
  static final _objectsCache = <String, dynamic>{};

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

  Stream<Map<String, dynamic>?> get updatePathStream => FlutterBackgroundService().on(
        _updatePathStream,
      );

  Stream<Map<String, dynamic>?> get allFilesUploadedStream => FlutterBackgroundService().on(
        _allFilesUploadedStream,
      );

  Stream<Map<String, dynamic>?> get logsStream => FlutterBackgroundService().on(
        _logsStream,
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

    if (Platform.isAndroid) await initAndroidNotifChannelIfNeeded();

    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: notifChannelId,
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

  Future<void> initAndroidNotifChannelIfNeeded() async {
    final channelInitialized = (await FlutterLocalNotificationsPlugin()
                .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
                ?.getNotificationChannels())
            ?.any((channel) => channel.id == notifChannelId) ==
        true;

    if (channelInitialized) return;

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
      notifChannelId, // id
      'MY FOREGROUND SERVICE', // title
      description: 'This channel is used for important notifications.', // description
      importance: Importance.low, // importance must be at low or higher level
    );

    await FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  Future<List<UploadingModel>> checkForUnfinishedUploads() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.actualizeUnfinishedUploads(_buildLogger(prefs));
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
      await prefs.addFileToPending(
        uploadingModel: model,
        logger: _buildLogger(prefs),
      );
    }

    await prefs.setHeadersMetadata(headers: headers, metadata: metadata);
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    } else {
      await _persistFilesForUpload(
        uploadingModels: uploadingModels,
        sharedPreferences: prefs,
      );
      _logExistingFiles('UPLOAD NOT STARTED - SERVICE IS RUNNING', prefs);
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
        if (model.uploadUrl != null) {
          await prefs.addFileToProcessing(
            uploadingModel: model,
            logger: _buildLogger(prefs),
          );
        } else {
          await prefs.addFileToReadyForUpload(
            uploadingModel: model,
            logger: _buildLogger(prefs),
          );
        }
      }
    }
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    } else {
      await Future.delayed(const Duration(seconds: 5)).then((value) async {
        final isRunning = await service.isRunning();
        if (!isRunning) {
          await service.startService();
        }
      });
    }
  }

  Future<void> removeFileById(int modelId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final storeKeys = [
      pendingStoreKey,
      readyForUploadingStoreKey,
      processingStoreKey,
      completeStoreKey,
      failedStoreKey,
    ];
    for (final storeKey in storeKeys) {
      final allFiles = prefs.getFilesForKey(storeKey);
      for (final model in allFiles) {
        if (model.id == modelId) {
          prefs.removeFile(
            model,
            storeKey,
            _buildLogger(prefs),
          );
          if (storeKey != pendingStoreKey) File(model.path).safeDelete();
          break;
        }
      }
    }
  }

  void resumeAllUploads() async {
    final unfinishedFiles = await checkForUnfinishedUploads();
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await prefs.setUploadAfterStartingService(true);

    if (unfinishedFiles.isEmpty) return;

    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }
    _buildLogger(prefs).d(
      "RESUME UPLOADING\n=> Unfinished files: ${unfinishedFiles.length}",
    );
  }

  void stopService() async {
    final service = FlutterBackgroundService();
    service.invoke("stop");
    disposeLogger();
  }

  Future<bool> clearStorage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.clearStorage();
  }

  // BACKGROUND ------------------------------------------------------------------------------------
  @pragma('vm:entry-point')
  static _onStart(ServiceInstance service) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await _persistFilesForUpload(
      sharedPreferences: prefs,
      service: service,
    );
    if (!prefs.getUploadAfterStartingService()) {
      _dispose(service);
      return;
    }
    ui.DartPluginRegistrant.ensureInitialized();
    if (service is bsa.AndroidServiceInstance) {
      service.setAsForegroundService();
    }
    service.on('stop').listen((_) => _dispose(service));

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
    await prefs.reload();
    await prefs.addFileToComplete(
      uploadingModel: uploadingModel,
      logger: _buildLogger(prefs),
    );
    await _updateProgress(currentFileProgress: 1);
    service.invoke(_completionStream, {'id': uploadingModel.id, 'url': uploadUrl});
  }

  @pragma('vm:entry-point')
  static Future<void> _onProgress({
    required UploadingModel uploadingModel,
    required double progress,
    required int lastChunkSize,
    required ServiceInstance service,
  }) async {
    service.invoke(_progressStream, {
      "id": uploadingModel.id,
      "progress": (progress * 100).toInt(),
      "lastChunkSize": lastChunkSize,
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
    await prefs.reload();
    await prefs.addFileToFailed(
      uploadingModel: uploadingModel,
      logger: _buildLogger(prefs),
    );
    service.invoke(_failureStream, {'id': uploadingModel.id});
  }

  @pragma('vm:entry-point')
  static Future<void> _onAuthFailed({
    required UploadingModel uploadingModel,
    required ServiceInstance service,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await prefs.addFileToFailed(
      uploadingModel: uploadingModel,
      logger: _buildLogger(prefs),
    );
    service.invoke(_authFailureStream, {'id': uploadingModel.id});
  }

  @pragma('vm:entry-point')
  static Future<void> _onServerError({
    required UploadingModel uploadingModel,
    required ServiceInstance service,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    await prefs.addFileToFailed(
      uploadingModel: uploadingModel,
      logger: _buildLogger(prefs),
    );
    service.invoke(_serverErrorStream, {'id': uploadingModel.id});
  }

  // PRIVATE ---------------------------------------------------------------------------------------
  @pragma('vm:entry-point')
  static Future<void> _uploadFiles(
    SharedPreferences prefs,
    ServiceInstance service, [
    Iterable<UploadingModel> processingUploads = const [],
    Iterable<UploadingModel> failedUploads = const [],
  ]) async {
    await prefs.reload();
    final readyForUploadingUploads = _getReadyForUploadingUploads(prefs, service);
    final headers = prefs.getHeaders();
    final total = processingUploads.length + readyForUploadingUploads.length + failedUploads.length;
    _logExistingFiles('TRY TO UPLOAD FILES', prefs, service: service);
    if (total > 0) {
      final uploadingModels = [
        ...processingUploads,
        ...readyForUploadingUploads,
        ...failedUploads,
      ];
      for (final uploadingModel in uploadingModels) {
        final uploader = await _prepareUploader(
          service: service,
          model: uploadingModel,
          prefs: prefs,
        );
        await uploader.upload(headers: headers);
        _logExistingFiles('NEXT FILE UPLOADING FINISHED', prefs, service: service);
      }
      await prefs.reload();
      final processingUploadsLeft = _getProcessingUploads(prefs, service);
      await _uploadFiles(prefs, service, processingUploadsLeft);
    } else {
      service.invoke(_allFilesUploadedStream);
      _logExistingFiles('ALL FILES UPLOADING FINISHED', prefs, service: service);
    }
  }

  @pragma('vm:entry-point')
  static Future<void> _persistFilesForUpload({
    List<UploadingModel>? uploadingModels,
    required SharedPreferences sharedPreferences,
    ServiceInstance? service,
  }) async {
    final models = uploadingModels ?? sharedPreferences.getPendingUploading();
    final compressParams = sharedPreferences.getCompressParams();
    for (final model in models) {
      final notPersistedFile = File(model.path);
      final persistedFile = await notPersistedFile.saveToDocumentsDir();
      File? compressedFile;
      if (compressParams != null) {
        compressedFile = await ImageCompressor.compressImageIfNeeded(
          sharedPreferences,
          persistedFile.path,
          compressParams,
          _buildLogger(
            sharedPreferences,
            service: service,
          ),
        );
      }
      model.path = compressedFile?.path ?? persistedFile.path;
      service?.invoke.call(_updatePathStream, {model.id.toString(): model.path});
      await sharedPreferences.addFileToReadyForUpload(
        uploadingModel: model,
        logger: _buildLogger(sharedPreferences, service: service),
      );
    }
  }

  @pragma('vm:entry-point')
  static List<UploadingModel> _getProcessingUploads(
    SharedPreferences prefs,
    ServiceInstance service,
  ) {
    final allUploadingFiles = prefs.getProcessingUploading();
    final filesToUpload = <UploadingModel>[];
    for (var model in allUploadingFiles) {
      if (model.existsSync) {
        filesToUpload.add(model);
      } else {
        prefs.removeFile(
          model,
          processingStoreKey,
          _buildLogger(prefs),
        );
      }
    }
    return filesToUpload;
  }

  @pragma('vm:entry-point')
  static List<UploadingModel> _getReadyForUploadingUploads(
    SharedPreferences prefs,
    ServiceInstance service,
  ) {
    final allReadyForUploadingFiles = prefs.getReadyForUploading();
    final filesToUpload = <UploadingModel>[];
    for (var model in allReadyForUploadingFiles) {
      if (model.existsSync) {
        filesToUpload.add(model);
      } else {
        prefs.removeFile(
          model,
          readyForUploadingStoreKey,
          _buildLogger(prefs),
        );
      }
    }
    return filesToUpload;
  }

  static Future<TusFileUploader> _prepareUploader({
    required ServiceInstance service,
    required UploadingModel model,
    required SharedPreferences prefs,
  }) async {
    final uploader = await _uploaderFromPath(
      service,
      prefs,
      model,
    );
    await uploader.setupUploadUrl();
    await prefs.addFileToProcessing(
      uploadingModel: model,
      logger: _buildLogger(prefs),
    );
    _logExistingFiles(
      'FILES BEFORE NEXT UPLOADING',
      prefs,
      service: service,
    );
    return uploader;
  }

  @pragma('vm:entry-point')
  static Future<TusFileUploader> _uploaderFromPath(
    ServiceInstance service,
    SharedPreferences prefs,
    UploadingModel uploadingModel,
  ) async {
    var filePath = uploadingModel.path;
    final metadata = prefs.getMetadata();
    final headers = prefs.getHeaders();
    final xFile = XFile(filePath);
    final totalBytes = await xFile.length();
    final uploadMetadata = xFile.generateMetadata(originalMetadata: metadata);
    final resultHeaders = Map<String, String>.from(headers)
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
      progressCallback: (uploadingModel, progress, lastChunkSize) async => _onProgress(
        uploadingModel: uploadingModel,
        progress: progress,
        lastChunkSize: lastChunkSize,
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
  static Future<void> _logExistingFiles(
    String header,
    SharedPreferences prefs, {
    ServiceInstance? service,
  }) async {
    await prefs.reload();
    final failedUploads = prefs.getFailedUploading();
    final pendingUploads = prefs.getPendingUploading();
    final readyForUploading = prefs.getReadyForUploading();
    final processingUploads = prefs.getProcessingUploading();
    _buildLogger(prefs, service: service).d(
      "$header\n=> Pending files: ${pendingUploads.length}\n=> Processing files: ${processingUploads.length}\n=> Ready for upload files: ${readyForUploading.length}\n=> Failed files: ${failedUploads.length}",
    );
  }

  @pragma('vm:entry-point')
  static Logger _buildLogger(
    SharedPreferences prefs, {
    ServiceInstance? service,
  }) {
    var logger = _objectsCache["logger"] as Logger?;
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
      Logger.addLogListener((event) {
        final sender = service ?? FlutterBackgroundService();
        sender.invoke(_logsStream, {event.level.name: event.message});
      });
    }
    return logger;
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
          notifChannelId,
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
  static Future _dispose(ServiceInstance service) async {
    service.stopSelf();
    disposeLogger();
    Future.delayed(const Duration(seconds: 2)).whenComplete(
        () => FlutterLocalNotificationsPlugin().cancel(_NotificationIds.uploadProgress.id));
  }

  static void disposeLogger(){
    (_objectsCache['logger'] as Logger?)?.close();
    _objectsCache.remove('logger');
  }
}
