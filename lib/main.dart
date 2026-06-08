import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

void main() {
  runApp(const SeismicOneApp());
}

class SeismicOneApp extends StatelessWidget {
  const SeismicOneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SeismicOne',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.redAccent,
        scaffoldBackgroundColor: const Color(0xFF121212),
      ),
      home: const EarthquakeDashboard(),
    );
  }
}

class EarthquakeDashboard extends StatefulWidget {
  const EarthquakeDashboard({super.key});

  @override
  State<EarthquakeDashboard> createState() => _EarthquakeDashboardState();
}

class _EarthquakeDashboardState extends State<EarthquakeDashboard> {
  List _earthquakes = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    fetchEarthquakeData();
  }

  // Our live free API network connection layer
  Future<void> fetchEarthquakeData() async {
    final url = Uri.parse(
      'https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_day.geojson',
    );

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _earthquakes = data['features'];
          _isLoading = false;
        });
      }
    } catch (error) {
      print("Error fetching seismic data: $error");
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('⚠️ SEISMIC_ONE LIVE FEED'),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() => _isLoading = true);
              fetchEarthquakeData();
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.redAccent),
            )
          : ListView.builder(
              itemCount: _earthquakes.length,
              itemBuilder: (context, index) {
                final props = _earthquakes[index]['properties'];
                final double magnitude =
                    (props['mag'] as num?)?.toDouble() ?? 0.0;

                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  color: const Color(0xFF1E1E1E),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: magnitude >= 4.5
                          ? Colors.red
                          : Colors.orange,
                      child: Text(
                        magnitude.toStringAsFixed(1),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(
                      props['place'] ?? 'Unknown Location',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text('Status: ${props['status'] ?? 'Recorded'}'),
                  ),
                );
              },
            ),
    );
  }
}
