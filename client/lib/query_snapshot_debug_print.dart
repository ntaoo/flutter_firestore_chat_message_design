import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

void querySnapshotDebugPrint(QuerySnapshot qs, String title) {
  debugPrint('-- $title ------------');
  final isAllFromCache = qs.documentChanges
      .every((element) => element.document.metadata.isFromCache);
  debugPrint('is all from cache: $isAllFromCache');
  qs.documentChanges.forEach((element) {
    debugPrint(element.document.metadata.isFromCache.toString());
  });
  debugPrint('document size: ${qs.documentChanges.length}');
  debugPrint('-- $title ------------');
}
