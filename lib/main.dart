import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:intl/intl.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load local environment file completely into application memory before UI mounts
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    debugPrint(
      "Environment setup warning: Ensure .env file exists and is registered in pubspec.yaml ($e)",
    );
  }

  runApp(const SeismicOneApp());
}

// ─── Chat Message Model ────────────────────────────────────────────────────────
class ChatMessage {
  final String role; // 'user' | 'assistant'
  final String content;
  final DateTime timestamp;

  const ChatMessage({
    required this.role,
    required this.content,
    required this.timestamp,
  });
}

// ─── Root Application ──────────────────────────────────────────────────────────
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

// ─── Dashboard Widget ─────────────────────────────────────────────────────────
class EarthquakeDashboard extends StatefulWidget {
  const EarthquakeDashboard({super.key});

  @override
  State<EarthquakeDashboard> createState() => _EarthquakeDashboardState();
}

class _EarthquakeDashboardState extends State<EarthquakeDashboard> {
  // ─── Seismic Data State ───────────────────────────────────────────────────────
  List _earthquakes = [];
  bool _isLoading = true;
  final MapController _mapController = MapController();
  List<Polyline> _tectonicPolylines = [];

  DateTime _startDate = DateTime.now().subtract(const Duration(days: 1));
  DateTime _endDate = DateTime.now();
  String _currentSortRule = 'Newest First';
  Map<String, dynamic>? _selectedQuake;
  bool _onlyShowVisibleInMap = false;

  // ─── Tri-Pane Visibility State Flags ─────────────────────────────────────────
  bool _showSidebar = true;
  bool _showMap = true;
  bool _showAIChat = true;

  // ———— Groq AI Configuration ————
  String get _groqApiKey {
    // If running live on GitHub Pages web, use the secure production fallback token directly
    if (kIsWeb) {
      return "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";
    }
    // If running locally on my machine, look for the standard local configuration file
    return dotenv.env['GROQ_API_KEY'] ?? "";
  }

  final List<ChatMessage> _chatHistory = [];
  final TextEditingController _aiInputController = TextEditingController();

  // ✅ Lifted ScrollController up to persistent State scope to allow auto-scrolling updates
  final ScrollController _chatScrollController = ScrollController();
  bool _isAiLoading = false;

  // ─── Computed: Visible Earthquakes ───────────────────────────────────────────
  List get _visibleEarthquakes {
    if (!_onlyShowVisibleInMap) return _earthquakes;
    try {
      return _earthquakes.where((feature) {
        final coords = feature['geometry']['coordinates'];
        final point = LatLng(
          (coords[1] as num).toDouble(),
          (coords[0] as num).toDouble(),
        );
        return _mapController.camera.visibleBounds.contains(point);
      }).toList();
    } catch (_) {
      return _earthquakes;
    }
  }

  @override
  void initState() {
    super.initState();
    fetchEarthquakeData();
    _loadTectonicPlates();
  }

  @override
  void dispose() {
    _aiInputController.dispose();
    _chatScrollController
        .dispose(); // ✅ Safe cleanup of the scroll tracker loop
    super.dispose();
  }

