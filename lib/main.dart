import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

// --- MAIN ENTRY POINT ---
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize the background service
  await initializeService();

  runApp(const MyApp());
}

// --- BACKGROUND SERVICE CONFIGURATION ---
Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  // Android Notification Setup
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'ble_foreground',
    'BLE Background Service',
    description: 'This channel is used for BLE background service.',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  if (Platform.isAndroid) {
    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'ble_foreground',
      initialNotificationTitle: 'BLE Service',
      initialNotificationContent: 'Initializing...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

// Entry point for the background isolate
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });

    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });

    // Handle notification content updates
    service.on('updateContent').listen((event) {
      if (event != null && event['message'] != null) {
        if (service is AndroidServiceInstance) {
          service.setForegroundNotificationInfo(
            title: "BLE Manager",
            content: "Last: ${event['message']}",
          );
        }
      }
    });
  }

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // Keep the isolate alive with periodic updates
  Timer.periodic(const Duration(seconds: 5), (timer) async {
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: "BLE Manager",
          content: "Maintaining connection...",
        );
        // Service is running - you can add heartbeat logic here
      }
    }
  });
}

@pragma('vm:entry-point')
bool onIosBackground(ServiceInstance service) {
  WidgetsFlutterBinding.ensureInitialized();
  return true;
}

// --- BLE LOGIC SINGLETON ---
class BLEManager extends ChangeNotifier {
  static final BLEManager _instance = BLEManager._internal();
  factory BLEManager() => _instance;
  BLEManager._internal();

  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? notifyCharacteristic;
  StreamSubscription<List<int>>? characteristicSubscription;
  StreamSubscription<BluetoothConnectionState>? connectionStateSubscription;

  final ValueNotifier<List<MessageData>> messagesNotifier = ValueNotifier([]);
  final ValueNotifier<String> statusNotifier = ValueNotifier('Ready to scan');
  final ValueNotifier<ConnectionStatus> connectionStatusNotifier =
      ValueNotifier(ConnectionStatus.disconnected);

  Future<void> connect(BluetoothDevice device) async {
    statusNotifier.value = 'Connecting...';
    connectionStatusNotifier.value = ConnectionStatus.connecting;

    try {
      // Listen to connection state changes
      connectionStateSubscription?.cancel();
      connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _handleDisconnection();
        }
      });

      // Connect with autoConnect for background reconnection
      await device.connect(
        timeout: const Duration(seconds: 15),
        // autoConnect: true,
      );

      connectedDevice = device;
      connectionStatusNotifier.value = ConnectionStatus.connected;
      statusNotifier.value = 'Connected';

      // Start the Background Service
      final service = FlutterBackgroundService();
      if (!await service.isRunning()) {
        await service.startService();
      }
      service.invoke('setAsForeground');
      // Set initial notification content
      service.invoke('updateContent', {"message": "Connected to device"});
      await _discoverServices(device);
      notifyListeners();
    } catch (e) {
      statusNotifier.value = 'Connection failed: ${e.toString()}';
      connectionStatusNotifier.value = ConnectionStatus.disconnected;
      connectedDevice = null;
      notifyListeners();
    }
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    try {
      List<BluetoothService> services = await device.discoverServices();

      // Priority 1: Look for your specific service/characteristic
      for (var service in services) {
        String serviceUuid = service.uuid.toString().toUpperCase();
        if (serviceUuid.contains('ABF0') || serviceUuid.contains('0000ABF0')) {
          for (var characteristic in service.characteristics) {
            String charUuid = characteristic.uuid.toString().toUpperCase();
            if (charUuid.contains('ABF2') || charUuid.contains('0000ABF2')) {
              await _subscribe(characteristic);
              return;
            }
          }
        }
      }

      // Priority 2: Find any notify/indicate characteristic
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.properties.notify ||
              characteristic.properties.indicate) {
            await _subscribe(characteristic);
            return;
          }
        }
      }

      statusNotifier.value = 'No data channel found';
    } catch (e) {
      statusNotifier.value = 'Service discovery failed: ${e.toString()}';
    }
  }

  Future<void> _subscribe(BluetoothCharacteristic characteristic) async {
    try {
      notifyCharacteristic = characteristic;
      await characteristic.setNotifyValue(true);

      characteristicSubscription?.cancel();
      characteristicSubscription = characteristic.lastValueStream.listen(
        (value) {
          if (value.isNotEmpty) {
            try {
              String message = utf8.decode(value, allowMalformed: true).trim();
              print('BLE Received: $message');

              // Add to message list
              final currentMsgs =
                  List<MessageData>.from(messagesNotifier.value);
              currentMsgs.insert(
                0,
                MessageData(message: message, timestamp: DateTime.now()),
              );

              // Keep only last 100 messages to prevent memory issues
              if (currentMsgs.length > 100) {
                currentMsgs.removeRange(100, currentMsgs.length);
              }

              messagesNotifier.value = currentMsgs;

              // Update notification
              FlutterBackgroundService().invoke(
                "updateContent",
                {"message": message},
              );
            } catch (e) {
              print('Error decoding message: $e');
            }
          }
        },
        onError: (error) {
          print('Characteristic stream error: $error');
          statusNotifier.value = 'Data stream error';
        },
      );

      statusNotifier.value = 'Listening for data';
    } catch (e) {
      statusNotifier.value = 'Subscribe failed: ${e.toString()}';
    }
  }

  void _handleDisconnection() {
    connectionStatusNotifier.value = ConnectionStatus.disconnected;
    statusNotifier.value = 'Device disconnected';

    characteristicSubscription?.cancel();
    connectionStateSubscription?.cancel();

    connectedDevice = null;
    notifyCharacteristic = null;

    // Stop background service
    final service = FlutterBackgroundService();
    service.invoke("stopService");

    notifyListeners();
  }

  Future<void> disconnect() async {
    if (connectedDevice != null) {
      await characteristicSubscription?.cancel();
      await connectionStateSubscription?.cancel();

      try {
        await connectedDevice!.disconnect();
      } catch (e) {
        print('Disconnect error: $e');
      }

      connectedDevice = null;
      notifyCharacteristic = null;
      connectionStatusNotifier.value = ConnectionStatus.disconnected;
      statusNotifier.value = 'Disconnected';

      // Stop background service
      final service = FlutterBackgroundService();
      service.invoke("stopService");

      notifyListeners();
    }
  }

  void clearMessages() {
    messagesNotifier.value = [];
  }
}

