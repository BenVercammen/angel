import 'dart:async';
import 'package:angel_framework/angel_framework.dart';
import 'package:intl/intl.dart';
import 'package:pool/pool.dart';

final DateFormat _fmt = new DateFormat('EEE, d MMM yyyy HH:mm:ss');

/// Formats a date (converted to UTC), ex: `Sun, 03 May 2015 23:02:37 GMT`.
String _formatDateForHttp(DateTime dt) => _fmt.format(dt.toUtc()) + ' GMT';

/// A flexible response cache for Angel.
///
/// Use this to improve real and perceived response of Web applications,
/// as well as to memoize expensive responses.
class ResponseCache {
  /// A set of [Patterns] for which responses will be cached.
  ///
  /// For example, you can pass a `Glob` matching `**/*.png` files to catch all PNG images.
  final List<Pattern> patterns = [];

  /// An optional timeout, after which a given response will be removed from the cache, and the contents refreshed.
  final Duration timeout;

  final Map<String, _CachedResponse> _cache = {};
  final Map<String, Pool> _writeLocks = {};

  ResponseCache({this.timeout});

  /// Closes all internal write-locks, and closes the cache.
  Future close() async {
    _writeLocks.forEach((_, p) => p.close());
  }

  /// Removes an entry from the response cache.
  void invalidate(String path) => _cache.remove(path);

  /// A middleware that handles requests with an `If-Modified-Since` header.
  ///
  /// This prevents the server from even having to access the cache, and plays very well with static assets.
  Future<bool> ifModifiedSince(RequestContext req, ResponseContext res) async {
    if (req.headers.value('if-modified-since') != null) {
      var modifiedSince = _fmt
          .parse(req.headers.value('if-modified-since').replaceAll('GMT', ''));

      // Check if there is a cache entry.
      for (var pattern in patterns) {
        if (pattern.allMatches(req.uri.path).isNotEmpty &&
            _cache.containsKey(req.uri.path)) {
          var response = _cache[req.uri.path];

          if (response.timestamp.compareTo(modifiedSince) <= 0) {
            res.statusCode = 304;
            return false;
          }
        }
      }
    }

    return true;
  }

  /// Serves content from the cache, if applicable.
  Future<bool> handleRequest(RequestContext req, ResponseContext res) async {
    if (res.statusCode == 304) return true;

    // Check if there is a cache entry.
    for (var pattern in patterns) {
      if (pattern.allMatches(req.uri.path).isNotEmpty) {
        var now = new DateTime.now().toUtc();

        if (_cache.containsKey(req.uri.path)) {
          // If the cache timeout has been met, don't send the cached response.
          var response = _cache[req.uri.path];
          if (now.difference(response.timestamp) >= timeout) return true;
          _setCachedHeaders(response.timestamp, req, res);
          res
            ..headers.addAll(response.headers)
            ..buffer.add(response.body)
            ..end();
          return false;
        }
      }
    }

    return true;
  }

  /// A response finalizer that saves responses to the cache.
  Future<bool> responseFinalizer(
      RequestContext req, ResponseContext res) async {
    if (res.statusCode == 304) return true;

    // Check if there is a cache entry.
    for (var pattern in patterns) {
      if (pattern.allMatches(req.uri.path).isNotEmpty) {
        var now = new DateTime.now().toUtc();

        // Invalidate the response, if need be.
        if (_cache.containsKey(req.uri.path)) {
          // If there is no timeout, don't invalidate.
          if (timeout == null) return true;

          // Otherwise, don't invalidate unless the timeout has been exceeded.
          var response = _cache[req.uri.path];
          if (now.difference(response.timestamp) < timeout) return true;

          // If the cache entry should be invalidated, then invalidate it.
          invalidate(req.uri.path);
        }

        // Save the response.
        _cache[req.uri.path] = new _CachedResponse(
            new Map.from(res.headers), res.buffer.toBytes(), now);
        _setCachedHeaders(now, req, res);
      }
    }

    return true;
  }

  void _setCachedHeaders(
      DateTime modified, RequestContext req, ResponseContext res) {
    var privacy = 'public';

    res.headers
      ..['cache-control'] = '$privacy, max-age=${timeout?.inSeconds ?? 0}'
      ..['last-modified'] = _formatDateForHttp(modified);

    if (timeout != null) {
      var expiry = new DateTime.now().add(timeout);
      res.headers['expires'] = _formatDateForHttp(expiry);
    }
  }
}

class _CachedResponse {
  final Map<String, String> headers;
  final List<int> body;
  final DateTime timestamp;

  _CachedResponse(this.headers, this.body, this.timestamp);
}
