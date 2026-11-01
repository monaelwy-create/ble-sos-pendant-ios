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

  @override
  void initState() {
    super.initState();
    // Listen for scan results
    FlutterBluePlus.onScanResults.listen((results) {
      setState(() => _results = results);
      for (final r in results) {
        debugPrint(
          'Found: ${r.device.remoteId} | ${r.advertisementData.advName}',
        );
      }
    });
  }

  Future<void> _startScan() async {
    if (await FlutterBluePlus.isSupported == false) return;
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BLE Scan')),
      body: Column(
        children: [
          ElevatedButton(
            onPressed: _startScan,
            child: const Text('Start Scan'),
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
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
