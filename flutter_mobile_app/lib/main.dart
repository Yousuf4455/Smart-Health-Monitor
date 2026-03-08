
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MaterialApp(home: HealthMonitorApp()));
}

class HealthMonitorApp extends StatefulWidget {
  const HealthMonitorApp({super.key});

  @override
  State<HealthMonitorApp> createState() => _HealthMonitorAppState();
}

class _HealthMonitorAppState extends State<HealthMonitorApp> {
  final String SERVICE_UUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String DATA_CHAR_UUID = "beb5483e-36e1-4688-b7f5-ea07361b26a8";
  final String ALERT_CHAR_UUID = "88924aee-2342-4357-939e-29367c345173";
  final String CONTROL_CHAR_UUID = "12345678-1234-1234-1234-1234567890ab";

  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? controlCharacteristic;
  
  String connectionStatus = "Bağlı Değil";
  
  // --- DEĞİŞKENLER ---
  String currentBPM = "--";
  String currentSpO2 = "--";
  
  // Varsayılan slider değerleri (50 - 120 arası)
  RangeValues _currentRangeValues = const RangeValues(50, 120);
  
  bool isMonitoringActive = false;
  List<String> eventLog = [];

  // Ardışık bildirimleri engellemek için zamanlayıcı (Önceki konuşmamızdan)
  DateTime? lastAlertTime; 
  String lastAlertMsg = "";

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  void _scanAndConnect() async {
    setState(() => connectionStatus = "Taranıyor...");
    
    if (FlutterBluePlus.isScanningNow) {
       await FlutterBluePlus.stopScan();
    }

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));

    FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        // Cihaz ismini buradan kontrol ediyoruz
        if (r.device.platformName == "bileklikProje" || r.device.platformName == "BileklikProje" ) { 
          await FlutterBluePlus.stopScan();
          _connectToDevice(r.device);
          break;
        }
      }
    });
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() => connectionStatus = "Bağlanıyor...");
    
    try {
      await device.connect(autoConnect: true);
      // BAĞLANTI DURUMUNU SÜREKLİ DİNLE
      // Bu, bağlantı koptuğunda veya geri geldiğinde tetiklenir.
      device.connectionState.listen((BluetoothConnectionState state) {
        if (state == BluetoothConnectionState.disconnected) {
            // Bağlantı koptuysa
            setState(() {
                connectionStatus = "Bağlantı Koptu! Tekrar aranıyor...";
                connectedDevice = null; // Cihazı null yap ki arayüz güncellensin
            });
            // Not: autoConnect: true olduğu için biz bir şey yapmasak da 
            // kütüphane alttan alttan bağlanmaya çalışacaktır.
        } 
        else if (state == BluetoothConnectionState.connected) {
            // Bağlantı geri geldiyse
            setState(() {
                connectionStatus = "Bağlandı: ${device.platformName}";
                connectedDevice = device;
            });
        }
      });

      List<BluetoothService> services = await device.discoverServices();
      for (var service in services) {
        if (service.uuid.toString() == SERVICE_UUID) {
          for (var characteristic in service.characteristics) {
            
            // 1. Veri Karakteristiği (Nabız ve SpO2)
            if (characteristic.uuid.toString() == DATA_CHAR_UUID) {
              await characteristic.setNotifyValue(true);
              characteristic.onValueReceived.listen((value) {
                String rawData = utf8.decode(value); 
                List<String> parts = rawData.split(','); 
                
                if(parts.length == 2) {
                    setState(() {
                        currentBPM = parts[0];   
                        currentSpO2 = parts[1];  
                    });
                }
              });
            }

            // 2. Uyarı Karakteristiği (Alarm)
            if (characteristic.uuid.toString() == ALERT_CHAR_UUID) {
              await characteristic.setNotifyValue(true);
              characteristic.onValueReceived.listen((value) {
                String alert = utf8.decode(value);
                _addLog(alert);
                _showAlertPopup(alert);
              });
            }

            // 3. Kontrol Karakteristiği (Start/Stop/Limit)
            if (characteristic.uuid.toString() == CONTROL_CHAR_UUID) {
              controlCharacteristic = characteristic;
            }
          }
        }
      }
    } catch (e) {
      setState(() => connectionStatus = "Hata: $e");
    }
  }

  Future<void> _toggleSystem(bool active) async {
    if (controlCharacteristic == null) return;
    
    String command = active ? "START" : "STOP";
    await controlCharacteristic!.write(utf8.encode(command));
    
    setState(() {
      isMonitoringActive = active;
      if(!active) {
        currentBPM = "--";
        currentSpO2 = "--";
      }
    });
  }

  // --- YENİ EKLENEN FONKSİYON 1: LİMİTLERİ ESP32'YE GÖNDER ---
  Future<void> _sendLimitsToESP() async {
    if (controlCharacteristic == null) return;
    
    int min = _currentRangeValues.start.round();
    int max = _currentRangeValues.end.round();
    
    // Protokolümüz: "LIMITS:50,120"
    String command = "LIMITS:$min,$max";
    
    await controlCharacteristic!.write(utf8.encode(command));
    print("Giden Komut: $command");
  }
  // -----------------------------------------------------------

  void _addLog(String message) {
    // Spam engelleme (Flutter tarafı)
    DateTime now = DateTime.now();
    if (message == lastAlertMsg && lastAlertTime != null) {
      if (now.difference(lastAlertTime!).inSeconds < 3) {
        return; // 3 saniyeden kısa sürede aynı mesaj geldiyse yok say
      }
    }
    lastAlertTime = now;
    lastAlertMsg = message;

    String timeStr = DateFormat('HH:mm:ss').format(now);
    String readableMsg = "";
    
    if(message == "DUSME_ALGILANDI") {
        readableMsg = "⚠️ Düşme Tespit Edildi!";
    }else if(message == "HAREKETSIZLIK") {
        readableMsg = "🛑 Kullanıcı 2 Dakikadır Hareketsiz!"; 
    } else if(message == "NABIZ_YUKSEK") {
        readableMsg = "❤️ Nabız Çok Yüksek!";
    } else if(message == "NABIZ_DUSUK") {
        readableMsg = "💙 Nabız Çok Düşük!";
    } else if(message == "ACIL_BUTON") {
        readableMsg = "🆘 ACİL BUTONA BASILDI!";
    } else if(message == "SENSOR_HATA") {
        readableMsg = "❌ Sensör Bağlantısı Koptu";
    } else {
        readableMsg = message;
    }

    setState(() {
      eventLog.insert(0, "[$timeStr] $readableMsg");
    });
  }

  void _showAlertPopup(String msg) {
    showDialog(
      context: context, 
      builder: (ctx) => AlertDialog(
        title: const Text("ACİL DURUM UYARISI"),
        content: Text(msg),
        backgroundColor: Colors.red.shade100,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Tamam"))
        ],
      )
    );
  }

  // --- YENİ EKLENEN FONKSİYON 2: AYARLAR PENCERESİ ---
  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder( 
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("Nabız Eşik Ayarları"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("Güvenli Nabız Aralığını Seçin:"),
                  const SizedBox(height: 20),
                  RangeSlider(
                    values: _currentRangeValues,
                    min: 40,
                    max: 200,
                    divisions: 160,
                    labels: RangeLabels(
                      _currentRangeValues.start.round().toString(),
                      _currentRangeValues.end.round().toString(),
                    ),
                    onChanged: (RangeValues values) {
                      // Dialog içindeki state'i güncelle
                      setDialogState(() {
                        _currentRangeValues = values;
                      });
                      // Ana ekranın state'ini de güncelle (Opsiyonel ama iyi olur)
                      setState(() {
                         _currentRangeValues = values;
                      });
                    },
                  ),
                  Text(
                    "Min: ${_currentRangeValues.start.round()} - Max: ${_currentRangeValues.end.round()}",
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("İptal"),
                ),
                ElevatedButton(
                  onPressed: () {
                    // ESP32'ye Gönder
                    _sendLimitsToESP();
                    Navigator.pop(context);
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(content: Text("Yeni ayarlar cihaza gönderildi!")),
                    );
                  },
                  child: const Text("Kaydet"),
                ),
              ],
            );
          },
        );
      },
    );
  }
  // ----------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // --- AppBar GÜNCELLENDİ (Settings İkonu Eklendi) ---
      appBar: AppBar(
        title: const Text("Sağlık Monitörü"), 
        backgroundColor: Colors.teal,
        actions: [
          // Sadece cihaz bağlıysa ayar butonunu göster
          if(connectedDevice != null)
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: _showSettingsDialog,
            )
        ],
      ),
      // --------------------------------------------------
      
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            // Durum Paneli
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(10)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(Icons.bluetooth, color: connectedDevice != null ? Colors.blue : Colors.grey),
                  Text(connectionStatus, style: const TextStyle(fontWeight: FontWeight.bold)),
                  if (connectedDevice == null)
                    ElevatedButton(onPressed: _scanAndConnect, child: const Text("Bağlan"))
                ],
              ),
            ),
            const SizedBox(height: 20),

            // --- GÖSTERGE PANELİ ---
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // 1. NABIZ GÖSTERGESİ
                Column(
                  children: [
                    CircleAvatar(
                      radius: 50,
                      backgroundColor: isMonitoringActive ? Colors.redAccent : Colors.grey,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.favorite, size: 30, color: Colors.white),
                          Text(currentBPM, style: const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text("BPM", style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),

                // 2. SpO2 GÖSTERGESİ
                Column(
                  children: [
                    CircleAvatar(
                      radius: 50,
                      backgroundColor: isMonitoringActive ? Colors.blueAccent : Colors.grey,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.water_drop, size: 30, color: Colors.white),
                          Text("%$currentSpO2", style: const TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text("SpO2", style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
            // ------------------------------------------------

            const SizedBox(height: 30),

            // Başlat / Durdur Switch
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("Sistem Kapalı", style: TextStyle(fontSize: 16)),
                Switch(
                  value: isMonitoringActive, 
                  onChanged: (val) {
                    if(connectedDevice != null) _toggleSystem(val);
                  }
                ),
                const Text("Sistem Açık", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            const Divider(height: 40),

            // Log Listesi
            const Align(alignment: Alignment.centerLeft, child: Text("Olay Kayıtları:", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            Expanded(
              child: ListView.builder(
                itemCount: eventLog.length,
                itemBuilder: (ctx, index) => Card(
                  color: eventLog[index].contains("🆘") ? Colors.red.shade50 : Colors.white,
                  child: ListTile(
                    title: Text(eventLog[index]),
                    leading: const Icon(Icons.history),
                  ),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}