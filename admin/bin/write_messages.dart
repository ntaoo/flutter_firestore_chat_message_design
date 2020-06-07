import 'dart:async';

import 'package:firebase_admin_interop/firebase_admin_interop.dart';

Future<void> main() async {
  final serviceAccountKeyFilename =
      '/Users/naoto/private_keys/chat-message2/chat-message2-82df3-firebase-adminsdk-k63ez-5a90bdf09e.json';
  final admin = FirebaseAdmin.instance;
  final cert = admin.certFromPath(serviceAccountKeyFilename);
  final app = admin.initializeApp(AppOptions(
    projectId: 'chat-message2-82df3',
    credential: cert,
    databaseURL: 'https://chat-message2-82df3.firebaseio.com',
  ));
  final firestore = app.firestore();
  await batchWriteMessage(firestore);
}

Future<void> batchWriteMessage(Firestore firestore) async {
  final total = 500;
  final batchOperationLimit = 500;
  final batchSetLimit = total / batchOperationLimit;
  final oldestTime = DateTime.now().subtract(Duration(days: 1));

  for (var currentBatchSet = 1;
      currentBatchSet <= batchSetLimit;
      currentBatchSet++) {
    await _batchWriteMessage(
        firestore,
        (currentBatchSet - 1) * batchOperationLimit,
        batchOperationLimit,
        oldestTime);
    print('batch write set $currentBatchSet done.');
  }
  print('done');
}

Future<void> _batchWriteMessage(Firestore firestore, int completedNumber,
    int limit, DateTime oldestTime) async {
  final collection = firestore.collection(messagesCollectionPath);
  final batch = firestore.batch();
  for (var i = 1; i <= limit; i++) {
    final order = completedNumber + i;
    batch.setData(
        collection.document(),
        DocumentData()
          ..setString(MessageDocumentDataSchema.body,
              generateMessageBody(order, 'added'))
          ..setTimestamp(MessageDocumentDataSchema.bodyModifiedAt, null)
          ..setTimestamp(
              MessageDocumentDataSchema.sentAt,
              Timestamp.fromDateTime(
                  oldestTime.add(Duration(seconds: order)))));
  }
  await batch.commit();
}

const messagesCollectionPath = 'messages';

class MessageDocumentDataSchema {
  static const body = 'body';
  static const sentAt = 'sentAt';
  static const bodyModifiedAt = 'bodyModifiedAt';
}

String generateMessageBody(int order, String changeType) {
  assert(changeType == 'added' || changeType == 'modified');
  return '$order $changeType';
}