  // ─── USGS GeoJSON Live Fetch ──────────────────────────────────────────────────
  Future<void> _loadTectonicPlates() async {
    try {
      // ✅ Adjusted to standard forward slash syntax matching asset bundles directly
      final raw = await rootBundle.loadString(
        'assets/json/tectonic_plates.json',
      );
      final Map<String, dynamic> decoded =
          json.decode(raw) as Map<String, dynamic>;
      final features = decoded['features'] as List<dynamic>? ?? [];

      List<List<LatLng>> splitAntimeridianSegments(List<dynamic> coordList) {
        final segments = <List<LatLng>>[];
        List<LatLng> current = [];

        for (final rawPair in coordList) {
          try {
            if (rawPair is List && rawPair.length >= 2) {
              final lon = (rawPair[0] as num).toDouble();
              final lat = (rawPair[1] as num).toDouble();
              final point = LatLng(lat, lon);

              if (current.isEmpty) {
                current.add(point);
                continue;
              }

              final prev = current.last;
              final lonDiff = (prev.longitude - lon).abs();

              if (lonDiff > 180.0) {
                if (current.isNotEmpty) {
                  segments.add(List<LatLng>.from(current));
                }
                current = [point];
              } else {
                current.add(point);
              }
            }
          } catch (_) {
            continue;
          }
        }

        if (current.isNotEmpty) segments.add(current);
        return segments;
      }

      final parsedPolylines = <Polyline>[];

      for (final feature in features) {
        if (feature is! Map<String, dynamic>) continue;
        final geometry = feature['geometry'] as Map<String, dynamic>?;
        if (geometry == null) continue;

        final type = (geometry['type'] ?? '').toString();
        final coords = geometry['coordinates'];
        if (coords == null) continue;

        if (type == 'LineString' && coords is List) {
          final segments = splitAntimeridianSegments(coords);
          for (final seg in segments) {
            if (seg.length > 1) {
              parsedPolylines.add(
                Polyline(
                  points: seg,
                  color: const Color(0xFFD32F2F).withOpacity(0.40),
                  strokeWidth: 1.5,
                ),
              );
            }
          }
        } else if (type == 'Polygon' && coords is List && coords.isNotEmpty) {
          final exterior = coords[0] as List<dynamic>;
          final segments = splitAntimeridianSegments(exterior);
          for (final seg in segments) {
            if (seg.length > 1) {
              parsedPolylines.add(
                Polyline(
                  points: seg,
                  color: const Color(0xFFD32F2F).withOpacity(0.40),
                  strokeWidth: 1.5,
                ),
              );
            }
          }
        } else if (type == 'MultiPolygon' && coords is List) {
          for (final polygon in coords) {
            if (polygon is List && polygon.isNotEmpty) {
              final exterior = polygon[0] as List<dynamic>;
              final segments = splitAntimeridianSegments(exterior);
              for (final seg in segments) {
                if (seg.length > 1) {
                  parsedPolylines.add(
                    Polyline(
                      points: seg,
                      color: const Color(0xFFD32F2F),
                      strokeWidth: 2.0,
                    ),
                  );
                }
              }
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _tectonicPolylines = parsedPolylines;
        });
      }
    } catch (error) {
      debugPrint('Failed to load tectonic plate data: $error');
    }
  }

  Future<void> fetchEarthquakeData() async {
    final formattedStart = DateFormat('yyyy-MM-dd').format(_startDate);
    final formattedEnd =
        '${DateFormat('yyyy-MM-dd').format(_endDate)}T23:59:59';

    final url = Uri.parse(
      'https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson'
      '&starttime=$formattedStart&endtime=$formattedEnd',
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
        setState(() => _isLoading = false);
      }
    } catch (error) {
      debugPrint("Error fetching seismic data: $error");
      setState(() => _isLoading = false);
    }
  }

