import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_contacts/flutter_contacts.dart'; // <-- New
import 'package:shared_preferences/shared_preferences.dart'; // <-- New

import 'firebase_options.dart';

const String kServiceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
const String kCharUuid = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
const String kPrefLastDevice = 'last_pendant_id';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // iOS: lets the system relaunch the app for the pendant if it was killed.
  FlutterBluePlus.setOptions(restoreState: true);
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
  StreamSubscription<BluetoothConnectionState>? _connSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterSubscription;
  BluetoothDevice? _device;
  bool _isConnected = false;
  bool _connectRequestInFlight = false;
  String _locationNote = '';
  String _status = 'Starting...';

  String? _caregiverNumber; // Stores the saved number

  @override
  void initState() {
    super.initState();
    FlutterBluePlus.onScanResults.listen((results) {
      setState(() => _results = results);
    });
    _loadCaregiverNumber(); // Load saved number on startup

    // Auto-connect: as soon as Bluetooth is on, reconnect to the saved pendant.
    _adapterSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        _autoConnect();
      } else if (mounted) {
        setState(() => _status = 'Bluetooth is ${state.name}. Turn it on.');
      }
    });
  }

  @override
  void dispose() {
    _sosSubscription?.cancel();
    _connSubscription?.cancel();
    _adapterSubscription?.cancel();
    super.dispose();
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  // --- AUTO CONNECT ---
  Future<void> _autoConnect() async {
    if (_isConnected) return;
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(kPrefLastDevice);
    if (id == null) {
      _setStatus('No saved pendant yet. Tap Start Scan and pick it once.');
      return;
    }
    _setStatus('Looking for saved pendant...');
    _connectToDevice(BluetoothDevice.fromId(id));
  }

  Future<void> _forgetPendant() async {
    final device = _device;
    _device = null;
    await _connSubscription?.cancel();
    await _sosSubscription?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kPrefLastDevice);
    try {
      await device?.disconnect();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _isConnected = false;
      _status = 'Pendant forgotten. Tap Start Scan to pick one.';
    });
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
    try {
      // 1. Request permission
      final status = await FlutterContacts.permissions.request(
        PermissionType.read,
      );

      if (status != PermissionStatus.granted) {
        debugPrint("Permission denied to read contacts. Status: $status");
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Permission to access contacts was denied.'),
          ),
        );
        return;
      }

      // 2. Open the native contact picker
      final contact = await FlutterContacts.native.showPicker(
        properties: {ContactProperty.phone},
      );
      // **************************
      if (contact != null && contact.phones.isNotEmpty) {
        // 1. Clean the number (remove spaces, dashes, etc.)
        String rawNumber = contact.phones.first.number.replaceAll(
          RegExp(r'[^\d+]'),
          '',
        );

        // 2. Format for Egypt (if it starts with '0', replace '0' with '+20')
        if (rawNumber.startsWith('0')) {
          rawNumber = '+20${rawNumber.substring(1)}';
        } else if (!rawNumber.startsWith('+')) {
          // If it's just digits without a 0, and no +, add +20
          rawNumber = '+20$rawNumber';
        }

        // 3. Save to phone memory
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('caregiver_number', rawNumber);

        setState(() {
          _caregiverNumber = rawNumber;
        });

        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Caregiver saved: $rawNumber')));
      }
    } catch (e) {
      // THIS will print the exact error to your debug console if it still fails
      debugPrint("Error picking contact: $e");
    }
  }
  // ----------------------------

  Future<void> _startScan() async {
    if (await FlutterBluePlus.isSupported == false) return;
    // The adapter state can still read 'unknown' for a moment after launch,
    // so wait for 'on' instead of checking a single snapshot.
    try {
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      final st = FlutterBluePlus.adapterStateNow;
      _setStatus(
        st == BluetoothAdapterState.unauthorized
            ? 'Bluetooth permission is off. Settings > this app > Bluetooth.'
            : 'Bluetooth state: ${st.name}. Check Settings > Bluetooth.',
      );
      return;
    }
    _setStatus('Scanning...');
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
  }

  Future<Position?> _getLocation() async {
    // Never throws. Waits long enough for a cold GPS fix, then falls back.
    _locationNote = '';
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _locationNote = 'location services are off';
        return null;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _locationNote = 'location permission denied';
        return null;
      }

      final lastKnown = await Geolocator.getLastKnownPosition();

      try {
        return await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 12),
          ),
        );
      } catch (_) {}

      try {
        // Quicker, coarser fix if the precise one timed out.
        return await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 4),
          ),
        );
      } catch (_) {}

      if (lastKnown == null) {
        _locationNote = 'no GPS fix, permission: ${permission.name}';
      }
      return lastKnown;
    } catch (e) {
      _locationNote = 'location error';
      return null;
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      await FlutterBluePlus.stopScan();

      // Switching pendants: cancel the old pending connection.
      final old = _device;
      if (old != null && old.remoteId != device.remoteId) {
        try {
          await old.disconnect();
        } catch (_) {}
      }
      _device = device;
      _setStatus('Waiting for pendant...');

      // One listener drives everything. Its first event is the current state,
      // so it also issues the first connect request.
      await _connSubscription?.cancel();
      _connSubscription = device.connectionState.listen((state) async {
        if (state == BluetoothConnectionState.connected) {
          if (mounted) setState(() => _isConnected = true);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(kPrefLastDevice, device.remoteId.str);
          await _setupSos(device);
        } else if (state == BluetoothConnectionState.disconnected) {
          await _sosSubscription?.cancel();
          _sosSubscription = null;
          if (mounted) {
            setState(() {
              _isConnected = false;
              _status = 'Disconnected. Waiting for pendant...';
            });
          }
          _requestConnect(device);
        }
      });
    } catch (e) {
      debugPrint('Connection setup failed: $e');
      _setStatus('Connection setup failed: $e');
    }
  }

  // autoConnect = iOS keeps this request pending natively (no timeout) and
  // wakes the app when the pendant shows up, even if the app is suspended.
  Future<void> _requestConnect(BluetoothDevice device) async {
    if (_connectRequestInFlight) return;
    _connectRequestInFlight = true;
    try {
      await device.connect(autoConnect: true, mtu: null);
    } catch (e) {
      debugPrint('Connect request failed: $e');
      _setStatus('Connect request failed: $e');
    } finally {
      _connectRequestInFlight = false;
    }
  }

  Future<void> _setupSos(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      var found = false;
      for (var service in services) {
        if (service.uuid.toString().toUpperCase() != kServiceUuid) continue;
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString().toUpperCase() != kCharUuid) {
            continue;
          }
          await characteristic.setNotifyValue(true);
          await _sosSubscription?.cancel();
          _sosSubscription = characteristic.onValueReceived.listen((
            value,
          ) async {
            final message = String.fromCharCodes(value).trim();
            if (message == "SOS") {
              await _handleEmergency();
            }
          });
          found = true;
        }
      }
      _setStatus(
        found
            ? 'Connected to pendant. Waiting for button press...'
            : 'Connected, but SOS service/characteristic not found.',
      );
    } catch (e) {
      debugPrint('Service setup failed: $e');
      _setStatus('Service setup failed: $e');
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
      String smsBody = position != null
          ? 'SOS! The pendant button was pressed. Location: Lat $lat, Lng $lng'
          : 'SOS! The pendant button was pressed. Location: Unknown ($_locationNote)';

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
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    _isConnected ? "✅ $_status" : _status,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _isConnected ? Colors.green : Colors.black87,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (_device != null)
                  TextButton(
                    onPressed: _forgetPendant,
                    child: const Text('Forget pendant'),
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
