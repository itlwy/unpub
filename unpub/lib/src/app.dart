import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:markdown/markdown.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:googleapis/oauth2/v2.dart';
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:archive/archive.dart';
import 'package:unpub/src/models.dart';
import 'package:unpub/unpub_api/lib/models.dart';
import 'package:unpub/src/meta_store.dart';
import 'package:unpub/src/package_store.dart';
import 'package:unpub/src/version_utils.dart';
import 'utils.dart';
import 'static/index.html.dart' as index_html;
import 'static/main.dart.js.dart' as main_dart_js;

part 'app.g.dart';

final RegExp _headingIdDeniedCharacters = RegExp(r'[^\w\s\u4e00-\u9fff-]');
final RegExp _headingIdWhitespace = RegExp(r'\s+');

String _headingId(String text) => text
    .toLowerCase()
    .trim()
    .replaceAll(_headingIdDeniedCharacters, '')
    .replaceAll(_headingIdWhitespace, '-');

class _HeaderWithIdSyntax extends HeaderSyntax {
  const _HeaderWithIdSyntax();

  @override
  Node parse(BlockParser parser) {
    var element = super.parse(parser) as Element;
    element.generatedId = _headingId(element.textContent);
    return element;
  }
}

class _SetextHeaderWithIdSyntax extends SetextHeaderSyntax {
  const _SetextHeaderWithIdSyntax();

  @override
  Node parse(BlockParser parser) {
    var element = super.parse(parser) as Element;
    element.generatedId = _headingId(element.textContent);
    return element;
  }
}

String _markdownToPackageHtml(String markdown) => markdownToHtml(
      markdown,
      blockSyntaxes: const [
        _HeaderWithIdSyntax(),
        _SetextHeaderWithIdSyntax(),
      ],
      extensionSet: ExtensionSet.gitHubFlavored,
    );

class App {
  static const proxyOriginHeader = "proxy-origin";

  /// meta information store
  final MetaStore metaStore;

  /// package(tarball) store
  final PackageStore packageStore;

  /// upstream url, default: https://pub.dev
  final String upstream;

  /// http(s) proxy to call googleapis (to get uploader email)
  final String? googleapisProxy;
  final String? overrideUploaderEmail;

  /// A forward proxy uri
  final Uri? proxy_origin;

  /// validate if the package can be published
  ///
  /// for more details, see: https://github.com/itlwy/unpub#package-validator
  final Future<void> Function(
    Map<String, dynamic> pubspec,
    String uploaderEmail,
  )? uploadValidator;

  App({
    required this.metaStore,
    required this.packageStore,
    this.upstream = 'https://pub.dev',
    this.googleapisProxy,
    this.overrideUploaderEmail,
    this.uploadValidator,
    this.proxy_origin,
  });

  static shelf.Response _okWithJson(Map<String, dynamic> data) =>
      shelf.Response.ok(
        json.encode(data),
        headers: {
          HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
          'Access-Control-Allow-Origin': '*',
        },
      );

  static shelf.Response _successMessage(String message) => _okWithJson({
        'success': {'message': message},
      });

  static shelf.Response _badRequest(
    String message, {
    int status = HttpStatus.badRequest,
  }) =>
      shelf.Response(
        status,
        headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
        body: json.encode({
          'error': {'message': message},
        }),
      );

  static shelf.Handler _errorHandler(shelf.Handler innerHandler) {
    return (shelf.Request request) async {
      try {
        return await innerHandler(request);
      } catch (error, stackTrace) {
        print('Unhandled error in ${request.method} ${request.requestedUri}:');
        print(error);
        print(stackTrace);
        return shelf.Response(
          HttpStatus.internalServerError,
          headers: {
            HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
            'Access-Control-Allow-Origin': '*',
          },
          body: json.encode({
            'error': {'message': 'Internal server error'},
          }),
        );
      }
    };
  }

  http.Client? _googleapisClient;

  String _resolveUrl(shelf.Request req, String reference) {
    if (proxy_origin != null) {
      return proxy_origin!.resolve(reference).toString();
    }
    String? proxyOriginInHeader = req.headers[proxyOriginHeader];
    if (proxyOriginInHeader != null) {
      return Uri.parse(proxyOriginInHeader).resolve(reference).toString();
    }
    return req.requestedUri.resolve(reference).toString();
  }

