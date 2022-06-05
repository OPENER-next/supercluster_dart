import 'dart:math';

import 'package:kdbush/kdbush.dart';
import 'package:supercluster/src/cluster_or_map_point.dart';
import 'package:supercluster/src/map_point.dart';

import 'cluster.dart';

class Supercluster<T> {
  final double? Function(T) getX;
  final double? Function(T) getY;

  final int minZoom;
  final int maxZoom;
  final int minPoints;
  final int radius;
  final int extent;
  final int nodeSize;

  //final bool generateId;
  //final int Function(int accumulated, dynamic props)? reduce;
  final List<KDBush<ClusterOrMapPoint, double>?> trees;
  List<T>? points;

  Supercluster({
    required this.getX,
    required this.getY,
    int? minZoom,
    int? maxZoom,
    int? minPoints,
    int? radius,
    int? extent,
    int? nodeSize,
  })  : minZoom = minZoom ?? 0,
        maxZoom = maxZoom ?? 16,
        minPoints = minPoints ?? 2,
        radius = radius ?? 40,
        extent = extent ?? 512,
        nodeSize = nodeSize ?? 64,
        trees = List.filled((maxZoom ?? 16) + 2, null);

  void load(List<T> points) {
    this.points = points;

    // generate a cluster object for each point and index input points into a KD-tree
    var clusters = <ClusterOrMapPoint>[];
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final x = getX(point);
      final y = getY(point);
      if (x == null || y == null) continue;
      clusters.add(
        ClusterOrMapPoint.mapPoint(
          createPointCluster(x, y, i),
        ),
      );
    }

    trees[maxZoom + 1] = KDBush<ClusterOrMapPoint, double>(
      points: clusters,
      getX: ClusterOrMapPoint.getX,
      getY: ClusterOrMapPoint.getY,
      nodeSize: nodeSize,
    );

