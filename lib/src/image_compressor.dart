import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:logger/logger.dart';
import 'package:native_exif/native_exif.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tus_bg_file_uploader/tus_bg_file_uploader.dart';
import 'package:path_provider/path_provider.dart' as path_provider;

class ImageCompressor {
  @pragma('vm:entry-point')
  static Future<File?> compressImageIfNeeded(
    SharedPreferences prefs,
    String path,
    CompressParams params,
    Logger logger,
  ) async {
    Map<String, Object>? exifAttrs;
    if (params.saveExif) {
     exifAttrs = await _persistExifAttrs(path);
    }
    final file = File(path);
    final length = await file.length();
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
    if (compressedFile != null && exifAttrs != null) {
      restoreExifAttrs(compressedFile, exifAttrs);
    }
    return compressedFile;
  }

  static Future<Map<String, Object>?> _persistExifAttrs(String path) async {
    final exif = await Exif.fromPath(path);
    Map<String, Object>? exifAttrs = await exif.getAttributes();
    exif.close();
    return exifAttrs;
  }

  static Future<void> restoreExifAttrs(File file, Map<String, Object> exifAttrs) async {
    final exif = await Exif.fromPath(file.path);
    await exif.writeAttributes(exifAttrs);
    await exif.close();
  }
}
