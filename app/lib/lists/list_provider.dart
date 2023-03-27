import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../contacts/contact_provider.dart';
import '../extensions.dart';
import '../util/store.dart';
import '../util/uuid.dart';

const listIdsKey = 'list_id_keys';

class ListProvider {
  final String userId;
  final SqlCrdt _crdt;

  Stream<List<ToDoList>> get lists => _queryLists()
      .asyncMap((l) => Future.wait(l.map(
          (map) async => ToDoList.fromMap(map, await _getMembers(map['id'])))))
      .doOnError((p0, p1) => '$p0\n$p1'.log);

  ListProvider(this.userId, this._crdt, StoreProvider storeProvider);

  Future<void> createList(String name, Color color) async {
    final listId = uuid();

    await _crdt.transaction((txn) async {
      await txn.execute('''
        INSERT INTO lists (id, name, color, creator_id, created_at)
        VALUES (?1, ?2, ?3, ?4, ?5)
      ''',
          [listId, name, color.hexValue, userId, DateTime.now().toLocalString]);
      await _setListReference(txn, listId);
    });
  }

  Future<void> import(String listId) async {
    final exists = await _crdt.query('''
      SELECT EXISTS (
        SELECT * FROM user_lists WHERE user_id = ? AND list_id = ? AND is_deleted = 0
      ) AS e
    ''', [userId, listId]);
    if (exists.first['e'] == 1) {
      'Import: already have $listId'.log;
      return;
    }

    'Importing $listId'.log;
    await _setListReference(_crdt, listId);
  }

  Future<void> _setListReference(TimestampedCrdt crdt, String listId) async {
    final maxPosition = (await crdt.query('''
      SELECT max(position) as max_position FROM user_lists
      WHERE is_deleted = 0
    ''')).first['max_position'] as int? ?? -1;
    await crdt.execute('''
      INSERT INTO user_lists (user_id, list_id, created_at, position)
      VALUES (?1, ?2, ?3, ?4)
    ''', [userId, listId, DateTime.now().toLocalString, maxPosition + 1]);
  }

  Stream<List<Map<String, dynamic>>> _queryLists([String? listId]) =>
      _crdt.watch('''
        SELECT id, name, color, creator_id, lists.created_at, position, item_count, done_count FROM user_lists
        LEFT JOIN lists ON user_lists.user_id = ? AND user_lists.list_id = id
        LEFT JOIN (
          SELECT list_id as item_count_list_id, count(*) as item_count, sum(done) as done_count
          FROM todos WHERE is_deleted = 0 GROUP BY list_id
        ) ON item_count_list_id = id
        WHERE id IS NOT NULL AND user_lists.is_deleted = 0 ${listId != null ? 'AND id = ?' : ''}
        ORDER BY position
      ''', () => [userId, if (listId != null) listId]);

  Stream<ToDoListWithItems> getList(String listId) => _queryLists(listId)
      .map((e) => e.first)
      .asyncMap((map) async => ToDoListWithItems.fromMap(
            map,
            await _getMembers(listId),
            await _getToDos(listId),
          ));

  /// Removes the list from the user's references
  /// Does not actually delete the list, since it could be used by others
  Future<void> removeList(String listId) => removeUser(userId, listId);

  Future<void> removeUser(String userId, String listId) => _crdt.execute('''
    UPDATE user_lists SET is_deleted = ?1
    WHERE user_id = ?2 AND list_id = ?3
  ''', [1, userId, listId]);

  Future<void> undoRemoveList(String listId) => undoRemoveUser(userId, listId);

  Future<void> undoRemoveUser(String userId, String listId) => _crdt.execute('''
    UPDATE lists SET is_deleted = ?1
    WHERE user_id = ?2 AND list_id = ?3
  ''', [0, userId, listId]);

  Future<void> deleteItem(String id) => _crdt.execute('''
    UPDATE todos SET is_deleted = ?1
    WHERE id = ?2
  ''', [1, id]);

  Future<void> undeleteItem(String id) => _crdt.execute('''
    UPDATE todos SET is_deleted = ?1
    WHERE id = ?2
  ''', [0, id]);

  Future<void> setDone(String itemId, bool isDone) => _crdt.execute('''
    UPDATE todos SET
      done = ?1,
      done_at = ?2,
      done_by = ?3
    WHERE id = ?4
  ''', [
        isDone.toInt,
        isDone ? DateTime.now().toLocalString : null,
        isDone ? userId : null,
        itemId
      ]);

  Future<void> setItemName(String itemId, String name) => _crdt.execute('''
    UPDATE todos SET name = ?1
    WHERE id = ?2
  ''', [name, itemId]);

  void setName(String listId, String name) => _crdt.execute('''
    UPDATE lists SET name = ?1
    WHERE id = ?2
  ''', [name, listId]);

  void setColor(String listId, Color color) => _crdt.execute('''
    UPDATE lists SET color = ?1
    WHERE id = ?2
  ''', [color.hexValue, listId]);

