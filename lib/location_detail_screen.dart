import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

class LocationDetailScreen extends StatefulWidget {
  final Map<String, dynamic> logData; // 리스트에서 전달받은 로깅 데이터

  const LocationDetailScreen({super.key, required this.logData});

  @override
  State<LocationDetailScreen> createState() => _LocationDetailScreenState();
}

class _LocationDetailScreenState extends State<LocationDetailScreen> {
  final Set<Polyline> _polylines = {};
  final Set<Marker> _markers = {};
  final List<LatLng> _routeCoordinates = [];
  GoogleMapController? _mapController;
  LatLng _initialCameraPosition = const LatLng(37.5665, 126.9780); // 기본 서울 시청 위치

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  void _fitRouteToMap() {
    if (_routeCoordinates.isEmpty || _mapController == null) return;
    if (_routeCoordinates.length == 1) {
      _mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(_routeCoordinates.first, 17),
      );
      return;
    }

    var minLat = _routeCoordinates.first.latitude;
    var maxLat = minLat;
    var minLng = _routeCoordinates.first.longitude;
    var maxLng = minLng;
    for (final point in _routeCoordinates.skip(1)) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    // 동일 지점에 가까운 짧은 경로에서도 bounds가 0이 되지 않도록 합니다.
    if ((maxLat - minLat).abs() < 0.0001) {
      minLat -= 0.0001;
      maxLat += 0.0001;
    }
    if ((maxLng - minLng).abs() < 0.0001) {
      minLng -= 0.0001;
      maxLng += 0.0001;
    }

    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat, minLng),
          northeast: LatLng(maxLat, maxLng),
        ),
        48,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _parseRouteData();
  }

  void _parseRouteData() {
    final rawPoints = widget.logData['routePoints'];
    if (rawPoints is! List) return;

    final latLngList = <LatLng>[];
    for (final rawPoint in rawPoints) {
      if (rawPoint is! Map) continue;
      final latValue = rawPoint['latitude'];
      final lngValue = rawPoint['longitude'];
      if (latValue is! num || lngValue is! num) continue;
      final lat = latValue.toDouble();
      final lng = lngValue.toDouble();
      if (lat < -90 || lat > 90 || lng < -180 || lng > 180) continue;
      final point = LatLng(lat, lng);
      // 같은 좌표가 연속해서 저장된 경우만 제거합니다. 원래 경로의 굴곡은 유지합니다.
      if (latLngList.isEmpty ||
          latLngList.last.latitude != point.latitude ||
          latLngList.last.longitude != point.longitude) {
        latLngList.add(point);
      }
    }

    if (latLngList.isEmpty) return;
    _routeCoordinates.addAll(latLngList);
    _initialCameraPosition = latLngList.first;

    _markers.add(Marker(
      markerId: const MarkerId('start'),
      position: latLngList.first,
      infoWindow: const InfoWindow(title: '출발지'),
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
    ));

    if (latLngList.length > 1) {
      _markers.add(Marker(
        markerId: const MarkerId('end'),
        position: latLngList.last,
        infoWindow: const InfoWindow(title: '도착지'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ));
      _polylines.add(Polyline(
        polylineId: const PolylineId('route_path'),
        points: latLngList,
        color: Colors.blueAccent,
        width: 5,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.logData;
    final double distanceKm = data['totalDistanceKm'] ?? 0.0;
    final int elapsedSeconds = data['elapsedSeconds'] ?? 0;
    final int steps = data['steps'] ?? 0;

    String formattedDate = '날짜 정보 없음';
    if (data['startTime'] != null) {
      try {
        final startTime = DateTime.parse(data['startTime']);
        formattedDate = DateFormat('yyyy년 MM월 dd일 HH:mm').format(startTime);
      } catch (_) {}
    }

    final minutes = elapsedSeconds ~/ 60;
    final seconds = elapsedSeconds % 60;

    return Scaffold(
      appBar: AppBar(
        title: Text(formattedDate),
      ),
      body: Column(
        children: [
          // 1. 상단 요약 통계 카드
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Card(
              elevation: 3,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildStatItem('이동 거리', '$distanceKm km', Icons.map),
                    _buildStatItem('소요 시간', '$minutes분 $seconds초', Icons.timer),
                    _buildStatItem('걸음 수', '$steps 보', Icons.directions_walk),
                  ],
                ),
              ),
            ),
          ),

          // 2. 하단 지도 영역 (이동 경로 시각화)
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: GoogleMap(
                mapType: MapType.normal,
                initialCameraPosition: CameraPosition(
                  target: _initialCameraPosition,
                  zoom: 15.0,
                ),
                onMapCreated: (controller) {
                  _mapController = controller;
                  // 지도가 생성된 다음 경로 전체가 화면에 들어오도록 확대/축소합니다.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _fitRouteToMap();
                  });
                },
                polylines: _polylines,
                markers: _markers,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: true,
                compassEnabled: true,
                // 사용하지 않는 controller 콜백을 제거했습니다.
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon) {
    return Column(
      children: [
        Icon(icon, color: Colors.blueAccent, size: 24),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      ],
    );
  }
}
