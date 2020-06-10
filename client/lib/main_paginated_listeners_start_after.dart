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
  final MessagesWithPaginatedListenersStrategy _messages;
  MyApp()
      : _messages =
            MessagesWithPaginatedListenersStrategy(MessagesRepository());
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
  final MessagesWithPaginatedListenersStrategy _messages;
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

  Stream<UnmodifiableListView<Stream<UnmodifiableListView<Message>>>>
      get messages => _messages.messages;

  void dispose() {
    scrollController.dispose();
  }

  void deleteMessage(String messageId) {
    _messages.deleteById(messageId);
  }
}

class MessageList extends StatelessWidget {
  static Provider inController(
      MessagesWithPaginatedListenersStrategy messages) {
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
      body: StreamBuilder<
          UnmodifiableListView<Stream<UnmodifiableListView<Message>>>>(
        stream: controller.messages,
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data.isEmpty) {
            return const SizedBox.shrink();
          }

          final messagesList = snapshot.data;
          return CustomScrollView(
            reverse: true,
            controller: controller.scrollController,
            slivers: messagesList.map(
              (messages) {
                return StreamBuilder<UnmodifiableListView<Message>>(
                  stream: messages,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData || snapshot.data.isEmpty) {
                      return SliverList(delegate: SliverChildListDelegate([]));
                    }

                    final messages = snapshot.data;
                    return SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final message = messages[index];
                          var additionalInfo = '';
                          if (index == messages.length - 1) {
                            additionalInfo = 'last message';
                          } else if (index == 0) {
                            additionalInfo = 'first message';
                          }
                          return ListTile(
                            title: Text(
                                '${message.body} data from ${message.isFromCache ? 'cache' : 'server'} $additionalInfo'),
                            subtitle: Text(
                                '${message.sentAt.hour}:${message.sentAt.minute}:${message.sentAt.second}. day: ${message.sentAt.day}'),
                            trailing: IconButton(
                              icon: Icon(Icons.delete),
                              onPressed: () =>
                                  controller.deleteMessage(message.id),
                            ),
                          );
                        },
                        childCount: messages.length,
                      ),
                    );
                  },
                );
              },
            ).toList(),
          );
        },
      ),
    );
  }
}

class MessagesWithPaginatedListenersStrategy {
  static const _partitionSize = 50;
  final _paginationController = StreamController<void>();
  final _paginatedMessages = BehaviorSubject<List<Messages>>.seeded([]);
  final MessagesRepository _repository;

  bool _hasLastBatch = false;

  MessagesWithPaginatedListenersStrategy(this._repository) {
    _initialize();
  }

  Sink<void> get prev => _paginationController.sink;

  Stream<UnmodifiableListView<Stream<UnmodifiableListView<Message>>>>
      get messages => _paginatedMessages.stream
          .map((list) => UnmodifiableListView(list.map((e) => e.messages)));

  void _initialize() async {
    final messages = Messages(_repository, _partitionSize);
    await messages.messages.first;
    _paginatedMessages.value = _paginatedMessages.value..add(messages);
    _initializePagination();
  }

  void _initializePagination() async {
    _paginationController.stream.exhaustMap((_) async* {
      if (_hasLastBatch) {
        yield null;
      } else {
        final messageBatch = Messages(_repository, _partitionSize,
            startAfterPosition:
                _paginatedMessages.value.last.lastMessageSentAt);

        final first = await messageBatch.messages.first;

        if (first.length < _partitionSize) {
          _hasLastBatch = true;
        }

        yield messageBatch;
      }
    }).listen((messageBatch) {
      if ((messageBatch == null)) return;
      _paginatedMessages.value = _paginatedMessages.value..add(messageBatch);
    });
  }

  void deleteById(String messageId) {
    _repository.remove(messageId);
  }

  void dispose() {
    _paginationController.close();
    _paginatedMessages.close();
  }
}

class Messages {
  final _messages = BehaviorSubject<List<Message>>.seeded([]);

  final MessagesRepository _repository;
  final int _partitionSize;
  final DateTime _startAfterPosition;

  StreamSubscription<List<DataChange<Message>>> _subscription;

  Messages(this._repository, this._partitionSize, {DateTime startAfterPosition})
      : _startAfterPosition = startAfterPosition {
    _listen();
  }

  Stream<UnmodifiableListView<Message>> get messages => _messages.stream
      .where((e) => e.isNotEmpty)
      .map((e) => UnmodifiableListView(e));

  DateTime get lastMessageSentAt => _messages.value.last.sentAt;

  int get size => _messages.value.length;

  void _listen() async {
    assert(_subscription == null);

    _subscription = _repository
        .changes(_partitionSize, startAfter: _startAfterPosition)
        .listen((dataChanges) {
      final messages = _messages.value;
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

  void dispose() {
    _subscription.cancel();
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
  Stream<List<DataChange<Message>>> changes(int limitNumber,
      {DateTime startAfter}) {
    var query = Firestore.instance
        .collection('messages')
        .orderBy('sentAt', descending: true)
        .limit(limitNumber);
    if (startAfter != null) {
      query = query.startAfter([startAfter]);
    }

    return query.snapshots().map((qs) {
      querySnapshotDebugPrint(
          qs, 'result of start after ${startAfter.toIso8601String()}');
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
