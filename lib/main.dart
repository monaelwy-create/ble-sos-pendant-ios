import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MaterialApp(home: BleScanPage()));
}

class BleScanPage extends StatefulWidget {
  const BleScanPage({super.key});
  @override
  State<BleScanPage> createState() => _BleScanPageState();
}

class _BleScanPageState extends State<BleScanPage> {
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<dynamic>? _connectionSubscription; // Fixed type
  StreamSubscription<List<int>>? _sosSubscription;

  bool _isConnected = false;
  String? _caregiverNumber;

  @override
  void initState() {
    super.initState();
    _loadCaregiverNumber();
    _startAutoScan();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _sosSubscription?.cancel();
    super.dispose();
  }

  // --- AUTO SCAN & AUTO CONNECT LOGIC ---
  void _startAutoScan() {
    _scanSubscription?.cancel(); // Cancel any existing scan listener

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        if (r.advertisementData.advName == "SOS_PENDANT") {
          debugPrint("Found Pendant! Connecting automatically...");
          FlutterBluePlus.stopScan();
          _connectToDevice(r.device);
          break;
        }
      }
    });

    FlutterBluePlus.startScan(timeout: const Duration(seconds: 30));

    _connectionSubscription = FlutterBluePlus.events.onConnectionStateChanged
        .listen((event) {
          // Check the state properly for newer package versions
          if (event.connectionState == BluetoothConnectionState.disconnected) {
            setState(() => _isConnected = false);
            debugPrint("Disconnected. Restarting auto-scan...");
            Future.delayed(const Duration(seconds: 2), () => _startAutoScan());
          }
        });
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect();
      setState(() => _isConnected = true);

      if (!mounted) return; // Fixed BuildContext warning
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Automatically Connected to Pendant!')),
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
                String message = String.fromCharCodes(value);
                if (message == "SOS") {
                  await _handleEmergency();
                }
              });
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Connection failed: $e');
      setState(() => _isConnected = false);
      Future.delayed(const Duration(seconds: 3), () => _startAutoScan());
    }
  }

  // --- CAREGIVER CONTACT LOGIC ---
  Future<void> _loadCaregiverNumber() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _caregiverNumber = prefs.getString('caregiver_number');
    });
  }

  Future<void> _pickContact() async {
    try {
      final status = await FlutterContacts.permissions.request(
        PermissionType.read,
      );
      if (status != PermissionStatus.granted) return;

      final contact = await FlutterContacts.native.showPicker(
        properties: {ContactProperty.phone},
      );

      if (contact != null && contact.phones.isNotEmpty) {
        String rawNumber = contact.phones.first.number.replaceAll(
          RegExp(r'[^\d+]'),
          '',
        );

        if (rawNumber.startsWith('0')) {
          rawNumber = '+20${rawNumber.substring(1)}';
        } else if (!rawNumber.startsWith('+')) {
          rawNumber = '+20$rawNumber';
        }

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('caregiver_number', rawNumber);

        setState(() => _caregiverNumber = rawNumber);

        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Caregiver saved: $rawNumber')));
      }
    } catch (e) {
      debugPrint("Error picking contact: $e");
    }
  }

  // --- EMERGENCY LOGIC ---
  Future<void> _handleEmergency() async {
    if (!mounted || _caregiverNumber == null) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Text("Getting location & sending alert..."),
          ],
        ),
      ),
    );

    Position? position = await _getLocation();

    try {
      String lat = position?.latitude.toString() ?? "Unknown";
      String lng = position?.longitude.toString() ?? "Unknown";
      String smsBody =
          'SOS! Emergency button pressed. Location: Lat $lat, Lng $lng';

      await FirebaseFirestore.instance.collection('sos_alerts').add({
        'to': _caregiverNumber,
        'body': smsBody,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint("Failed to send to Firestore: $e");
    }

    if (!mounted) return;
    Navigator.pop(context);

    _showSosDialog(position?.latitude, position?.longitude);
  }

  Future<Position?> _getLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return null;

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return null;
    }
    if (permission == LocationPermission.deniedForever) return null;

    return await Geolocator.getCurrentPosition();
  }

  void _showSosDialog(double? lat, double? lng) {
    String locationText = (lat != null && lng != null)
        ? 'Lat: $lat\nLng: $lng'
        : 'Could not get GPS location.';

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('🚨 EMERGENCY SENT'),
        content: Text(
          'SOS Button Pressed!\n\n$locationText\n\nAlert sent to caregiver.',
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
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_searching,
              size: 80,
              color: _isConnected ? Colors.green : Colors.orange,
            ),
            const SizedBox(height: 20),
            Text(
              _isConnected
                  ? "✅ Pendant Connected & Safe"
                  : "Searching for Pendant...",
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: _isConnected ? Colors.green : Colors.orange,
              ),
            ),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed: _pickContact,
              icon: const Icon(Icons.contact_phone),
              label: const Text('Select Caregiver from Contacts'),
            ),
            if (_caregiverNumber != null)
              Padding(
                padding: const EdgeInsets.only(top: 10.0),
                child: Text(
                  "Caregiver: $_caregiverNumber",
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
