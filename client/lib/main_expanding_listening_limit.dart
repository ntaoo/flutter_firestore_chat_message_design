import 'dart:async';
import 'dart:collection';

import 'package:client/query_snapshot_debug_print.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:rxdart/rxdart.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  Firestore.instance.settings(persistenceEnabled: false);
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  final MessagesWithExpandingListeningLimitStrategy _messages;
  MyApp()
      : _messages =
            MessagesWithExpandingListeningLimitStrategy(MessagesRepository());
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: MessageList.inController(_messages),
    );
  }
}

class MessageListController {
  final scrollController = ScrollController();
  final MessagesWithExpandingListeningLimitStrategy _messages;
  MessageListController(this._messages) {
    scrollController.addListener(() {
      if (scrollController.position.atEdge) {
        if (scrollController.position.pixels == 0) {
          debugPrint('top');
        } else {
          debugPrint('bottom');
          _messages.prev.add(null);
        }
      }
    });
  }

  Stream<UnmodifiableListView<Message>> get messages => _messages.messages;

  void dispose() {
    scrollController.dispose();
  }

  void deleteMessage(String messageId) {
    _messages.deleteById(messageId);
  }
}

class MessageList extends StatelessWidget {
  static Provider inController(
      MessagesWithExpandingListeningLimitStrategy messages) {
    return Provider<MessageListController>(
      create: (_) => MessageListController(messages),
      dispose: (_, self) => self.dispose(),
      child: MessageList._(),
    );
  }

  const MessageList._();

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<MessageListController>(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('Chat Messages'),
      ),
      body: StreamBuilder<UnmodifiableListView<Message>>(
        stream: controller.messages,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const SizedBox.shrink();
          }

          final messages = snapshot.data;
          return ListView.builder(
            reverse: true,
            controller: controller.scrollController,
            itemCount: messages.length,
            itemBuilder: (context, index) {
              final message = messages[index];
              return ListTile(
                title: Text(
                    '${message.body} data from ${message.isFromCache ? 'cache' : 'server'}'),
                subtitle: Text(
                    '${message.sentAt.hour}:${message.sentAt.minute}:${message.sentAt.second}. day: ${message.sentAt.day}'),
                trailing: IconButton(
                  icon: Icon(Icons.delete),
                  onPressed: () => controller.deleteMessage(message.id),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class MessagesWithExpandingListeningLimitStrategy {
  static const _limitUnit = 50;
  final _paginationController = StreamController<void>();
  final _messages = BehaviorSubject<List<Message>>.seeded([]);
  final MessagesRepository _repository;

  int _currentLimit = _limitUnit;
  StreamSubscription _subscription;

  bool _hasAll = false;

  MessagesWithExpandingListeningLimitStrategy(this._repository) {
    _initialize();
  }

  Sink<void> get prev => _paginationController.sink;

  Stream<UnmodifiableListView<Message>> get messages => _messages.stream
      .where((e) => e.isNotEmpty)
      .map((e) => UnmodifiableListView(e));

  void _initialize() {
    _listen();
    _initializePagination();
  }

  void _initializePagination() async {
    _paginationController.stream.exhaustMap((_) async* {
      if (_hasAll) {
        yield null;
      } else {
        final lastLength = _messages.value.length;
        _currentLimit += _limitUnit;

        await _listen();
        final latest = await messages.first;

        if (lastLength >= latest.length) {
          _hasAll = true;
        }

        yield null;
      }
    }).listen((_) {});
  }

  Future<void> _listen() async {
    await _subscription?.cancel();
    _subscription = null;
    _messages.value = [];

    _subscription = _repository.changes(_currentLimit).listen((dataChanges) {
      final messages = _messages.value;
      debugPrint('dataChanges.length: ${dataChanges.length}');
      for (final change in dataChanges) {
        switch (change.type) {
          case ChangeType.added:
            debugPrint('added');
            messages.insert(change.newIndex, change.data);
            break;
          case ChangeType.modified:
            debugPrint('modified');
            if (change.oldIndex == change.newIndex) {
              messages[change.oldIndex] = change.data;
            } else {
              messages
                ..removeAt(change.oldIndex)
                ..insert(change.newIndex, change.data);
            }
            break;
          case ChangeType.removed:
            debugPrint('removed');
            messages.removeAt(change.oldIndex);
            break;
        }
      }
      _messages.value = messages;
    });
  }

  void deleteById(String messageId) {
    _repository.remove(messageId);
  }

  void dispose() {
    _subscription.cancel();
    _paginationController.close();
    _messages.close();
  }
}

class Message {
  final String id;
  final String body;
  final DateTime bodyModifiedAt;
  final DateTime sentAt;
  final bool isFromCache;

  Message(
      this.id, this.body, this.bodyModifiedAt, this.sentAt, this.isFromCache);
}

class MessagesRepository {
  Stream<List<DataChange<Message>>> changes(int limitNumber) {
    return Firestore.instance
        .collection('messages')
        .orderBy('sentAt', descending: true)
        .limit(limitNumber)
        .snapshots()
        .map((qs) {
      querySnapshotDebugPrint(qs, 'expanding listening limit');
      return qs.documentChanges.map((change) {
        var changeType;
        switch (change.type) {
          case DocumentChangeType.added:
            changeType = ChangeType.added;
            break;
          case DocumentChangeType.modified:
            changeType = ChangeType.modified;
            break;
          case DocumentChangeType.removed:
            changeType = ChangeType.removed;
            break;
        }
        return DataChange(
            changeType,
            _toData(change.document, change.document.metadata.isFromCache),
            change.oldIndex,
            change.newIndex);
      }).toList();
    });
  }

  Message _toData(DocumentSnapshot documentSnapshot, bool isFromCache) {
    final data = documentSnapshot.data;
    return Message(
        documentSnapshot.documentID,
        data['body'],
        _timestampToDateTime(data['bodyModifiedAt']),
        _timestampToDateTime(data['sentAt']),
        isFromCache);
  }

  DateTime _timestampToDateTime(Timestamp timestamp) => timestamp?.toDate();

  void remove(String messageId) async {
    await Firestore.instance
        .collection('messages')
        .document(messageId)
        .delete();
  }
}

enum ChangeType { added, modified, removed }

// Change information with data converted from firestore document.
class DataChange<T> {
  DataChange(this.type, this.data, this.oldIndex, this.newIndex);
  final ChangeType type;
  final T data;
  final int oldIndex;
  final int newIndex;
}
