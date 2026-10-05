import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:pedometer/pedometer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:geolocator/geolocator.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // 만보기 관련 변수
  late Stream<StepCount> _stepCountStream;
  late Stream<PedestrianStatus> _pedestrianStatusStream;
  String _pedometerStatus = '확인 중...';
  int _currentSteps = 0;
  int _baseSteps = 0;
  int _todaySavedSteps = 0;

  // 위치 로깅 관련 변수
  bool _isLoggingLocation = false;
  StreamSubscription<Position>? _positionStreamSubscription;
  List<Map<String, dynamic>> _routePoints = [];
  double _totalDistanceMeters = 0.0;
  DateTime? _loggingStartTime;
  int _elapsedSeconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _loadLocalSteps();
    _initPedometer();
  }

  @override
  void dispose() {
    _positionStreamSubscription?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  // --- [만보기 로직] ---
  Future<void> _loadLocalSteps() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _todaySavedSteps = prefs.getInt('today_steps') ?? 0;
    });
  }

  void _initPedometer() {
    _pedestrianStatusStream = Pedometer.pedestrianStatusStream;
    _pedestrianStatusStream.listen((event) {
      setState(() => _pedometerStatus = event.status);
    }).onError((error) => setState(() => _pedometerStatus = '센서 에러'));

    _stepCountStream = Pedometer.stepCountStream;
    _stepCountStream.listen((event) {
      setState(() {
        if (_baseSteps == 0) _baseSteps = event.steps;
        _currentSteps = event.steps - _baseSteps;
      });
    }).onError((error) => debugPrint("Pedometer Error: $error"));
  }

  Future<void> _saveStepsToServer() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final totalStepsToSave = _todaySavedSteps + _currentSteps;
    final todayKey = DateTime.now().toIso8601String().substring(0, 10);

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('pedometer')
          .doc(todayKey)
          .set({
        'date': todayKey,
        'steps': totalStepsToSave,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      setState(() {
        _todaySavedSteps = totalStepsToSave;
        _baseSteps = 0;
        _currentSteps = 0;
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('today_steps', _todaySavedSteps);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('걸음 수가 서버에 저장되었습니다!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('서버 저장 실패 (오프라인 상태): $e')),
        );
      }
    }
  }

  // --- [위치 로깅 로직 (3번)] ---
  Future<void> _startLocationLogging() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('위치 서비스를 켜주세요.')));
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('위치 권한이 거부되었습니다.')));
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('설정에서 위치 권한을 허용해주세요.')));
      return;
    }

    // 로깅 초기화
    setState(() {
      _isLoggingLocation = true;
      _routePoints.clear();
      _totalDistanceMeters = 0.0;
      _loggingStartTime = DateTime.now();
      _elapsedSeconds = 0;
    });

    // 타이머 시작 (경과 시간 측정)
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _elapsedSeconds++;
      });
    });

    // 위치 스트림 구독 (오프라인 우선: 로컬 리스트에 계속 누적)
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5, // 5미터 이상 이동 시 기록
    );

    _positionStreamSubscription = Geolocator.getPositionStream(locationSettings: locationSettings).listen((Position position) async {
      setState(() {
        final newPoint = {
          'latitude': position.latitude,
          'longitude': position.longitude,
          'timestamp': position.timestamp.toIso8601String(),
        };

        if (_routePoints.isNotEmpty) {
          final last = _routePoints.last;
          // 이전 좌표와의 거리 계산하여 총 거리 누적
          double distance = Geolocator.distanceBetween(
            last['latitude'],
            last['longitude'],
            position.latitude,
            position.longitude,
          );
          _totalDistanceMeters += distance;
        }

        _routePoints.add(newPoint);
      });

      // 오프라인 대비 로컬 SharedPreferences에 임시 저장
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('temp_route', jsonEncode(_routePoints));
      await prefs.setDouble('temp_distance', _totalDistanceMeters);
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('위치 로깅이 시작되었습니다.')));
    }
  }

  // 위치 로깅 종료 및 서버(Firestore) 저장
  Future<void> _stopAndSaveLocationLogging() async {
    if (!_isLoggingLocation) return;

    _positionStreamSubscription?.cancel();
    _timer?.cancel();

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final docId = DateTime.now().toIso8601String();
    final summaryData = {
      'startTime': _loggingStartTime?.toIso8601String(),
      'endTime': DateTime.now().toIso8601String(),
      'totalDistanceKm': double.parse((_totalDistanceMeters / 1000).toStringAsFixed(2)),
      'elapsedSeconds': _elapsedSeconds,
      'steps': _currentSteps, // 연동된 걸음 수
      'routePoints': _routePoints,
      'createdAt': FieldValue.serverTimestamp(),
    };

    try {
      // Firestore에 전체 정보 한 번에 저장 (오프라인이면 자동 큐잉됨)
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('location_logs')
          .doc(docId)
          .set(summaryData);

      setState(() {
        _isLoggingLocation = false;
      });

      // 임시 로컬 데이터 삭제
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('temp_route');
      await prefs.remove('temp_distance');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('위치 로깅 기록이 서버에 안전하게 저장되었습니다!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('서버 저장 실패 (오프라인 상태일 수 있습니다): $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalDisplaySteps = _todaySavedSteps + _currentSteps;
    final user = FirebaseAuth.instance.currentUser;
    final distanceKm = (_totalDistanceMeters / 1000).toStringAsFixed(2);
    final minutes = _elapsedSeconds ~/ 60;
    final seconds = _elapsedSeconds % 60;

    return Scaffold(
      appBar: AppBar(
        title: const Text('로드맵 홈'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) context.go('/login');
            },
          )
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            UserAccountsDrawerHeader(
              accountName: Text(user?.displayName ?? '사용자'),
              accountEmail: Text(user?.email ?? ''),
              currentAccountPicture: const CircleAvatar(child: Icon(Icons.person)),
            ),
            ListTile(
              leading: const Icon(Icons.directions_walk),
              title: const Text('만보기 상세 (주간 그래프)'),
              onTap: () {
                Navigator.pop(context);
                context.push('/pedometer-detail');
              },
            ),
            ListTile(
              leading: const Icon(Icons.map),
              title: const Text('위치 로깅 기록 리스트'),
              onTap: () {
                Navigator.pop(context);
                context.push('/location-list');
              },
            ),
          ],
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. 만보기 요약 카드
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('오늘의 만보기', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        Chip(
                          label: Text(_pedometerStatus, style: const TextStyle(color: Colors.white, fontSize: 12)),
                          backgroundColor: _pedometerStatus == 'walking' ? Colors.green : Colors.grey,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('$totalDisplaySteps 걸음', style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _saveStepsToServer,
                            child: const Text('만보기 서버 저장'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () => context.push('/pedometer-detail'),
                          child: const Text('주간 상세'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // 2. 위치 로깅 요약 및 시작/종료 카드 (3번 구현)
            Card(
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('위치 경로 로깅', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        Chip(
                          label: Text(_isLoggingLocation ? '로깅 중...' : '대기 중', style: const TextStyle(color: Colors.white, fontSize: 12)),
                          backgroundColor: _isLoggingLocation ? Colors.red : Colors.grey,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('이동 거리: $distanceKm km', style: const TextStyle(fontSize: 16)),
                    const SizedBox(height: 4),
                    Text('경과 시간: $minutes분 $seconds초', style: const TextStyle(fontSize: 16, color: Colors.grey)),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                            onPressed: _isLoggingLocation ? null : _startLocationLogging,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('로깅 시작'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                            onPressed: _isLoggingLocation ? _stopAndSaveLocationLogging : null,
                            icon: const Icon(Icons.stop),
                            label: const Text('종료 및 저장'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}