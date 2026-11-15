import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  StreamSubscription<Position>? _positionStreamSubscription; // Background GPS

  BluetoothDevice? _device;
  bool _isConnected = false;
  bool _connectRequestInFlight = false;
  String _locationNote = '';
  String _status = 'Starting...';

  String? _caregiverNumber;

  @override
  void initState() {
    super.initState();

    _startBackgroundLocationTracking(); // Keep GPS warm

    FlutterBluePlus.onScanResults.listen((results) {
      setState(() => _results = results);
    });
    _loadCaregiverNumber();

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
    _positionStreamSubscription?.cancel(); // Stop background GPS
    super.dispose();
  }

  void _setStatus(String s) {
    if (mounted) setState(() => _status = s);
  }

  // --- BACKGROUND GPS TRACKING ---
  void _startBackgroundLocationTracking() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return;
      }
      if (permission == LocationPermission.deniedForever) return;

      _positionStreamSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            ),
          ).listen((Position position) {
            debugPrint(
              "Background GPS warm: ${position.latitude}, ${position.longitude}",
            );
          });
    } catch (e) {
      debugPrint("Error starting background GPS: $e");
    }
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

  Future<void> _pickContact() async {
    try {
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

        setState(() {
          _caregiverNumber = rawNumber;
        });

        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Caregiver saved: $rawNumber')));
      }
    } catch (e) {
      debugPrint("Error picking contact: $e");
    }
  }

  // ====================================================
  // --- SCANNING & CONNECTION ---
  Future<void> _startScan() async {
    if (await FlutterBluePlus.isSupported == false) return;
    try {
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 10));
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

    // FIXED: Scan specifically for the ESP32's Service UUID
    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 15),
      withNames: ["SOS_PENDANT"],
    );
  }

  // ============================================================
  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      await FlutterBluePlus.stopScan();

      final old = _device;
      if (old != null && old.remoteId != device.remoteId) {
        try {
          await old.disconnect();
        } catch (_) {}
      }
      _device = device;
      _setStatus('Waiting for pendant...');

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

  // ======================================================
  Future<Position?> _getLocation() async {
    _locationNote = '';
    try {
      // 1. Check if Location Services is globally ON
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _locationNote = 'Location Services are OFF in iPhone Settings';
        return null;
      }

      // 2. Check App Permissions
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _locationNote = 'Permission Denied by User';
        return null;
      }

      // 3. Grab Last Known (Works instantly even if GPS is asleep)
      Position? lastKnown = await Geolocator.getLastKnownPosition();

      // 4. Try for a fresh, highly accurate fix
      try {
        final fresh = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 15),
          ),
        );
        return fresh; // Success! Return immediately
      } catch (e) {
        // If it fails, we don't stop. We just log it and try the fallback.
        _locationNote = 'Fresh GPS Timed Out. ';
      }

      // 5. If fresh failed, use Last Known
      if (lastKnown != null) {
        _locationNote += 'Used Last Known Location. ';
        return lastKnown;
      }

      // 6. If BOTH failed, this is the worst-case scenario
      _locationNote += 'Last Known was also NULL. iOS is blocking location.';
      return null;
    } catch (e) {
      _locationNote = 'Exception: $e';
      return null;
    }
  }

  // ===========================================================
  Future<void> _handleEmergency() async {
    if (!mounted) return;

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
        'to': _caregiverNumber,
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

  // --- UI DIALOGS ---
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

  // --- BUILD UI ---
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
