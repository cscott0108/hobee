import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'clean.dart';
import 'download.dart';
import 'saved.dart';

const _media = MethodChannel('hobee/media');

/// Getting files out of the private Hobees gallery: into the phone's gallery one by one, as one .zip in
/// Downloads, or through the Android share sheet. Files keep the plain timestamp name of when they were saved.
class GalleryExport {
  /// Test seam: the Android share sheet.
  static Future<void> Function(List<XFile> files) shareFiles =
      (files) async {
        await SharePlus.instance.share(ShareParams(files: files));
      };

  static String nameFor(SavedItem it) => timestampName(DateTime.fromMillisecondsSinceEpoch(it.savedAt), it.ext == 'jpeg' ? 'jpg' : it.ext);

  /// File names inside the zip: the timestamp names, with _1, _2 … where two were saved in the same second.
  static List<String> zipNames(List<SavedItem> items) {
    final used = <String>{};
    final out = <String>[];
    for (final it in items) {
      final base = nameFor(it);
      final dot = base.lastIndexOf('.');
      var n = base;
      for (var k = 1; !used.add(n); k++) {
        n = '${base.substring(0, dot)}_$k${base.substring(dot)}';
      }
      out.add(n);
    }
    return out;
  }

  /// Each item into Pictures / Movies so it shows in the phone's gallery. Returns the items that made it.
  static Future<List<SavedItem>> toPhone(List<SavedItem> items) async {
    await Downloader.askStorage();
    final done = <SavedItem>[];
    for (final it in items) {
      try {
        await _media.invokeMethod<String>('save', {'path': it.path, 'name': nameFor(it), 'mime': mimeFor(it.ext), 'video': it.isVideo});
        done.add(it);
      } catch (_) {}
    }
    return done;
  }

  /// All [items] in one .zip in Downloads. Returns where it went.
  static Future<String> toZip(List<SavedItem> items) async {
    await Downloader.askStorage();
    final r = await _media.invokeMethod<String>('zip', {
      'paths': [for (final it in items) it.path],
      'names': zipNames(items),
      'name': 'Hobees_${timestampName(DateTime.now(), 'zip')}',
    });
    return r ?? '';
  }

  static Future<void> share(List<SavedItem> items) =>
      shareFiles([for (final it in items) XFile(it.path, mimeType: mimeFor(it.ext))]);
}
