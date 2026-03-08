# 🩺 Smart Health & Safety Monitor (Wearable IoT System)

This project is an end-to-end IoT health monitoring system designed for the elderly, patients, or lone workers. It consists of an **ESP32**-based wearable hardware device and a **Flutter**-based mobile application. The system communicates in real-time via Bluetooth Low Energy (BLE).

## 🌟 Key Features

### 📟 Wearable Device (ESP32) Features
* **Real-Time Heart Rate & SpO2:** Measured using the MAX30100 sensor.
* **Fall Detection:** Detects sudden falls (vectorial acceleration > 15G) using the MPU6050 accelerometer.
* **Inactivity Alert:** Generates an alarm if the user remains completely motionless for 2 minutes.
* **SOS Emergency Button:** A physical push-button to instantly send an emergency signal to the mobile app.
* **Smart Power Saving (Standby Mode):** When switched to "System Off" via the app, the live data streaming stops to save battery, but *Fall, Inactivity, and SOS* checks continue running in the background. The system automatically wakes up and sends an alert in an emergency.
* **Fault Tolerance (Auto-Recovery):** Detects physical disconnections of the I2C sensors and safely restarts the initialization process without freezing when the connection is restored.

### 📱 Mobile Application (Flutter) Features
* **Auto-Connect:** If the device goes out of range and disconnects, the app continues scanning in the background and instantly resumes the data stream once the device is back in range.
* **Live Dashboard:** Displays real-time BPM and SpO2 values with a clean and responsive UI.
* **Dynamic Threshold Settings:** Safe heart rate ranges (e.g., 50-120 BPM) can be adjusted from the settings menu and instantly transmitted to the ESP32 via BLE.
* **Event Logs:** All received emergency alerts and sensor errors are recorded in a scrollable list with timestamps.
* **Visual Emergency Alerts:** Displays red pop-up warnings on the screen in case of falls, abnormal heart rates, or SOS events.

---

## 🛠️ Technologies Used

* **Hardware:** ESP32 (Microcontroller), MPU6050 (Accelerometer/Gyroscope), MAX30100 (Pulse Oximeter)
* **Firmware:** C++ (Arduino IDE / PlatformIO), ESP32 BLE Libraries
* **Mobile App:** Flutter, Dart, `flutter_blue_plus`

---

## 🔌 Circuit Diagram & Pinout

| ESP32 Pin | Component / Sensor | Function |
| :--- | :--- | :--- |
| **GPIO 23** | MPU6050 & MAX30100 | I2C SDA (Data) |
| **GPIO 21** | MPU6050 & MAX30100 | I2C SCL (Clock) |
| **GPIO 18** | Push Button | SOS / Emergency (INPUT_PULLUP) |
| **GPIO 2** | LED | System Active / Standby Indicator |
| **3.3V / VIN**| All Sensors | VCC Power Supply |
| **GND** | All Sensors & Button | Common Ground |

---

## 📡 BLE Communication Protocol

The system communicates using the following UUIDs:
* **Service UUID:** `4fafc201-1fb5-459e-8fcc-c5c9c331914b`
* **Data (TX) UUID:** `beb5483e-36e1-4688-b7f5-ea07361b26a8` (Continuously streams BPM and SpO2. Format: `BPM,SpO2`)
* **Alert (TX) UUID:** `88924aee-2342-4357-939e-29367c345173` (Sends text only during emergencies. e.g., `DUSME_ALGILANDI`, `ACIL_BUTON`)
* **Control (RX) UUID:** `12345678-1234-1234-1234-1234567890ab` (Receives commands from the phone. e.g., `START`, `STOP`, `LIMITS:50,120`)

---

## 🚀 Setup & Installation

### 1. ESP32 Firmware Setup
1. Clone this repository to your local machine.
2. Open the ESP32 code using Arduino IDE or VS Code (PlatformIO).
3. Install the required libraries: `Adafruit MPU6050`, `MAX30100lib`.
4. Upload the code to your ESP32 board. *(Tip: If you get an upload error, hold down the BOOT button on the ESP32 while connecting).*

### 2. Flutter Mobile App Setup
1. Navigate to the `flutter_mobile_app` directory in your terminal.
2. Run `flutter pub get` to install the dependencies.
3. Connect a physical Android or iOS device (Bluetooth features do not work on emulators) and run `flutter run`.

---

## 📸 App Screenshot



![Mobile App Dashboard](docs/app_screenshot.png)

