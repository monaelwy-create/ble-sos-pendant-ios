import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_contacts/flutter_contacts.dart'; // <-- New
import 'package:shared_preferences/shared_preferences.dart'; // <-- New

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
  List<ScanResult> _results = [];
  StreamSubscription<List<int>>? _sosSubscription;
  bool _isConnected = false;

  String? _caregiverNumber; // Stores the saved number

  @override
  void initState() {
    super.initState();
    FlutterBluePlus.onScanResults.listen((results) {
      setState(() => _results = results);
    });
    _loadCaregiverNumber(); // Load saved number on startup
  }

  @override
  void dispose() {
    _sosSubscription?.cancel();
    super.dispose();
  }

  // --- CONTACT & SAVE LOGIC ---
  Future<void> _loadCaregiverNumber() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _caregiverNumber = prefs.getString('caregiver_number');
    });
  }

  // ================================================================
  Future<void> _pickContact() async {
    // 1. Request permission using the new API
    final status = await FlutterContacts.permissions.request(
      PermissionType.read,
    );
    if (status != PermissionStatus.granted) {
      debugPrint("Permission denied to read contacts");
      return;
    }

    // 2. Open the native contact picker (new API method)
    // The showPicker method returns the selected Contact directly
    final contact = await FlutterContacts.native.showPicker(
      properties: {ContactProperty.phone}, // We only need the phone number
    );

    if (contact != null) {
      if (contact.phones.isNotEmpty) {
        // 3. Clean the number and add '+' if missing (E.164 format)
        String rawNumber = contact.phones.first.number.replaceAll(
          RegExp(r'[^\d+]'),
          '',
        );
        if (!rawNumber.startsWith('+')) {
          rawNumber = '+$rawNumber';
        }

        // 4. Save to phone memory
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('caregiver_number', rawNumber);

        setState(() {
          _caregiverNumber = rawNumber;
        });

        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Caregiver saved: $rawNumber')));
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Selected contact has no phone number.'),
          ),
        );
      }
    }
  }
  // ----------------------------

  Future<void> _startScan() async {
    if (await FlutterBluePlus.isSupported == false) return;
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
  }

  Future<Position?> _getLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return null;

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return null;
    }
    if (permission == LocationPermission.deniedForever) return null;

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
    }
  }

  Future<void> _handleEmergency() async {
    if (!mounted) return;

    // Safety check: Make sure a caregiver is saved
    if (_caregiverNumber == null || _caregiverNumber!.isEmpty) {
      _showErrorDialog(
        "No caregiver number saved. Please select one from contacts first.",
      );
      return;
    }

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
          'SOS! The pendant button was pressed. Location: Lat $lat, Lng $lng';

      await FirebaseFirestore.instance.collection('sos_alerts').add({
        'to': _caregiverNumber, // <-- Uses the saved contact number!
        'body': smsBody,
        'timestamp': FieldValue.serverTimestamp(),
      });

      debugPrint("SOS Alert triggered Twilio SMS!");
    } catch (e) {
      debugPrint("Failed to send to Firestore: $e");
    }

    if (!mounted) return;
    Navigator.pop(context);

    _showSosDialog(position?.latitude, position?.longitude);
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

  void _showErrorDialog(String msg) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Error'),
        content: Text(msg),
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
                // --- NEW: Contact Picker Button ---
                ElevatedButton.icon(
                  onPressed: _pickContact,
                  icon: const Icon(Icons.contact_phone),
                  label: const Text('Select Caregiver from Contacts'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade100,
                    foregroundColor: Colors.blue.shade900,
                  ),
                ),
                if (_caregiverNumber != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
                    child: Text(
                      "Caregiver: $_caregiverNumber",
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                      ),
                    ),
                  ),
                // ----------------------------------
                const Divider(),
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
