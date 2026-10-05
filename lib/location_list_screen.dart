import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';

class LocationListScreen extends StatelessWidget {
  const LocationListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('위치 로깅 리스트')),
        body: const Center(child: Text('로그인이 필요합니다.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('위치 로깅 기록 리스트'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        // Firestore에서 사용자의 location_logs 컬렉션을 생성일(createdAt) 기준 내림차순으로 가져옴
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('location_logs')
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(child: Text('에러가 발생했습니다: ${snapshot.error}'));
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
              child: Text(
                '저장된 위치 로깅 기록이 없습니다.\n홈에서 로깅을 시작해 보세요!',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            );
          }

          final docs = snapshot.data!.docs;

          return ListView.builder(
            padding: const EdgeInsets.all(16.0),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final data = docs[index].data() as Map<String, dynamic>;
              // 만약 docId 변수를 여기서 따로 쓰지 않는다면 선언을 생략하거나 아래와 같이 활용할 수 있습니다.
              // final docId = docs[index].id;

              // 데이터 파싱
              final double distanceKm = data['totalDistanceKm'] ?? 0.0;
              final int elapsedSeconds = data['elapsedSeconds'] ?? 0;
              final int steps = data['steps'] ?? 0;
              
              // 시간 포맷팅
              String formattedDate = '날짜 정보 없음';
              if (data['startTime'] != null) {
                try {
                  final startTime = DateTime.parse(data['startTime']);
                  formattedDate = DateFormat('yyyy년 MM월 dd일 HH:mm').format(startTime);
                } catch (_) {}
              }

              final minutes = elapsedSeconds ~/ 60;
              final seconds = elapsedSeconds % 60;

              return Card(
                elevation: 2,
                margin: const EdgeInsets.only(bottom: 12.0),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16.0),
                  leading: const CircleAvatar(
                    backgroundColor: Colors.blueAccent,
                    child: Icon(Icons.map, color: Colors.white),
                  ),
                  title: Text(
                    formattedDate,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('거리: $distanceKm km'),
                        Text('시간: ${minutes}분 ${seconds}초'),
                        Text('걸음: $steps보'),
                      ],
                    ),
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: () {
                    // 5번 기능인 위치 로깅 상세 화면으로 데이터(extra) 전달하며 이동
                    context.push('/location-detail', extra: data);
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}