  // ─── Sort Logic ───────────────────────────────────────────────────────────────
  void _sortEarthquakes() {
    if (_currentSortRule == 'Newest First') {
      _earthquakes.sort(
        (a, b) => (b['properties']['time'] as int).compareTo(
          a['properties']['time'] as int,
        ),
      );
    } else if (_currentSortRule == 'Oldest First') {
      _earthquakes.sort(
        (a, b) => (a['properties']['time'] as int).compareTo(
          b['properties']['time'] as int,
        ),
      );
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

  // ─── Groq AI Network Layer ────────────────────────────────────────────────────
  Future<void> _sendMessageToAi(String userText) async {
    if (userText.trim().isEmpty) return;

    setState(() {
      _chatHistory.add(
        ChatMessage(
          role: 'user',
          content: userText.trim(),
          timestamp: DateTime.now(),
        ),
      );
      _isAiLoading = true;
    });

    _aiInputController.clear();
    _scrollToBottom();

    final String baseSystemPrompt;
    if (_selectedQuake != null) {
      final props = _selectedQuake!['properties'];
      final coords = _selectedQuake!['geometry']['coordinates'];
      final double magnitude = (props['mag'] as num?)?.toDouble() ?? 0.0;
      final double depth = (coords[2] as num?)?.toDouble() ?? 0.0;
      final String location = props['place'] ?? 'Unknown Location';
      final int timeMillis = props['time'] ?? 0;
      final DateTime eventTime = DateTime.fromMillisecondsSinceEpoch(
        timeMillis,
      );
      final String timestamp = DateFormat(
        'yyyy-MM-dd HH:mm:ss',
      ).format(eventTime);
      final int tsunami = props['tsunami'] ?? 0;
      final String tsunamiThreat = tsunami == 1
          ? "ACTIVE WARNING ISSUED"
          : "None detected";

      baseSystemPrompt =
          '''You are SeismicOne AI — an elite seismology analyst and emergency disaster response strategist embedded inside a live earthquake monitoring dashboard.

CURRENT LIVE TELEMETRY LOG:
  • Location: $location
  • Moment Magnitude: M${magnitude.toStringAsFixed(1)}
  • Hypocentral Depth: ${depth.toStringAsFixed(1)} km
  • Event Timestamp: $timestamp
  • Tsunami Threat: $tsunamiThreat

Use this seismic telemetry data as your primary reasoning context. Avoid fluff phrases. Format your output cleanly using distinct sections such as "🚨 Immediate Risk Assessment" and "🛠️ Actionable Safety Directives" with sharp Markdown bullet points.''';
    } else {
      baseSystemPrompt =
          '''You are SeismicOne AI — an elite seismology analyst and emergency disaster response strategist embedded inside a live earthquake monitoring dashboard.

No epicenter is currently selected. Answer general seismology questions, explain earthquake risks, discuss preparedness strategies, and interpret USGS data. Avoid fluff phrases and format your output cleanly using sharp Markdown bullet points.''';
    }

    try {
      final response = await http.post(
        Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_groqApiKey',
        },
        body: json.encode({
          'model': 'llama-3.1-8b-instant',
          'messages': [
            {'role': 'system', 'content': baseSystemPrompt},
            ..._chatHistory.map((m) => {'role': m.role, 'content': m.content}),
          ],
          'temperature': 0.3,
          'max_tokens': 1024,
        }),
      );

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        final aiText =
            responseData['choices'][0]['message']['content'] ??
            'Unable to analyze telemetry.';
        setState(() {
          _chatHistory.add(
            ChatMessage(
              role: 'assistant',
              content: aiText,
              timestamp: DateTime.now(),
            ),
          );
          _isAiLoading = false;
        });
      } else {
        final errorBody = json.decode(response.body);
        final errorMsg =
            errorBody['error']?['message'] ?? 'HTTP ${response.statusCode}';
        setState(() {
          _chatHistory.add(
            ChatMessage(
              role: 'assistant',
              content:
                  '⚠️ Groq API error: $errorMsg\n\nVerify your API key configuration parameters.',
              timestamp: DateTime.now(),
            ),
          );
          _isAiLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _chatHistory.add(
          ChatMessage(
            role: 'assistant',
            content:
                '🔌 Network drop detected. Check your internet connection and try again.\n\nError: $e',
            timestamp: DateTime.now(),
          ),
        );
        _isAiLoading = false;
      });
    } finally {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 120), () {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ─── Report Dialog ────────────────────────────────────────────────────────────
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
                      onChanged: (value) =>
                          setStateDialog(() => feltIt = value),
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

  // ─── Floating Info Card (Map Overlay) ────────────────────────────────────────
  Widget _buildFloatingInfoCard() {
    if (_selectedQuake == null) return const SizedBox.shrink();
    final props = _selectedQuake!['properties'];
    final coords = _selectedQuake!['geometry']['coordinates'];

    final double magnitude = (props['mag'] as num?)?.toDouble() ?? 0.0;
    final double longitude = (coords[0] as num?)?.toDouble() ?? 0.0;
    final double latitude = (coords[1] as num?)?.toDouble() ?? 0.0;
    final double depth = (coords[2] as num?)?.toDouble() ?? 0.0;
    final int timeMillis = props['time'] ?? 0;
    final DateTime dateTime = DateTime.fromMillisecondsSinceEpoch(timeMillis);
    final int tsunami = props['tsunami'] ?? 0;

    Color alertColor = Colors.greenAccent;
    String intensity = 'Weak';
    if (magnitude >= 4.0 && magnitude < 5.5) {
      alertColor = Colors.orangeAccent;
      intensity = 'Moderate';
    } else if (magnitude >= 5.5) {
      alertColor = Colors.redAccent;
      intensity = 'Intense';
    }

    return Positioned(
      bottom: 16,
      left: 16,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 350),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xEE1A1A1A),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.6),
                blurRadius: 16,
                spreadRadius: 2,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
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
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          props['place'] ?? 'Unknown Location',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          intensity,
                          style: TextStyle(
                            fontSize: 12,
                            color: alertColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey, size: 18),
                    onPressed: () => setState(() => _selectedQuake = null),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const Divider(color: Colors.white12, height: 16),
              Text(
                '🕐 ${DateFormat('yyyy-MM-dd HH:mm').format(dateTime)}'
                '  |  📍 ${latitude.toStringAsFixed(3)}°, ${longitude.toStringAsFixed(3)}°'
                '  |  ⬇ ${depth.toStringAsFixed(1)} km',
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: tsunami == 1
                      ? Colors.redAccent.withValues(alpha: 0.12)
                      : Colors.greenAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: tsunami == 1
                        ? Colors.redAccent.withValues(alpha: 0.4)
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
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      tsunami == 1
                          ? 'TSUNAMI WARNING ISSUED'
                          : 'No Tsunami Warning',
                      style: TextStyle(
                        color: tsunami == 1
                            ? Colors.redAccent
                            : Colors.greenAccent,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: Colors.purpleAccent.withValues(alpha: 0.5),
                    ),
                    foregroundColor: Colors.purpleAccent,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  icon: const Icon(Icons.psychology_rounded, size: 16),
                  label: const Text(
                    'Analyze with AI',
                    style: TextStyle(fontSize: 12),
                  ),
                  onPressed: () {
                    if (!_showAIChat) setState(() => _showAIChat = true);
                    final p = _selectedQuake!['properties'];
                    final c = _selectedQuake!['geometry']['coordinates'];
                    final mag = (p['mag'] as num?)?.toDouble() ?? 0.0;
                    final d = (c[2] as num?)?.toDouble() ?? 0.0;
                    final place = p['place'] ?? 'Unknown';
                    _sendMessageToAi(
                      'Analyze this earthquake: M${mag.toStringAsFixed(1)} at $place, '
                      'depth ${d.toStringAsFixed(1)} km. '
                      'What are the key risks and recommended immediate actions?',
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Map Marker Builder ───────────────────────────────────────────────────────
  List<Marker> _buildMarkers() {
    final List<Marker> normalMarkers = [];
    final List<Marker> selectedMarkers = [];

    double currentZoom;
    try {
      currentZoom = _mapController.camera.zoom;
    } catch (_) {
      currentZoom = 4.0;
    }

    for (final feature in _visibleEarthquakes) {
      final props = feature['properties'];
      final coords = feature['geometry']['coordinates'];

      final double magnitude = (props['mag'] as num?)?.toDouble() ?? 0.0;
      final double longitude = (coords[0] as num?)?.toDouble() ?? 0.0;
      final double latitude = (coords[1] as num?)?.toDouble() ?? 0.0;

      final bool isSelected =
          _selectedQuake != null &&
          _selectedQuake!['properties']['time'] == props['time'];

      Color alertColor = Colors.greenAccent;
      if (magnitude >= 4.0 && magnitude < 5.5) {
        alertColor = Colors.orangeAccent;
      } else if (magnitude >= 5.5) {
        alertColor = Colors.redAccent;
      }

      final double markerSize = isSelected
          ? 38.0
          : (12.0 + (currentZoom * 1.1)).clamp(12.0, 26.0);

      final marker = Marker(
        point: LatLng(latitude, longitude),
        width: markerSize,
        height: markerSize,
        child: GestureDetector(
          onTap: () => setState(() => _selectedQuake = feature),
          child: Container(
            decoration: BoxDecoration(
              color: alertColor.withValues(alpha: isSelected ? 0.75 : 0.35),
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? Colors.white : alertColor,
                width: isSelected ? 2.5 : 1.5,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: alertColor.withValues(alpha: 0.7),
                        blurRadius: 10,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
          ),
        ),
      );

      if (isSelected) {
        selectedMarkers.add(marker);
      } else {
        normalMarkers.add(marker);
      }
    }

    return [...normalMarkers, ...selectedMarkers];
  }

  // ─── Map Controls ─────────────────────────────────────────────────────────────
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

  // ─── Legend Popup ─────────────────────────────────────────────────────────────
  void _showLegendPopup() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text(
            'Map Legend',
            style: TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildLegendItem(
                Colors.greenAccent,
                'Weak Tremors (Magnitude < 3.0)',
              ),
              const SizedBox(height: 12),
              _buildLegendItem(
                Colors.orangeAccent,
                'Moderate Tremors (Magnitude 3.0 to 4.9)',
              ),
              const SizedBox(height: 12),
              _buildLegendItem(
                Colors.redAccent,
                'Intense / Severe Tremors (Magnitude >= 5.0)',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 24,
                    height: 4,
                    color: const Color(0xFFD32F2F),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Active Geological Tectonic Fault Lines',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close', style: TextStyle(color: Colors.grey)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLegendItem(Color color, String text) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.5),
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: const TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }

  // ─── Regional Jump Menu ───────────────────────────────────────────────────────
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

  // LEFT PANE: Filter Sidebar
  Widget _buildSidebar() {
    return Container(
      width: (_showMap || _showAIChat) ? 360 : null,
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
                    '${DateFormat('MMM d').format(_startDate)} – ${DateFormat('MMM d').format(_endDate)}',
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
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF262626),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      Text(
                        'Showing: ${_visibleEarthquakes.length} Earthquakes',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Expanded(
                            child: Text(
                              'Only list Earthquakes Shown in Map',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Switch(
                            value: _onlyShowVisibleInMap,
                            onChanged: (val) =>
                                setState(() => _onlyShowVisibleInMap = val),
                            activeThumbColor: Colors.orangeAccent,
                          ),
                        ],
                      ),
                    ],
                  ),
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
                      items:
                          <String>[
                                'Newest First',
                                'Oldest First',
                                'Largest Magnitude',
                                'Smallest Magnitude',
                              ]
                              .map<DropdownMenuItem<String>>(
                                (v) => DropdownMenuItem<String>(
                                  value: v,
                                  child: Text(v),
                                ),
                              )
                              .toList(),
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
                    itemCount: _visibleEarthquakes.length,
                    itemBuilder: (context, index) {
                      final feature = _visibleEarthquakes[index];
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
                      } else if (magnitude >= 5.5) {
                        alertColor = Colors.redAccent;
                      }

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
                            setState(() => _selectedQuake = feature);
                            _mapController.move(
                              LatLng(latitude, longitude),
                              8.0,
                            );
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

  // CENTER PANE: Vector Map
  Widget _buildMapPane() {
    return Expanded(
      flex: 3,
      child: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const LatLng(0, 0),
              initialZoom: 2.0,
              minZoom: 1.0,
              maxZoom: 18.0,
              onPositionChanged: (position, hasGesture) => setState(() {}),
              onTap: (tapPosition, point) =>
                  setState(() => _selectedQuake = null),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.seismic_one',
              ),
              PolylineLayer(polylines: _tectonicPolylines),
              MarkerLayer(markers: _buildMarkers()),
            ],
          ),
          _buildFloatingInfoCard(),
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
                  heroTag: 'legend',
                  mini: true,
                  backgroundColor: const Color(0xFF1A1A1A),
                  onPressed: _showLegendPopup,
                  child: const Icon(
                    Icons.legend_toggle_rounded,
                    color: Colors.white,
                  ),
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

  // RIGHT PANE: Groq AI Emergency Assistant
  Widget _buildAIChatPane() {
    return Container(
      width: 380,
      decoration: const BoxDecoration(
        color: Color(0xFF0F0F1A),
        border: Border(left: BorderSide(color: Color(0xFF2A2A3A), width: 1)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: const BoxDecoration(
              color: Color(0xFF14142B),
              border: Border(bottom: BorderSide(color: Color(0xFF2A2A3A))),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF7C3AED), Color(0xFF4F46E5)],
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.psychology_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'SeismicOne AI',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        _selectedQuake != null
                            ? '⚡ Epicenter context loaded'
                            : '● Ready for queries',
                        style: TextStyle(
                          color: _selectedQuake != null
                              ? Colors.purpleAccent
                              : Colors.greenAccent,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_chatHistory.isNotEmpty)
                  IconButton(
                    icon: const Icon(
                      Icons.delete_sweep_rounded,
                      color: Colors.grey,
                      size: 18,
                    ),
                    tooltip: 'Clear chat',
                    onPressed: () => setState(() => _chatHistory.clear()),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
              ],
            ),
          ),

          // Active epicenter context banner
          if (_selectedQuake != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.purple.withValues(alpha: 0.08),
                border: const Border(
                  bottom: BorderSide(color: Color(0xFF2A2A3A)),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.location_on_rounded,
                    color: Colors.purpleAccent,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      () {
                        final p = _selectedQuake!['properties'];
                        final c = _selectedQuake!['geometry']['coordinates'];
                        final mag = (p['mag'] as num?)?.toDouble() ?? 0.0;
                        final d = (c[2] as num?)?.toDouble() ?? 0.0;
                        return 'M${mag.toStringAsFixed(1)} · ${p['place'] ?? 'Unknown'} · ${d.toStringAsFixed(0)} km depth';
                      }(),
                      style: const TextStyle(
                        color: Colors.purpleAccent,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

          // Chat messages block
          Expanded(
            child: _chatHistory.isEmpty
                ? _buildEmptyAIState()
                : ListView.builder(
                    controller: _chatScrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: _chatHistory.length + (_isAiLoading ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (_isAiLoading && index == _chatHistory.length) {
                        return _buildTypingIndicator();
                      }
                      return _buildChatBubble(_chatHistory[index]);
                    },
                  ),
          ),

          // Input bar
          Container(
            padding: const EdgeInsets.all(12),
            decoration: const BoxDecoration(
              color: Color(0xFF14142B),
              border: Border(top: BorderSide(color: Color(0xFF2A2A3A))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _aiInputController,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    maxLines: null,
                    decoration: InputDecoration(
                      hintText: 'Ask about seismic risks, safety...',
                      hintStyle: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 13,
                      ),
                      filled: true,
                      fillColor: const Color(0xFF1C1C30),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                    onSubmitted: (text) => _sendMessageToAi(text),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF7C3AED), Color(0xFF4F46E5)],
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: IconButton(
                    onPressed: _isAiLoading
                        ? null
                        : () => _sendMessageToAi(_aiInputController.text),
                    icon: _isAiLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(
                            Icons.send_rounded,
                            color: Colors.white,
                            size: 18,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyAIState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF7C3AED), Color(0xFF4F46E5)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.psychology_rounded,
                color: Colors.white,
                size: 38,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'SeismicOne AI',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Powered by Groq · Llama 3.1\nSelect an epicenter on the map or ask anything about earthquake safety and seismic risk.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _buildQuickPrompt('🌊 Tsunami risk factors'),
                _buildQuickPrompt('🏚️ Earthquake preparedness'),
                _buildQuickPrompt('📊 Richter vs Moment magnitude'),
                _buildQuickPrompt('🔴 Ring of Fire explained'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickPrompt(String text) {
    return GestureDetector(
      onTap: () => _sendMessageToAi(text),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C30),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF2A2A4A)),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ),
    );
  }

  Widget _buildChatBubble(ChatMessage msg) {
    final isUser = msg.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.only(right: 8, top: 2),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF7C3AED), Color(0xFF4F46E5)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.psychology_rounded,
                color: Colors.white,
                size: 16,
              ),
            ),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser
                    ? const Color(0xFF2D1F6E)
                    : const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
                border: Border.all(
                  color: isUser
                      ? Colors.purple.withValues(alpha: 0.3)
                      : Colors.white.withValues(alpha: 0.06),
                ),
              ),
              child: Text(
                msg.content,
                style: TextStyle(
                  color: isUser
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.9),
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
          if (isUser) ...[
            Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.only(left: 8, top: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF2D1F6E),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.person_rounded,
                color: Colors.white70,
                size: 16,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(right: 8, top: 2),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF7C3AED), Color(0xFF4F46E5)],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.psychology_rounded,
              color: Colors.white,
              size: 16,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 44, height: 16, child: _TypingDots()),
                const SizedBox(width: 8),
                Text(
                  'Analyzing telemetry...',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // MAIN BUILD — Tri-Pane Scaffold
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
              Icons.dashboard_rounded,
              color: _showSidebar ? Colors.orangeAccent : Colors.white54,
            ),
            tooltip: 'Toggle Sidebar',
            onPressed: () {
              if (_showSidebar && !_showMap && !_showAIChat) return;
              setState(() => _showSidebar = !_showSidebar);
            },
          ),
          IconButton(
            icon: Icon(
              Icons.map_rounded,
              color: _showMap ? Colors.orangeAccent : Colors.white54,
            ),
            tooltip: 'Toggle Map',
            onPressed: () {
              if (_showMap && !_showSidebar && !_showAIChat) return;
              setState(() => _showMap = !_showMap);
            },
          ),
          IconButton(
            icon: Icon(
              Icons.psychology_rounded,
              color: _showAIChat ? Colors.purpleAccent : Colors.white54,
            ),
            tooltip: 'Toggle AI Assistant',
            onPressed: () {
              if (_showAIChat && !_showSidebar && !_showMap) return;
              setState(() => _showAIChat = !_showAIChat);
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth > 900) {
            return Row(
              children: [
                if (_showSidebar)
                  (_showMap || _showAIChat)
                      ? _buildSidebar()
                      : Expanded(child: _buildSidebar()),
                if (_showMap) _buildMapPane(),
                if (_showAIChat) _buildAIChatPane(),
              ],
            );
          } else {
            int currentIndex = 0;
            if (_showMap) {
              currentIndex = 0;
            } else if (_showAIChat) {
              currentIndex = 1;
            } else {
              currentIndex = 2;
            }

            return IndexedStack(
              index: currentIndex,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [_buildMapPane()],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [Expanded(child: _buildAIChatPane())],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [Expanded(child: _buildSidebar())],
                ),
              ],
            );
          }
        },
      ),
    );
  }
}

// ─── Animated Typing Dots Widget ─────────────────────────────────────────────
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (i) {
            final delay = i / 3.0;
            final value = ((_controller.value - delay) % 1.0).clamp(0.0, 1.0);
            final opacity = (value < 0.5 ? value * 2 : (1.0 - value) * 2).clamp(
              0.2,
              1.0,
            );
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: Colors.purpleAccent.withValues(alpha: opacity),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}
