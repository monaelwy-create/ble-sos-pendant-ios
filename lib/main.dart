import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

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

  // FIX 1: Cancel the listener when the app is closed to prevent memory leaks
  @override
  void dispose() {
    _sosSubscription?.cancel();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (await FlutterBluePlus.isSupported == false) return;
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      await FlutterBluePlus.stopScan();
      await device.connect();

      setState(() => _isConnected = true);

      // FIX 2: Check if the screen is still open before using context
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

              _sosSubscription = characteristic.onValueReceived.listen((value) {
                String message = String.fromCharCodes(value);
                if (message == "SOS") {
                  _showSosDialog();
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

  void _showSosDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('🚨 EMERGENCY'),
        content: const Text(
          'The SOS button was pressed! Here is where we will trigger Firebase.',
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
