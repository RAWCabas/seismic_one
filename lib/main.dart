import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';

void main() {
  runApp(const SeismicOneApp());
}

class SeismicOneApp extends StatelessWidget {
  const SeismicOneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SeismicOne',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.redAccent,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Colors.redAccent,
          secondary: Colors.orangeAccent,
        ),
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
  final MapController _mapController = MapController();

  DateTime _startDate = DateTime.now().subtract(const Duration(days: 1));
  DateTime _endDate = DateTime.now();

  String _currentSortRule = 'Newest First';
  bool _showSidebar = true;
  bool _showMap = true;

  @override
  void initState() {
    super.initState();
    fetchEarthquakeData();
  }

  // Live Free USGS GeoJSON API Network Connection Layer
  Future<void> fetchEarthquakeData() async {
    final formattedStart = DateFormat('yyyy-MM-dd').format(_startDate);
    final formattedEnd = '${DateFormat('yyyy-MM-dd').format(_endDate)}T23:59:59';

    final url = Uri.parse(
      'https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson&starttime=$formattedStart&endtime=$formattedEnd',
    );

    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _earthquakes = data['features'];
          _sortEarthquakes();
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (error) {
      debugPrint("Error fetching seismic data: $error");
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _sortEarthquakes() {
    if (_currentSortRule == 'Newest First') {
      _earthquakes.sort((a, b) => (b['properties']['time'] as int).compareTo(a['properties']['time'] as int));
    } else if (_currentSortRule == 'Oldest First') {
      _earthquakes.sort((a, b) => (a['properties']['time'] as int).compareTo(b['properties']['time'] as int));
    } else if (_currentSortRule == 'Largest Magnitude') {
      _earthquakes.sort((a, b) {
        final magA = (a['properties']['mag'] as num?)?.toDouble() ?? 0.0;
        final magB = (b['properties']['mag'] as num?)?.toDouble() ?? 0.0;
        return magB.compareTo(magA);
      });
    } else if (_currentSortRule == 'Smallest Magnitude') {
      _earthquakes.sort((a, b) {
        final magA = (a['properties']['mag'] as num?)?.toDouble() ?? 0.0;
        final magB = (b['properties']['mag'] as num?)?.toDouble() ?? 0.0;
        return magA.compareTo(magB);
      });
    }
  }

  void _showReportDialog() {
    showDialog(
      context: context,
      builder: (context) {
        bool feltIt = true;
        DateTime? selectedDate = DateTime.now();
        TimeOfDay? selectedTime = TimeOfDay.now();
        final TextEditingController locationController =
            TextEditingController();

        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E1E1E),
              title: const Text('Report an Earthquake'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(
                      title: const Text('Did you feel it?'),
                      value: feltIt,
                      onChanged: (value) {
                        setStateDialog(() {
                          feltIt = value;
                        });
                      },
                      activeThumbColor: Colors.redAccent,
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      title: const Text('When?'),
                      subtitle: Text(
                        '${DateFormat('yMMMd').format(selectedDate!)} at ${selectedTime!.format(context)}',
                      ),
                      trailing: const Icon(Icons.calendar_today, size: 20),
                      onTap: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: selectedDate!,
                          firstDate: DateTime(2000),
                          lastDate: DateTime.now(),
                        );
                        if (date != null) {
                          if (!context.mounted) return;
                          final time = await showTimePicker(
                            context: context,
                            initialTime: selectedTime!,
                          );
                          if (time != null) {
                            setStateDialog(() {
                              selectedDate = date;
                              selectedTime = time;
                            });
                          }
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: locationController,
                      decoration: const InputDecoration(
                        labelText: 'Where were you?',
                        hintText: 'City, Region, or exact location',
                        border: OutlineInputBorder(),
                        focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.redAccent),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                  ),
                  onPressed: () {
                    // Locally acknowledge the report since there is no backend
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Thank you! Your report has been submitted locally.',
                        ),
                        backgroundColor: Colors.green,
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                  child: const Text(
                    'Submit',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showEarthquakeDetails(Map<String, dynamic> feature) {
    final props = feature['properties'];
    final geometry = feature['geometry'];
    final coords = geometry['coordinates'];

    final double magnitude = (props['mag'] as num?)?.toDouble() ?? 0.0;
    final double longitude = (coords[0] as num?)?.toDouble() ?? 0.0;
    final double latitude = (coords[1] as num?)?.toDouble() ?? 0.0;
    final double depth = (coords[2] as num?)?.toDouble() ?? 0.0;

    final int timeMillis = props['time'] ?? 0;
    final DateTime dateTime = DateTime.fromMillisecondsSinceEpoch(timeMillis);

    final int tsunami = props['tsunami'] ?? 0;

    Color alertColor = Colors.greenAccent;
    String intensity = "Weak";
    if (magnitude >= 4.0 && magnitude < 5.5) {
      alertColor = Colors.orangeAccent;
      intensity = "Moderate";
    } else if (magnitude >= 5.5) {
      alertColor = Colors.redAccent;
      intensity = "Intense";
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A1A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[800],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: alertColor.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                      border: Border.all(color: alertColor, width: 2),
                    ),
                    child: Center(
                      child: Text(
                        magnitude.toStringAsFixed(1),
                        style: TextStyle(
                          color: alertColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          props['place'] ?? 'Unknown Location',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Intensity: $intensity',
                          style: TextStyle(
                            fontSize: 14,
                            color: alertColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Divider(color: Colors.white12),
              const SizedBox(height: 16),
              _buildDetailRow(
                Icons.calendar_today,
                'Time & Date',
                DateFormat('yyyy-MM-dd HH:mm:ss').format(dateTime),
              ),
              _buildDetailRow(
                Icons.straighten,
                'Depth',
                '${depth.toStringAsFixed(2)} km',
              ),
              _buildDetailRow(
                Icons.location_on,
                'Coordinates',
                '${latitude.toStringAsFixed(4)}°, ${longitude.toStringAsFixed(4)}°',
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: tsunami == 1
                      ? Colors.redAccent.withValues(alpha: 0.1)
                      : Colors.greenAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: tsunami == 1
                        ? Colors.redAccent.withValues(alpha: 0.3)
                        : Colors.greenAccent.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      tsunami == 1
                          ? Icons.warning_amber_rounded
                          : Icons.check_circle_outline,
                      color: tsunami == 1
                          ? Colors.redAccent
                          : Colors.greenAccent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        tsunami == 1
                            ? 'TSUNAMI WARNING ISSUED\nCheck local authorities for wave heights and evacuation orders.'
                            : 'No Tsunami Warning',
                        style: TextStyle(
                          color: tsunami == 1
                              ? Colors.redAccent
                              : Colors.greenAccent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey[400]),
          const SizedBox(width: 12),
          Text(
            '$label:',
            style: TextStyle(color: Colors.grey[400], fontSize: 14),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Marker> _buildMarkers() {
    return _earthquakes.map((feature) {
      final props = feature['properties'];
      final geometry = feature['geometry'];
      final coords = geometry['coordinates'];

      final double magnitude = (props['mag'] as num?)?.toDouble() ?? 0.0;
      final double longitude = (coords[0] as num?)?.toDouble() ?? 0.0;
      final double latitude = (coords[1] as num?)?.toDouble() ?? 0.0;

      Color alertColor = Colors.greenAccent;
      double size = 20.0;

      if (magnitude >= 4.0 && magnitude < 5.5) {
        alertColor = Colors.orangeAccent;
        size = 30.0;
      } else if (magnitude >= 5.5) {
        alertColor = Colors.redAccent;
        size = 40.0;
      }

      return Marker(
        point: LatLng(latitude, longitude),
        width: size,
        height: size,
        child: GestureDetector(
          onTap: () => _showEarthquakeDetails(feature),
          child: Container(
            decoration: BoxDecoration(
              color: alertColor.withValues(alpha: 0.6),
              shape: BoxShape.circle,
              border: Border.all(color: alertColor, width: 2),
              boxShadow: [
                BoxShadow(
                  color: alertColor.withValues(alpha: 0.4),
                  blurRadius: 8,
                ),
              ],
            ),
          ),
        ),
      );
    }).toList();
  }

  void _zoomIn() {
    final currentZoom = _mapController.camera.zoom;
    _mapController.move(_mapController.camera.center, currentZoom + 1.0);
  }

  void _zoomOut() {
    final currentZoom = _mapController.camera.zoom;
    _mapController.move(_mapController.camera.center, currentZoom - 1.0);
  }

  void _moveToRegion(LatLng center, double zoom) {
    _mapController.move(center, zoom);
  }

  void _showRegionalMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      builder: (context) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.public, color: Colors.blueAccent),
              title: const Text('World'),
              onTap: () {
                Navigator.pop(context);
                _moveToRegion(const LatLng(0, 0), 2.0);
              },
            ),
            ListTile(
              leading: const Icon(Icons.public, color: Colors.greenAccent),
              title: const Text('North America'),
              onTap: () {
                Navigator.pop(context);
                _moveToRegion(const LatLng(45.0, -100.0), 3.0);
              },
            ),
            ListTile(
              leading: const Icon(Icons.public, color: Colors.greenAccent),
              title: const Text('South America'),
              onTap: () {
                Navigator.pop(context);
                _moveToRegion(const LatLng(-15.0, -60.0), 3.0);
              },
            ),
            ListTile(
              leading: const Icon(Icons.public, color: Colors.orangeAccent),
              title: const Text('Europe'),
              onTap: () {
                Navigator.pop(context);
                _moveToRegion(const LatLng(50.0, 10.0), 4.0);
              },
            ),
            ListTile(
              leading: const Icon(Icons.public, color: Colors.orangeAccent),
              title: const Text('Africa'),
              onTap: () {
                Navigator.pop(context);
                _moveToRegion(const LatLng(0.0, 20.0), 3.0);
              },
            ),
            ListTile(
              leading: const Icon(Icons.public, color: Colors.redAccent),
              title: const Text('Asia'),
              onTap: () {
                Navigator.pop(context);
                _moveToRegion(const LatLng(30.0, 100.0), 3.0);
              },
            ),
            ListTile(
              leading: const Icon(Icons.public, color: Colors.blueAccent),
              title: const Text('Oceania'),
              onTap: () {
                Navigator.pop(context);
                _moveToRegion(const LatLng(-25.0, 135.0), 3.0);
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: _showMap ? 360 : null,
      color: const Color(0xFF161616),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF262626),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.date_range, color: Colors.white),
                  label: Text(
                    '${DateFormat('MMM d').format(_startDate)} - ${DateFormat('MMM d').format(_endDate)}',
                    style: const TextStyle(color: Colors.white),
                  ),
                  onPressed: () async {
                    final picked = await showDateRangePicker(
                      context: context,
                      initialDateRange: DateTimeRange(
                        start: _startDate,
                        end: _endDate,
                      ),
                      firstDate: DateTime(2000),
                      lastDate: DateTime.now(),
                      builder: (context, child) {
                        return Theme(
                          data: Theme.of(context).copyWith(
                            colorScheme: const ColorScheme.dark(
                              primary: Colors.redAccent,
                              onPrimary: Colors.white,
                              surface: Color(0xFF1E1E1E),
                              onSurface: Colors.white,
                            ),
                          ),
                          child: child!,
                        );
                      },
                    );
                    if (picked != null) {
                      setState(() {
                        _startDate = picked.start;
                        _endDate = picked.end;
                        _isLoading = true;
                      });
                      fetchEarthquakeData();
                    }
                  },
                ),
                const SizedBox(height: 12),
                const Text(
                  'SORT BY:',
                  style: TextStyle(
                    color: Colors.grey,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF262626),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _currentSortRule,
                      dropdownColor: const Color(0xFF1E1E1E),
                      icon: const Icon(Icons.sort, color: Colors.white),
                      style: const TextStyle(color: Colors.white),
                      onChanged: (String? newValue) {
                        if (newValue != null) {
                          setState(() {
                            _currentSortRule = newValue;
                            _sortEarthquakes();
                          });
                        }
                      },
                      items: <String>[
                        'Newest First',
                        'Oldest First',
                        'Largest Magnitude',
                        'Smallest Magnitude'
                      ].map<DropdownMenuItem<String>>((String value) {
                        return DropdownMenuItem<String>(
                          value: value,
                          child: Text(value),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.redAccent),
                  )
                : ListView.builder(
                    itemCount: _earthquakes.length,
                    itemBuilder: (context, index) {
                      final feature = _earthquakes[index];
                      final props = feature['properties'];
                      final coords = feature['geometry']['coordinates'];

                      final double magnitude =
                          (props['mag'] as num?)?.toDouble() ?? 0.0;
                      final double longitude =
                          (coords[0] as num?)?.toDouble() ?? 0.0;
                      final double latitude =
                          (coords[1] as num?)?.toDouble() ?? 0.0;

                      final int timeMillis = props['time'] ?? 0;
                      final DateTime dateTime =
                          DateTime.fromMillisecondsSinceEpoch(timeMillis);

                      Color alertColor = Colors.greenAccent;
                      if (magnitude >= 4.0 && magnitude < 5.5) {
                        alertColor = Colors.orangeAccent;
                      } else if (magnitude >= 5.5)
                        alertColor = Colors.redAccent;

                      return Card(
                        color: const Color(0xFF1E1E1E),
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            _mapController.move(
                              LatLng(latitude, longitude),
                              6.0,
                            );
                            _showEarthquakeDetails(feature);
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12.0),
                            child: Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: alertColor.withValues(alpha: 0.15),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: alertColor,
                                      width: 2,
                                    ),
                                  ),
                                  child: Center(
                                    child: Text(
                                      magnitude.toStringAsFixed(1),
                                      style: TextStyle(
                                        color: alertColor,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        props['place'] ?? 'Unknown',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            DateFormat(
                                              'MMM d, HH:mm',
                                            ).format(dateTime),
                                            style: const TextStyle(
                                              color: Colors.grey,
                                              fontSize: 12,
                                            ),
                                          ),
                                          Text(
                                            (props['status'] ?? '')
                                                .toString()
                                                .toUpperCase(),
                                            style: TextStyle(
                                              color: alertColor,
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapPane() {
    return Expanded(
      child: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: const MapOptions(
              initialCenter: LatLng(0, 0),
              initialZoom: 2.0,
              minZoom: 1.0,
              maxZoom: 18.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.seismic_one',
              ),
              MarkerLayer(markers: _buildMarkers()),
            ],
          ),
          Positioned(
            top: 16,
            right: 16,
            child: Column(
              children: [
                FloatingActionButton(
                  heroTag: 'menu',
                  mini: true,
                  backgroundColor: const Color(0xFF262626),
                  onPressed: _showRegionalMenu,
                  child: const Icon(Icons.public, color: Colors.white),
                ),
                const SizedBox(height: 16),
                FloatingActionButton(
                  heroTag: 'zoomIn',
                  mini: true,
                  backgroundColor: const Color(0xFF262626),
                  onPressed: _zoomIn,
                  child: const Icon(Icons.add, color: Colors.white),
                ),
                const SizedBox(height: 8),
                FloatingActionButton(
                  heroTag: 'zoomOut',
                  mini: true,
                  backgroundColor: const Color(0xFF262626),
                  onPressed: _zoomOut,
                  child: const Icon(Icons.remove, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '⚠️ SEISMIC_ONE LIVE MATRIX',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.add_alert, color: Colors.orangeAccent),
          tooltip: 'Report Felt Earthquake',
          onPressed: _showReportDialog,
        ),
        actions: [
          IconButton(
            icon: Icon(
              _showSidebar ? Icons.dashboard_rounded : Icons.dashboard_outlined,
              color: _showSidebar ? Colors.orangeAccent : Colors.white,
            ),
            tooltip: 'Toggle Sidebar',
            onPressed: () {
              if (_showSidebar && !_showMap) return;
              setState(() => _showSidebar = !_showSidebar);
            },
          ),
          IconButton(
            icon: Icon(
              _showMap ? Icons.map_rounded : Icons.map_outlined,
              color: _showMap ? Colors.orangeAccent : Colors.white,
            ),
            tooltip: 'Toggle Map',
            onPressed: () {
              if (_showMap && !_showSidebar) return;
              setState(() => _showMap = !_showMap);
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            tooltip: 'Refresh Live Feed',
            onPressed: () {
              setState(() => _isLoading = true);
              fetchEarthquakeData();
            },
          ),
        ],
      ),
      body: Row(
        children: [
          if (_showSidebar)
            _showMap ? _buildSidebar() : Expanded(child: _buildSidebar()),
          if (_showMap)
            _buildMapPane(),
        ],
      ),
    );
  }
}
