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
  LatLng _initialCameraPosition = const LatLng(37.5665, 126.9780); // 기본 서울 시청 위치

  @override
  void initState() {
    super.initState();
    _parseRouteData();
  }

  void _parseRouteData() {
    final rawPoints = widget.logData['routePoints'] as List<dynamic>?;
    if (rawPoints == null || rawPoints.isEmpty) return;

    List<LatLng> latLngList = [];
    for (var point in rawPoints) {
      final lat = point['latitude'] as double;
      final lng = point['longitude'] as double;
      latLngList.add(LatLng(lat, lng));
    }

    if (latLngList.isNotEmpty) {
      _initialCameraPosition = latLngList.first;

      // 시작점과 종료점 마커 추가
      _markers.add(
        Marker(
          markerId: const MarkerId('start'),
          position: latLngList.first,
          infoWindow: const InfoWindow(title: '출발지'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        ),
      );

      if (latLngList.length > 1) {
        _markers.add(
          Marker(
            markerId: const MarkerId('end'),
            position: latLngList.last,
            infoWindow: const InfoWindow(title: '도착지'),
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          ),
        );
      }

      // 경로 폴리라인 추가
      _polylines.add(
        Polyline(
          polylineId: const PolylineId('route_path'),
          points: latLngList,
          color: Colors.blueAccent,
          width: 5,
        ),
      );
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
                    _buildStatItem('소요 시간', '${minutes}분 ${seconds}초', Icons.timer),
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
                initialCameraPosition: CameraPosition(
                  target: _initialCameraPosition,
                  zoom: 15.0,
                ),
                polylines: _polylines,
                markers: _markers,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: true,
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