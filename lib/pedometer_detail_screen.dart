import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

class PedometerDetailScreen extends StatefulWidget {
  const PedometerDetailScreen({super.key});

  @override
  State<PedometerDetailScreen> createState() => _PedometerDetailScreenState();
}

class _PedometerDetailScreenState extends State<PedometerDetailScreen> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _weeklyData = [];
  int _totalWeeklySteps = 0;

  @override
  void initState() {
    super.initState();
    _fetchWeeklyData();
  }

  // 최근 7일간의 데이터를 Firestore에서 불러오기
  Future<void> _fetchWeeklyData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final now = DateTime.now();
      List<Map<String, dynamic>> tempData = [];
      int totalSteps = 0;

      // 최근 7일 날짜 리스트 생성 (오늘부터 과거 6일)
      for (int i = 6; i >= 0; i--) {
        final date = now.subtract(Duration(days: i));
        final dateKey = DateFormat('yyyy-MM-dd').format(date);
        final dayOfWeek = DateFormat('E', 'ko_KR').format(date); // 월, 화, 수...

        tempData.add({
          'dateKey': dateKey,
          'dayOfWeek': dayOfWeek,
          'steps': 0,
        });
      }

      // Firestore에서 최근 데이터 쿼리
      final querySnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('pedometer')
          .orderBy('date', descending: true)
          .limit(7)
          .get();

      // 가져온 데이터 매핑
      final Map<String, int> firestoreMap = {};
      for (var doc in querySnapshot.docs) {
        final data = doc.data();
        final String date = data['date'] ?? '';
        final int steps = data['steps'] ?? 0;
        firestoreMap[date] = steps;
      }

      // 7일 리스트에 합산 반영
      for (var item in tempData) {
        final dateKey = item['dateKey'];
        if (firestoreMap.containsKey(dateKey)) {
          item['steps'] = firestoreMap[dateKey]!;
        }
        totalSteps += (item['steps'] as int);
      }

      setState(() {
        _weeklyData = tempData;
        _totalWeeklySteps = totalSteps;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint("Weekly Data Error: $e");
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final avgSteps = _weeklyData.isNotEmpty ? (_totalWeeklySteps / _weeklyData.length).round() : 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('만보기 주간 상세'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. 요약 카드
                  Card(
                    elevation: 3,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          Column(
                            children: [
                              const Text('최근 7일 총 걸음 수', style: TextStyle(color: Colors.grey, fontSize: 13)),
                              const SizedBox(height: 4),
                              Text('$_totalWeeklySteps 걸음', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          Container(height: 30, width: 1, color: Colors.grey.shade300),
                          Column(
                            children: [
                              const Text('일일 평균 걸음 수', style: TextStyle(color: Colors.grey, fontSize: 13)),
                              const SizedBox(height: 4),
                              Text('$avgSteps 걸음', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 2. 바 차트 영역
                  const Text('최근 일주일 걸음 수 추이', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Card(
                      elevation: 3,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
                        child: BarChart(
                          BarChartData(
                            alignment: BarChartAlignment.spaceAround,
                            maxY: _getMaxY(),
                            barTouchData: BarTouchData(enabled: true),
                            titlesData: FlTitlesData(
                              show: true,
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  getTitlesWidget: (double value, TitleMeta meta) {
                                    int index = value.toInt();
                                    if (index >= 0 && index < _weeklyData.length) {
                                      return Padding(
                                        padding: const EdgeInsets.only(top: 8.0),
                                        child: Text(
                                          _weeklyData[index]['dayOfWeek'],
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                        ),
                                      );
                                    }
                                    return const Text('');
                                  },
                                ),
                              ),
                              leftTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false), // 왼쪽 숫자 생략 깔끔하게
                              ),
                              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                            ),
                            gridData: const FlGridData(show: false),
                            borderData: FlBorderData(show: false),
                            barGroups: _weeklyData.asMap().entries.map((entry) {
                              int index = entry.key;
                              double steps = (entry.value['steps'] as int).toDouble();
                              return BarChartGroupData(
                                x: index,
                                barRods: [
                                  BarChartRodData(
                                    toY: steps,
                                    color: Colors.blueAccent,
                                    width: 16,
                                    borderRadius: BorderRadius.circular(6),
                                    backDrawRodData: BackgroundBarChartRodData(
                                      show: true,
                                      toY: _getMaxY(),
                                      color: Colors.grey.shade100,
                                    ),
                                  ),
                                ],
                              );
                            }).toList(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  // 차트의 최대 Y값 설정 (데이터가 없거나 작을 때 기본값 확보)
  double _getMaxY() {
    double max = 10000; // 기본 1만 걸음 기준
    for (var item in _weeklyData) {
      double steps = (item['steps'] as int).toDouble();
      if (steps > max) {
        max = steps * 1.2; // 여유 공간 20%
      }
    }
    return max;
  }
}