  Future<String> _getUploaderEmail(shelf.Request req) async {
    if (overrideUploaderEmail != null) return overrideUploaderEmail!;

    var authHeader = req.headers[HttpHeaders.authorizationHeader];
    if (authHeader == null) throw 'missing authorization header';

    var token = authHeader.split(' ').last;

    if (_googleapisClient == null) {
      if (googleapisProxy != null) {
        _googleapisClient = IOClient(
          HttpClient()
            ..findProxy = (url) => HttpClient.findProxyFromEnvironment(
                  url,
                  environment: {"https_proxy": googleapisProxy!},
                ),
        );
      } else {
        _googleapisClient = http.Client();
      }
    }

    var info = await Oauth2Api(
      _googleapisClient!,
    ).tokeninfo(accessToken: token);
    if (info.email == null) throw 'fail to get google account email';
    return info.email!;
  }

  Future<HttpServer> serve([String host = '0.0.0.0', int port = 4000]) async {
    var handler = const shelf.Pipeline()
        .addMiddleware(corsHeaders())
        .addMiddleware(shelf.logRequests())
        .addMiddleware(_errorHandler)
        .addHandler((req) async {
      // Return 404 by default
      // https://github.com/google/dart-neats/issues/1
      var res = await router.call(req);
      return res;
    });
    var server = await shelf_io.serve(handler, host, port);
    return server;
  }

  Map<String, dynamic> _versionToJson(UnpubVersion item, shelf.Request req) {
    var name = item.pubspec['name'] as String;
    var version = item.version;
    return {
      'archive_url': _resolveUrl(
        req,
        '/packages/$name/versions/$version.tar.gz',
      ),
      'pubspec': item.pubspec,
      'version': version,
    };
  }

  bool isPubClient(shelf.Request req) {
    var ua = req.headers[HttpHeaders.userAgentHeader];
    print(ua);
    return ua != null && ua.toLowerCase().contains('dart pub');
  }

  Router get router => _$AppRouter(this);

  @Route.get('/api/packages/<name>')
  Future<shelf.Response> getVersions(shelf.Request req, String name) async {
    var package = await metaStore.queryPackage(name);

    if (package == null) {
      return shelf.Response.found(
        Uri.parse(upstream).resolve('/api/packages/$name').toString(),
      );
    }

    sortVersionsByPriority(package.versions);

    var versionMaps =
        package.versions.map((item) => _versionToJson(item, req)).toList();
    var latest = _versionToJson(primaryVersion(package.versions), req);

    return _okWithJson({
      'name': name,
      'latest': latest,
      'versions': versionMaps,
    });
  }

  @Route.get('/api/packages/<name>/versions/<version>')
  Future<shelf.Response> getVersion(
    shelf.Request req,
    String name,
    String version,
  ) async {
    // Important: + -> %2B, should be decoded here
    try {
      version = Uri.decodeComponent(version);
    } catch (err) {
      print(err);
    }

    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.found(
        Uri.parse(
          upstream,
        ).resolve('/api/packages/$name/versions/$version').toString(),
      );
    }

    var packageVersion = package.versions.firstWhereOrNull(
      (item) => item.version == version,
    );
    if (packageVersion == null) {
      return shelf.Response.notFound('Not Found');
    }