// --- DATA MODELS ---
class MessageData {
  final String message;
  final DateTime timestamp;
  MessageData({required this.message, required this.timestamp});
}

enum ConnectionStatus { disconnected, connecting, connected }

// --- UI WIDGETS ---
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Device Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2196F3)),
        useMaterial3: true,
      ),
      home: const BLEHomePage(),
    );
  }
}

class BLEHomePage extends StatefulWidget {
  const BLEHomePage({super.key});

  @override
  State<BLEHomePage> createState() => _BLEHomePageState();
}

class _BLEHomePageState extends State<BLEHomePage>
    with SingleTickerProviderStateMixin {
  final BLEManager _bleManager = BLEManager();

  List<ScanResult> scanResults = [];
  bool isScanning = false;
  late AnimationController _pulseController;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _requestPermissions();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _scanSubscription?.cancel();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    try {
      if (Platform.isAndroid) {
        await Permission.notification.request();
        await Permission.bluetoothScan.request();
        await Permission.bluetoothConnect.request();
        await Permission.location.request();
      } else if (Platform.isIOS) {
        await Permission.bluetooth.request();
      }
    } catch (e) {
      print('Permission request error: $e');
    }
  }

  Future<void> startScan() async {
    setState(() {
      scanResults.clear();
      isScanning = true;
      _bleManager.statusNotifier.value = 'Scanning...';
    });

    try {
      // Cancel existing subscription
      _scanSubscription?.cancel();

      // Start scanning
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15),
        androidUsesFineLocation: true,
      );

      // Listen to scan results
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        if (mounted) {
          setState(() {
            scanResults = results;
            // Sort by signal strength
            scanResults.sort((a, b) => b.rssi.compareTo(a.rssi));
          });
        }
      });

      // Wait for scan to complete
      await Future.delayed(const Duration(seconds: 15));
      await FlutterBluePlus.stopScan();

      if (mounted) {
        setState(() {
          isScanning = false;
          _bleManager.statusNotifier.value =
              scanResults.isEmpty ? 'No devices found' : 'Scan complete';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isScanning = false;
          _bleManager.statusNotifier.value = 'Scan failed: ${e.toString()}';
        });
      }
      print('Scan error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text('BLE Background Manager'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        actions: [
          ValueListenableBuilder<ConnectionStatus>(
            valueListenable: _bleManager.connectionStatusNotifier,
            builder: (context, status, _) {
              if (status == ConnectionStatus.connected) {
                return IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    _bleManager.clearMessages();
                  },
                  tooltip: 'Clear messages',
                );
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusCard(),
          const SizedBox(height: 8),
          _buildActionButtons(),
          const SizedBox(height: 8),
          Expanded(
            child: ValueListenableBuilder<ConnectionStatus>(
              valueListenable: _bleManager.connectionStatusNotifier,
              builder: (context, status, child) {
                if (status == ConnectionStatus.connected) {
                  return _buildMessageList();
                } else {
                  return _buildDeviceList();
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    return ValueListenableBuilder<ConnectionStatus>(
      valueListenable: _bleManager.connectionStatusNotifier,
      builder: (context, status, _) {
        return Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: status == ConnectionStatus.connected
                  ? [Colors.green.shade400, Colors.green.shade600]
                  : status == ConnectionStatus.connecting
                      ? [Colors.orange.shade400, Colors.orange.shade600]
                      : [Colors.grey.shade400, Colors.grey.shade600],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  final scale = status == ConnectionStatus.connecting
                      ? 1.0 + (_pulseController.value * 0.2)
                      : 1.0;
                  return Transform.scale(
                    scale: scale,
                    child: Icon(
                      status == ConnectionStatus.connected
                          ? Icons.bluetooth_connected
                          : status == ConnectionStatus.connecting
                              ? Icons.bluetooth_searching
                              : Icons.bluetooth_disabled,
                      color: Colors.white,
                      size: 32,
                    ),
                  );
                },
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status == ConnectionStatus.connected
                          ? 'Connected'
                          : status == ConnectionStatus.connecting
                              ? 'Connecting...'
                              : 'Not Connected',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ValueListenableBuilder<String>(
                      valueListenable: _bleManager.statusNotifier,
                      builder: (ctx, msg, _) => Text(
                        msg,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.9),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActionButtons() {
    return ValueListenableBuilder<ConnectionStatus>(
      valueListenable: _bleManager.connectionStatusNotifier,
      builder: (context, status, _) {
        if (status == ConnectionStatus.disconnected) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: isScanning ? null : startScan,
                icon: Icon(isScanning ? Icons.hourglass_empty : Icons.search),
                label: Text(isScanning ? 'Scanning...' : 'Scan for Devices'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          );
        } else {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: status == ConnectionStatus.connecting
                    ? null
                    : () => _bleManager.disconnect(),
                icon: const Icon(Icons.bluetooth_disabled),
                label: const Text('Disconnect'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          );
        }
      },
    );
  }

  Widget _buildDeviceList() {
    if (scanResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bluetooth_searching,
                size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              isScanning ? 'Scanning for devices...' : 'No devices found',
              style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
            ),
            if (!isScanning) ...[
              const SizedBox(height: 8),
              Text(
                'Tap "Scan for Devices" to start',
                style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
              ),
            ],
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: scanResults.length,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemBuilder: (context, index) {
        final result = scanResults[index];
        final deviceName = result.device.platformName.isNotEmpty
            ? result.device.platformName
            : "Unknown Device";
        final signalStrength = result.rssi;

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: ListTile(
            leading: Icon(
              Icons.bluetooth,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(
              deviceName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              result.device.remoteId.toString(),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Icon(
                  signalStrength > -70
                      ? Icons.signal_wifi_4_bar
                      : signalStrength > -85
                          ? Icons.wifi_rounded
                          : Icons.wifi_2_bar,
                  size: 20,
                  color: signalStrength > -70
                      ? Colors.green
                      : signalStrength > -85
                          ? Colors.orange
                          : Colors.red,
                ),
                const SizedBox(height: 2),
                Text(
                  "$signalStrength dBm",
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
            onTap: () => _bleManager.connect(result.device),
          ),
        );
      },
    );
  }

  Widget _buildMessageList() {
    return ValueListenableBuilder<List<MessageData>>(
      valueListenable: _bleManager.messagesNotifier,
      builder: (context, messages, _) {
        if (messages.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.inbox, size: 64, color: Colors.grey.shade400),
                const SizedBox(height: 16),
                Text(
                  'Waiting for data...',
                  style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Messages will appear here when received',
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          itemCount: messages.length,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemBuilder: (context, index) {
            final msg = messages[index];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child:
                      const Icon(Icons.message, color: Colors.white, size: 20),
                ),
                title: Text(
                  msg.message,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                subtitle: Text(
                  _formatTimestamp(msg.timestamp),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inSeconds < 60) {
      return 'Just now';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}h ago';
    } else {
      return '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    }
  }
}