    // cluster points on max zoom, then cluster the results on previous zoom, etc.;
    // results in a cluster hierarchy across zoom levels
    for (var z = maxZoom; z >= minZoom; z--) {
      // create a new set of clusters for the zoom and index them with a KD-tree
      clusters = _cluster(clusters, z);
      trees[z] = KDBush<ClusterOrMapPoint, double>(
        points: clusters,
        getX: ClusterOrMapPoint.getX,
        getY: ClusterOrMapPoint.getY,
        nodeSize: nodeSize,
      );
    }
  }

  List<ClusterOrMapPoint> getClustersAndPoints(
    double westLng,
    double southLat,
    double eastLng,
    double northLat,
    int zoom,
  ) {
    var minLng = ((westLng + 180) % 360 + 360) % 360 - 180;
    final minLat = max(-90.0, min(90.0, southLat));
    var maxLng =
        eastLng == 180 ? 180.0 : ((eastLng + 180) % 360 + 360) % 360 - 180;
    final maxLat = max(-90.0, min(90.0, northLat));

    if (eastLng - westLng >= 360) {
      minLng = -180.0;
      maxLng = 180.0;
    } else if (minLng > maxLng) {
      final easternHem =
          getClustersAndPoints(minLng, minLat, 180, maxLat, zoom);
      final westernHem =
          getClustersAndPoints(-180, minLat, maxLng, maxLat, zoom);
      return easternHem..addAll(westernHem);
    }

    final tree = trees[_limitZoom(zoom)]!;
    final ids = tree.withinBounds(
        lngX(minLng), latY(maxLat), lngX(maxLng), latY(minLat));
    final clusters = <ClusterOrMapPoint>[];
    for (final id in ids) {
      clusters.add(tree.points[id]);
    }
    return clusters;
  }

  List<ClusterOrMapPoint> getChildren(clusterId) {
    final originId = _getOriginId(clusterId);
    final originZoom = _getOriginZoom(clusterId);
    final errorMsg = 'No cluster with the specified id.';

    final index = trees[originZoom];
    if (index == null) throw errorMsg;

    if (originId >= index.points.length) throw errorMsg;
    final origin = index.points[originId];

    final r = radius / (extent * pow(2, originZoom - 1));
    final ids = index.withinRadius(origin.x, origin.y, r);
    final children = <ClusterOrMapPoint>[];
    for (final id in ids) {
      final c = index.points[id];
      if (c.parentId == clusterId) {
        children.add(c);
      }
    }

    if (children.isEmpty) throw errorMsg;

    return children;
  }

  List<MapPoint> getLeaves(int clusterId, {int limit = 10, int offset = 0}) {
    final leaves = <MapPoint>[];
    _appendLeaves(leaves, clusterId, limit, offset, 0);

    return leaves;
  }

  int getClusterExpansionZoom(int clusterId) {
    var expansionZoom = _getOriginZoom(clusterId) - 1;
    while (expansionZoom <= maxZoom) {
      final children = getChildren(clusterId);
      expansionZoom++;
      if (children.length != 1) break;
      clusterId = children[0].cluster!.id;
    }
    return expansionZoom;
  }

  int _appendLeaves(List<MapPoint> result, int clusterId, int limit, int offset,
      int skipped) {
    final children = getChildren(clusterId);

    for (final child in children) {
      final cluster = child.cluster;
      final mapPoint = child.mapPoint;

      if (cluster != null) {
        if (skipped + cluster.numPoints <= offset) {
          // skip the whole cluster
          skipped += cluster.numPoints;
        } else {
          // enter the cluster
          skipped = _appendLeaves(result, cluster.id, limit, offset, skipped);
          // exit the cluster
        }
      } else if (skipped < offset) {
        // skip a single point
        skipped++;
      } else {
        // add a single point
        result.add(mapPoint!);
      }
      if (result.length == limit) break;
    }

    return skipped;
  }

  int _limitZoom(num z) {
    return max(minZoom, min(z.floor(), maxZoom + 1));
  }

  List<ClusterOrMapPoint> _cluster(List<ClusterOrMapPoint> points, int zoom) {
    final clusters = <ClusterOrMapPoint>[];
    final r = radius / (extent * pow(2, zoom));

    // loop through each point
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      // if we've already visited the point at this zoom level, skip it
      if (p.zoom <= zoom) continue;
      p.zoom = zoom;

      // find all nearby points
      final tree = trees[zoom + 1]!;
      final neighborIds = tree.withinRadius(p.x, p.y, r);

      final numPointsOrigin = p.cluster?.numPoints ?? 1;
      var numPoints = numPointsOrigin;

      // count the number of points in a potential cluster
      for (final neighborId in neighborIds) {
        final b = tree.points[neighborId];
        // filter out neighbors that are already processed
        if (b.zoom > zoom) numPoints += b.cluster?.numPoints ?? 1;
      }

      // if there were neighbors to merge, and there are enough points to form a cluster
      if (numPoints > numPointsOrigin && numPoints >= minPoints) {
        var wx = p.x * numPointsOrigin;
        var wy = p.y * numPointsOrigin;

        // encode both zoom and point index on which the cluster originated -- offset by total length of features
        final id = (i << 5) + (zoom + 1) + this.points!.length;

        for (final neighborId in neighborIds) {
          final b = tree.points[neighborId];

          if (b.zoom <= zoom) continue;
          b.zoom = zoom; // save the zoom (so it doesn't get processed twice)

          final numPoints2 = b.cluster?.numPoints ?? 1;
          wx += b.x *
              numPoints2; // accumulate coordinates for calculating weighted center
          wy += b.y * numPoints2;

          b.parentId = id;
        }

        p.parentId = id;
        clusters.add(
          ClusterOrMapPoint.cluster(
            createCluster(wx / numPoints, wy / numPoints, id, numPoints),
          ),
        );
      } else {
        // left points as unclustered
        clusters.add(p);

        if (numPoints > 1) {
          for (final neighborId in neighborIds) {
            final b = tree.points[neighborId];
            if (b.zoom <= zoom) continue;
            b.zoom = zoom;
            clusters.add(b);
          }
        }
      }
    }

    return clusters;
  }

  // get index of the point from which the cluster originated
  _getOriginId(clusterId) {
    return (clusterId - points!.length) >> 5;
  }

  // get zoom of the point from which the cluster originated
  _getOriginZoom(clusterId) {
    return (clusterId - points!.length) % 32;
  }

  /// ////////////////

}

// longitude/latitude to spherical mercator in [0..1] range
double lngX(lng) {
  return lng / 360 + 0.5;
}

double latY(lat) {
  final latSin = sin(lat * pi / 180);
  final y = (0.5 - 0.25 * log((1 + latSin) / (1 - latSin)) / pi);
  return y < 0
      ? 0
      : y > 1
          ? 1
          : y;
}

// spherical mercator to longitude/latitude
double xLng(x) {
  return (x - 0.5) * 360;
}

double yLat(y) {
  final y2 = (180 - y * 360) * pi / 180;
  return 360 * atan(exp(y2)) / pi - 90;
}

Cluster createCluster(x, y, id, numPoints) {
  return Cluster(
    x: x,
    y: y,
    id: id,
    numPoints: numPoints,
  );
}

MapPoint createPointCluster(double x, double y, int id) {
  return MapPoint(
    x: lngX(x),
    y: latY(y),
    index: id,
  );
}