    return _okWithJson(_versionToJson(packageVersion, req));
  }

  @Route.get('/packages/<name>/versions/<version>.tar.gz')
  Future<shelf.Response> download(
    shelf.Request req,
    String name,
    String version,
  ) async {
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.found(
        Uri.parse(
          upstream,
        ).resolve('/packages/$name/versions/$version.tar.gz').toString(),
      );
    }

    var packageVersion = package.versions.firstWhereOrNull(
      (item) => item.version == version,
    );
    if (packageVersion == null) {
      return shelf.Response.notFound('Not Found');
    }

    if (isPubClient(req)) {
      metaStore.increaseDownloads(name, version);
    }

    if (packageStore.supportsDownloadUrl) {
      return shelf.Response.found(
        await packageStore.downloadUrl(name, version),
      );
    } else {
      return shelf.Response.ok(
        packageStore.download(name, version),
        headers: {HttpHeaders.contentTypeHeader: ContentType.binary.mimeType},
      );
    }
  }

  @Route.get('/api/packages/versions/new')
  Future<shelf.Response> getUploadUrl(shelf.Request req) async {
    return _okWithJson({
      'url': _resolveUrl(req, '/api/packages/versions/newUpload').toString(),
      'fields': {},
    });
  }

  @Route.post('/api/packages/versions/newUpload')
  Future<shelf.Response> upload(shelf.Request req) async {
    try {
      // Skip Google OAuth2 authentication for private deployment
      // var uploader = await _getUploaderEmail(req);
      var uploader = "";

      var contentType = req.headers['content-type'];
      if (contentType == null) throw 'invalid content type';

      var mediaType = MediaType.parse(contentType);
      var boundary = mediaType.parameters['boundary'];
      if (boundary == null) throw 'invalid boundary';

      var transformer = MimeMultipartTransformer(boundary);
      MimeMultipart? fileData;

      // The map below makes the runtime type checker happy.
      // https://github.com/dart-lang/pub-dev/blob/19033f8154ca1f597ef5495acbc84a2bb368f16d/app/lib/fake/server/fake_storage_server.dart#L74
      final stream = req.read().map((a) => a).transform(transformer);
      await for (var part in stream) {
        if (fileData != null) continue;
        fileData = part;
      }

      var bb = await fileData!.fold(
        BytesBuilder(),
        (BytesBuilder byteBuilder, d) => byteBuilder..add(d),
      );
      var tarballBytes = bb.takeBytes();
      var tarBytes = GZipDecoder().decodeBytes(tarballBytes);
      var archive = TarDecoder().decodeBytes(tarBytes);
      ArchiveFile? pubspecArchiveFile;
      ArchiveFile? readmeFile;
      ArchiveFile? changelogFile;

      for (var file in archive.files) {
        if (file.name == 'pubspec.yaml') {
          pubspecArchiveFile = file;
          continue;
        }
        if (file.name.toLowerCase() == 'readme.md') {
          readmeFile = file;
          continue;
        }
        if (file.name.toLowerCase() == 'changelog.md') {
          changelogFile = file;
          continue;
        }
      }

      if (pubspecArchiveFile == null) {
        throw 'Did not find any pubspec.yaml file in upload. Aborting.';
      }

      var pubspecYaml = utf8.decode(pubspecArchiveFile.content);
      var pubspec = loadYamlAsMap(pubspecYaml)!;

      if (uploadValidator != null) {
        await uploadValidator!(pubspec, uploader);
      }

      // TODO: null
      var name = pubspec['name'] as String;
      var version = pubspec['version'] as String;

      var package = await metaStore.queryPackage(name);

      // Package already exists
      if (package != null) {
        if (package.private == false) {
          throw '$name is not a private package. Please upload it to https://pub.dev';
        }

        // Check uploaders
        if (package.uploaders?.contains(uploader) == false) {
          throw '$uploader is not an uploader of $name';
        }

        // Check duplicated version
        var duplicated = package.versions.firstWhereOrNull(
          (item) => version == item.version,
        );
        if (duplicated != null) {
          throw 'version invalid: $name@$version already exists.';
        }
      }

      // Upload package tarball to storage
      await packageStore.upload(name, version, tarballBytes);

      String? readme;
      String? changelog;
      if (readmeFile != null) {
        readme = utf8.decode(readmeFile.content);
      }
      if (changelogFile != null) {
        changelog = utf8.decode(changelogFile.content);
      }

      // Write package meta to database
      var unpubVersion = UnpubVersion(
        version,
        pubspec,
        pubspecYaml,
        uploader,
        readme,
        changelog,
        DateTime.now(),
      );
      await metaStore.addVersion(name, unpubVersion);

      // TODO: Upload docs
      return shelf.Response.found(
        _resolveUrl(req, '/api/packages/versions/newUploadFinish'),
      );
    } catch (err) {
      return shelf.Response.found(
        _resolveUrl(req, '/api/packages/versions/newUploadFinish?error=$err'),
      );
    }
  }

  @Route.get('/api/packages/versions/newUploadFinish')
  Future<shelf.Response> uploadFinish(shelf.Request req) async {
    var error = req.requestedUri.queryParameters['error'];
    if (error != null) {
      return _badRequest(error);
    }
    return _successMessage('Successfully uploaded package.');
  }

  @Route.delete('/api/packages/<name>/versions/prereleases')
  Future<shelf.Response> removePrereleases(
    shelf.Request req,
    String name,
  ) async {
    var params = req.requestedUri.queryParameters;
    var baseText = params['base'];
    var tag = params['tag'] ?? 'beta';
    var dryRun = params['dryRun'] == 'true';

    if (baseText == null || baseText.isEmpty) {
      return _badRequest('missing base version');
    }
    if (tag != 'beta') {
      return _badRequest('unsupported prerelease tag: $tag');
    }

    var base = tryParseVersion(baseText);
    if (base == null) {
      return _badRequest('invalid base version: $baseText');
    }
    if (base.isPreRelease || base.build.isNotEmpty) {
      return _badRequest('base version must be a stable version');
    }

    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return _badRequest('package not exists', status: HttpStatus.notFound);
    }

    var hasBase = package.versions.any(
      (version) => version.version == baseText,
    );
    if (!hasBase) {
      return _badRequest('base version does not exist: $baseText');
    }

    var matched = package.versions.where((version) {
      return matchesPrerelease(parseVersion(version.version), base, tag);
    }).toList();
    matched.sort(
      (a, b) => parseVersion(a.version).compareTo(parseVersion(b.version)),
    );

    var matchedVersions = matched.map((version) => version.version).toList();
    if (dryRun) {
      return _okWithJson({
        'success': true,
        'package': name,
        'base': baseText,
        'tag': tag,
        'removed': <String>[],
        'matched': matchedVersions,
        'storageFailures': <Map<String, String>>[],
      });
    }

    var removed = await metaStore.removeVersions(name, matchedVersions);
    var storageFailures = <Map<String, String>>[];
    for (var version in removed) {
      try {
        await packageStore.delete(name, version.version);
      } catch (err) {
        storageFailures.add({
          'version': version.version,
          'error': err.toString(),
        });
      }
    }

    return _okWithJson({
      'success': true,
      'package': name,
      'base': baseText,
      'tag': tag,
      'removed': removed.map((version) => version.version).toList(),
      'storageFailures': storageFailures,
    });
  }

  @Route.post('/api/packages/<name>/uploaders')
  Future<shelf.Response> addUploader(shelf.Request req, String name) async {
    var body = await req.readAsString();
    var email = Uri.splitQueryString(body)['email']!; // TODO: null
    // Skip Google OAuth2 authentication for private deployment
    // var operatorEmail = await _getUploaderEmail(req);
    // var package = await metaStore.queryPackage(name);
    //
    // if (package?.uploaders?.contains(operatorEmail) == false) {
    //   return _badRequest('no permission', status: HttpStatus.forbidden);
    // }
    // if (package?.uploaders?.contains(email) == true) {
    //   return _badRequest('email already exists');
    // }

    await metaStore.addUploader(name, email);
    return _successMessage('uploader added');
  }

  @Route.delete('/api/packages/<name>/uploaders/<email>')
  Future<shelf.Response> removeUploader(
    shelf.Request req,
    String name,
    String email,
  ) async {
    email = Uri.decodeComponent(email);
    // Skip Google OAuth2 authentication for private deployment
    // var operatorEmail = await _getUploaderEmail(req);
    // var package = await metaStore.queryPackage(name);
    //
    // // TODO: null
    // if (package?.uploaders?.contains(operatorEmail) == false) {
    //   return _badRequest('no permission', status: HttpStatus.forbidden);
    // }
    // if (package?.uploaders?.contains(email) == false) {
    //   return _badRequest('email not uploader');
    // }

    await metaStore.removeUploader(name, email);
    return _successMessage('uploader removed');
  }

  @Route.get('/webapi/packages')
  Future<shelf.Response> getPackages(shelf.Request req) async {
    var params = req.requestedUri.queryParameters;
    var size = int.tryParse(params['size'] ?? '') ?? 10;
    var page = int.tryParse(params['page'] ?? '') ?? 0;
    var sort = params['sort'] ?? 'download';
    var q = params['q'];

    String? keyword;
    String? uploader;
    String? dependency;

    if (q == null) {
    } else if (q.startsWith('email:')) {
      uploader = q.substring(6).trim();
    } else if (q.startsWith('dependency:')) {
      dependency = q.substring(11).trim();
    } else {
      keyword = q;
    }

    final result = await metaStore.queryPackages(
      size: size,
      page: page,
      sort: sort,
      keyword: keyword,
      uploader: uploader,
      dependency: dependency,
    );

    var data = ListApi(result.count, [
      for (var package in result.packages) _listApiPackage(package),
    ]);

    return _okWithJson({'data': data.toJson()});
  }

  @Route.get('/packages/<name>.json')
  Future<shelf.Response> getPackageVersions(
    shelf.Request req,
    String name,
  ) async {
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return _badRequest('package not exists', status: HttpStatus.notFound);
    }

    var versions = package.versions.map((v) => v.version).toList();
    versions.sort((a, b) {
      return compareVersionPriorityDescending(a, b);
    });

    return _okWithJson({'name': name, 'versions': versions});
  }

  @Route.get('/webapi/package/<name>/<version>')
  Future<shelf.Response> getPackageDetail(
    shelf.Request req,
    String name,
    String version,
  ) async {
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return _okWithJson({'error': 'package not exists'});
    }

    UnpubVersion? packageVersion;
    if (version == 'latest') {
      packageVersion = primaryVersion(package.versions);
    } else {
      packageVersion = package.versions.firstWhereOrNull(
        (item) => item.version == version,
      );
    }
    if (packageVersion == null) {
      return _okWithJson({'error': 'version not exists'});
    }

    var versions = package.versions
        .map((v) => DetailViewVersion(v.version, v.createdAt))
        .toList();
    versions.sort((a, b) {
      return compareVersionPriorityDescending(a.version, b.version);
    });

    var pubspec = packageVersion.pubspec;
    List<String?> authors;
    if (pubspec['author'] != null) {
      authors = RegExp(
        r'<(.*?)>',
      ).allMatches(pubspec['author']).map((match) => match.group(1)).toList();
    } else if (pubspec['authors'] != null) {
      authors = (pubspec['authors'] as List)
          .map((author) => RegExp(r'<(.*?)>').firstMatch(author)!.group(1))
          .toList();
    } else {
      authors = [];
    }

    var depMap = (pubspec['dependencies'] as Map? ?? {}).cast<String, String>();

    // Render markdown to HTML with GFM extensions and linkable headings.
    var readmeHtml = packageVersion.readme != null
        ? _markdownToPackageHtml(packageVersion.readme!)
        : null;
    var changelogHtml = packageVersion.changelog != null
        ? _markdownToPackageHtml(packageVersion.changelog!)
        : null;

    var data = WebapiDetailView(
      package.name,
      packageVersion.version,
      packageVersion.pubspec['description'] ?? '',
      packageVersion.pubspec['homepage'] ?? '',
      package.uploaders ?? [],
      packageVersion.createdAt,
      readmeHtml,
      changelogHtml,
      versions,
      authors,
      depMap.keys.toList(),
      getPackageTags(packageVersion.pubspec),
    );

    return _okWithJson({'data': data.toJson()});
  }

  @Route.get('/healthz')
  Future<shelf.Response> healthz(shelf.Request req) async {
    var healthy = await metaStore.healthCheck();
    if (healthy) {
      return shelf.Response.ok('ok');
    } else {
      return shelf.Response.internalServerError(body: 'unhealthy');
    }
  }

  @Route.get('/')
  @Route.get('/packages')
  @Route.get('/packages/<name>')
  @Route.get('/packages/<name>/versions/<version>')
  Future<shelf.Response> indexHtml(shelf.Request req) async {
    return shelf.Response.ok(
      index_html.content,
      headers: {HttpHeaders.contentTypeHeader: ContentType.html.mimeType},
    );
  }

  @Route.get('/main.dart.js')
  Future<shelf.Response> mainDartJs(shelf.Request req) async {
    return shelf.Response.ok(
      main_dart_js.content,
      headers: {HttpHeaders.contentTypeHeader: 'text/javascript'},
    );
  }

  String _getBadgeUrl(
    String label,
    String message,
    String color,
    Map<String, String> queryParameters,
  ) {
    var badgeUri = Uri.parse('https://img.shields.io/static/v1');
    return Uri(
      scheme: badgeUri.scheme,
      host: badgeUri.host,
      path: badgeUri.path,
      queryParameters: {
        'label': label,
        'message': message,
        'color': color,
        ...queryParameters,
      },
    ).toString();
  }

  @Route.get('/badge/<type>/<name>')
  Future<shelf.Response> badge(
    shelf.Request req,
    String type,
    String name,
  ) async {
    var queryParameters = req.requestedUri.queryParameters;
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.notFound('Not found');
    }

    switch (type) {
      case 'v':
        var latest = parseVersion(primaryVersion(package.versions).version);

        var color = latest.major == 0 ? 'orange' : 'blue';

        return shelf.Response.found(
          _getBadgeUrl('unpub', latest.toString(), color, queryParameters),
        );
      case 'd':
        return shelf.Response.found(
          _getBadgeUrl(
            'downloads',
            package.download.toString(),
            'blue',
            queryParameters,
          ),
        );
      default:
        return shelf.Response.notFound('Not found');
    }
  }

  ListApiPackage _listApiPackage(UnpubPackage package) {
    var latest = primaryVersion(package.versions);
    return ListApiPackage(
      package.name,
      latest.pubspec['description'] as String?,
      getPackageTags(latest.pubspec),
      latest.version,
      package.updatedAt,
    );
  }
}