  Future<String> createItem(String listId, String name) async {
    final id = uuid();
    final maxPosition = (await _crdt.query('''
      SELECT max(position) AS max_position FROM todos
      WHERE list_id = ? AND is_deleted = 0
    ''', [listId])).first['max_position'] as int? ?? -1;
    await _crdt.execute('''
      INSERT INTO todos (id, list_id, name, done, position, creator_id, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    ''', [
      id,
      listId,
      name,
      0,
      maxPosition + 1,
      userId,
      DateTime.now().toLocalString,
    ]);
    return id;
  }

  Future<void> setListOrder(List<ToDoList> lists) async {
    await _crdt.transaction((txn) async {
      for (int i = 0; i < lists.length; i++) {
        final list = lists[i];
        if (list.position != i) {
          await txn.execute('''
            UPDATE user_lists SET position = ?1
            WHERE user_id = ?2 AND list_id = ?3
          ''', [i, userId, list.id]);
        }
      }
    });
  }

  Future<void> setItemOrder(List<ToDo> items) async {
    await _crdt.transaction((txn) async {
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        if (item.position != i) {
          await txn.execute('''
            UPDATE todos SET position = ?1
            WHERE id = ?2
          ''', [i, item.id]);
        }
      }
    });
  }

  Future<List<Member>> _getMembers(String listId) => _crdt.query('''
        SELECT user_id AS id, name, user_lists.created_at AS joined_at FROM user_lists
          LEFT JOIN users ON user_id = id
        WHERE list_id = ?1
          AND user_lists.is_deleted = 0 AND coalesce(users.is_deleted, 0) = 0
      ''',
      [listId]).then((l) => l.map((m) => Member.fromMap(userId, m)).toList());

  Future<List<ToDo>> _getToDos(String listId) => _crdt.query('''
    SELECT
      todos.id,
      todos.name,
      todos.done,
      todos.done_at,
      users.name AS done_by,
      todos.position,
      todos.creator_id,
      todos.created_at
    FROM
      todos
    LEFT JOIN
      users ON done_by = users.id
    WHERE
      list_id = ?
      AND todos.is_deleted = 0
    ORDER BY
      position
  ''', [listId]).then((l) => l.map(ToDo.fromMap).toList());
}

class ToDoListWithItems extends ToDoList {
  final List<ToDo> items;

  ToDoListWithItems.fromList(ToDoList list, this.items)
      : super(list.id, list.name, list.color, list.creatorId, list.createdAt,
            list.position, list.itemCount, list.doneCount, list.members);

  ToDoListWithItems.fromMap(
      Map<String, dynamic> map, List<Member> members, this.items)
      : super.fromMap(map, members);
}

class ToDoList {
  final String id;
  final String name;
  final Color color;
  final String? creatorId;
  final DateTime? createdAt;
  final int position;
  final int itemCount;
  final int doneCount;
  final List<Member> members;

  int get shareCount => members.length;

  bool get isShared => shareCount > 1;

  bool get isEmpty => itemCount == 0;

  const ToDoList(this.id, this.name, this.color, this.creatorId, this.createdAt,
      this.position, this.itemCount, this.doneCount, this.members);

  ToDoList.fromMap(Map<String, dynamic> map, List<Member> members)
      : this(
          map['id'],
          map['name'],
          (map['color'] as String).asColor,
          map['creator_id'],
          (map['created_at'] as String?)?.asDateTime,
          map['position'],
          map['item_count'] ?? 0,
          map['done_count'] ?? 0,
          members,
        );

  String memberNames(BuildContext context) =>
      members.map((e) => e.nameOr(context)).join(' • ');

  @override
  String toString() => '$name [$doneCount/$itemCount]';
}

class ToDo {
  final String id;
  final String name;
  final bool done;
  final DateTime? doneAt;
  final String? doneBy;
  final int position;
  final String? creatorId;
  final DateTime? createdAt;

  ToDo(this.id, this.name, this.done, this.doneAt, this.doneBy, this.position,
      this.creatorId, this.createdAt);

  factory ToDo.fromMap(Map<String, dynamic> map) => ToDo(
        map['id'],
        map['name'],
        map['done'] == 1,
        (map['done_at'] as String?)?.asDateTime.toLocal(),
        map['done_by'],
        map['position'],
        map['creator_id'],
        (map['created_at'] as String?)?.asDateTime.toLocal(),
      );

  @override
  bool operator ==(Object other) =>
      other is ToDo &&
      other.id == id &&
      other.name == name &&
      other.done == done;

  @override
  int get hashCode => Object.hash(id, name, done);

  @override
  String toString() => '$name ${done ? '🗹' : '☐'}';
}

class Member extends User {
  final DateTime? joinedAt;

  Member.fromMap(String userId, Map<String, dynamic> map)
      : joinedAt = (map['joined_at'] as String?)?.asDateTime.toLocal(),
        super.fromMap(userId, map);
}
