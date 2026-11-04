import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart'; // <-- Import Geolocator

void main() => runApp(const MaterialApp(home: BleScanPage()));

class BleScanPage extends StatefulWidget {
  const BleScanPage({super.key});
  @override
  State<BleScanPage> createState() => _BleScanPageState();
}

class _BleScanPageState extends State<BleScanPage> {
  List<ScanResult> _results = [];
  StreamSubscription<List<int>>? _sosSubscription;
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    FlutterBluePlus.onScanResults.listen((results) {
      setState(() => _results = results);
    });
  }

  @override
  void dispose() {
    _sosSubscription?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (await FlutterBluePlus.isSupported == false) return;
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
  }

  // --- NEW FUNCTION: Get Location ---
  Future<Position?> _getLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    // 1. Check if location services are enabled on the phone
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('Location services are disabled.');
      return null;
    }

    // 2. Check permissions
    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint('Location permissions are denied');
        return null;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      debugPrint('Location permissions are permanently denied.');
      return null;
    }

    // 3. Get the position
    return await Geolocator.getCurrentPosition();
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      await FlutterBluePlus.stopScan();
      await device.connect();

      setState(() => _isConnected = true);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connected! Ready for SOS.')),
      );

      List<BluetoothService> services = await device.discoverServices();

      for (var service in services) {
        if (service.uuid.toString().toUpperCase() ==
            "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") {
          for (var characteristic in service.characteristics) {
            if (characteristic.uuid.toString().toUpperCase() ==
                "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") {
              await characteristic.setNotifyValue(true);

              _sosSubscription = characteristic.onValueReceived.listen((
                value,
              ) async {
                // <-- Added async
                String message = String.fromCharCodes(value);
                if (message == "SOS") {
                  // Trigger location fetch
                  await _handleEmergency();
                }
              });
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Connection failed: $e');
    }
  }

  // --- NEW FUNCTION: Handle Emergency ---
  Future<void> _handleEmergency() async {
    if (!mounted) return;

    // Show a loading dialog while getting GPS
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Text("Getting location..."),
          ],
        ),
      ),
    );

    Position? position = await _getLocation();

    if (!mounted) return;
    Navigator.pop(context); // Close loading dialog

    if (position != null) {
      _showSosDialog(position.latitude, position.longitude);
    } else {
      _showSosDialog(null, null); // Show dialog even if GPS fails
    }
  }

  void _showSosDialog(double? lat, double? lng) {
    String locationText = (lat != null && lng != null)
        ? 'Lat: $lat\nLng: $lng'
        : 'Could not get GPS location.';

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('🚨 EMERGENCY'),
        content: Text(
          'SOS Button Pressed!\n\n$locationText\n\n(Next step: send this to Firebase)',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SOS Pendant App')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                ElevatedButton(
                  onPressed: _startScan,
                  child: const Text('Start Scan'),
                ),
                if (_isConnected)
                  const Text(
                    "✅ Connected to Pendant. Waiting for button press...",
                    style: TextStyle(
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (_, i) {
                final r = _results[i];
                return ListTile(
                  title: Text(
                    r.advertisementData.advName.isEmpty
                        ? '(No Name)'
                        : r.advertisementData.advName,
                  ),
                  subtitle: Text('${r.device.remoteId}  RSSI: ${r.rssi}'),
                  trailing: const Icon(Icons.bluetooth),
                  onTap: () => _connectToDevice(r.device),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
