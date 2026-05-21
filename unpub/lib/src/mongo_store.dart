import 'package:mongo_dart/mongo_dart.dart';
import 'package:intl/intl.dart';
import 'package:unpub/src/models.dart';
import 'meta_store.dart';

final packageCollection = 'packages';
final statsCollection = 'stats';

class MongoStore extends MetaStore {
  Db db;

  MongoStore(this.db);

  Future<void> _ensureConnection() async {
    try {
      await db
          .collection(packageCollection)
          .findOne(where.limit(1));
    } catch (_) {
      try {
        await db.close();
      } catch (_) {}
      await db.open();
    }
  }

  @override
  Future<bool> healthCheck() async {
    try {
      await db
          .collection(packageCollection)
          .findOne(where.limit(1));
      return true;
    } catch (_) {
      return false;
    }
  }

  static SelectorBuilder _selectByName(String? name) => where.eq('name', name);

  Future<UnpubQueryResult> _queryPackagesBySelector(
      SelectorBuilder selector) async {
    final count = await db.collection(packageCollection).count(selector);
    final packages = await db
        .collection(packageCollection)
        .find(selector)
        .map((item) => UnpubPackage.fromJson(item))
        .toList();
    return UnpubQueryResult(count, packages);
  }

  @override
  queryPackage(name) async {
    await _ensureConnection();
    var json =
        await db.collection(packageCollection).findOne(_selectByName(name));
    if (json == null) return null;
    return UnpubPackage.fromJson(json);
  }

  @override
  addVersion(name, version) async {
    await _ensureConnection();
    await db.collection(packageCollection).update(
        _selectByName(name),
        modify
            .push('versions', version.toJson())
            .addToSet('uploaders', version.uploader)
            .setOnInsert('createdAt', version.createdAt)
            .setOnInsert('private', true)
            .setOnInsert('download', 0)
            .set('updatedAt', version.createdAt),
        upsert: true);
  }

  @override
  addUploader(name, email) async {
    await _ensureConnection();
    await db
        .collection(packageCollection)
        .update(_selectByName(name), modify.push('uploaders', email));
  }

  @override
  removeUploader(name, email) async {
    await _ensureConnection();
    await db
        .collection(packageCollection)
        .update(_selectByName(name), modify.pull('uploaders', email));
  }

  @override
  increaseDownloads(name, version) {
    var today = DateFormat('yyyyMMdd').format(DateTime.now());
    _ensureConnection().then((_) async {
      try {
        await db
            .collection(packageCollection)
            .update(_selectByName(name), modify.inc('download', 1));
      } catch (e) {
        print('Warning: failed to increment download count for $name: $e');
      }
      try {
        await db
            .collection(statsCollection)
            .update(_selectByName(name), modify.inc('d$today', 1));
      } catch (e) {
        print('Warning: failed to increment stats for $name: $e');
      }
    }).catchError((e) {
      print('Warning: cannot increment downloads for $name, DB unreachable: $e');
    });
  }

  @override
  Future<UnpubQueryResult> queryPackages({
    required size,
    required page,
    required sort,
    keyword,
    uploader,
    dependency,
  }) async {
    await _ensureConnection();
    var selector =
        where.sortBy(sort, descending: true).limit(size).skip(page * size);

    if (keyword != null) {
      selector = selector.match('name', '.*$keyword.*');
    }
    if (uploader != null) {
      selector = selector.eq('uploaders', uploader);
    }
    if (dependency != null) {
      selector = selector.raw({
        'versions': {
          r'$elemMatch': {
            'pubspec.dependencies.$dependency': {r'$exists': true}
          }
        }
      });
    }

    return _queryPackagesBySelector(selector);
  }
}
