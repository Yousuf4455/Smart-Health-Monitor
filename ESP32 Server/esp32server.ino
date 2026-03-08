#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include "MAX30100_PulseOximeter.h"

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// --- PIN TANIMLAMALARI ---
#define BUTTON_PIN 18      
#define LED_PIN 2          

// Pin Değişikliği (İsteğin üzerine yerleri değişmiş hali)
#define I2C_SDA 22  
#define max_SDA 23 
#define I2C_SCL 21  

// --- BLE UUID ---
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define DATA_CHAR_UUID      "beb5483e-36e1-4688-b7f5-ea07361b26a8" 
#define ALERT_CHAR_UUID     "88924aee-2342-4357-939e-29367c345173" 
#define CONTROL_CHAR_UUID   "12345678-1234-1234-1234-1234567890ab" 

// --- NESNELER ---
Adafruit_MPU6050 mpu;
PulseOximeter pox;

BLEServer* pServer = NULL;
BLECharacteristic* pDataChar = NULL;
BLECharacteristic* pAlertChar = NULL;
BLECharacteristic* pControlChar = NULL;

// --- DEĞİŞKENLER ---
bool deviceConnected = false;
bool systemActive = false;    // TRUE: Canlı Veri + Alarm, FALSE: Sadece Alarm (Güç Tasarrufu)
bool sensorErrorState = false; 

uint32_t tsLastReport = 0;     
const uint32_t REPORTING_PERIOD_MS = 500; 

// Eşik Değerleri (Telefondan güncellenebilir)
const float FALL_THRESHOLD = 15.0; 
int low_bpm_limit = 50;
int high_bpm_limit = 120;

// Zamanlayıcılar
unsigned long lastAlertSentTime = 0;     
const int ALERT_COOLDOWN = 3000;         

unsigned long lastMovementTime = 0;           
const unsigned long INACTIVITY_LIMIT = 120000; // 2 Dakika
const float MOVEMENT_SENSITIVITY = 5.0;       
float lastVectorMagnitude = 0;                

// --- CALLBACKLER ---

void onBeatDetected() {
    // Nabız callback
}

class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
      Serial.println(">> MOBIL CIHAZ BAGLANDI");
    };

    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      Serial.println(">> BAGLANTI KOPTU! Tekrar yayına başlanıyor...");
      
      // Bluetooth stack'inin temizlenmesi için yarım saniye bekle
      delay(500); 
      
      // Kilit nokta burası: Bağlantı kopsa bile yayını (Advertising) tekrar başlat!
      pServer->getAdvertising()->start(); 
    }
};


class MyControlCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
      String value = pCharacteristic->getValue().c_str();
      
      if (value == "START") {
        systemActive = true;
        Serial.println(">> MOD: CANLI IZLEME (Veri + Alarm)");
        digitalWrite(LED_PIN, HIGH); 
      } 
      else if (value == "STOP") {
        systemActive = false;
        Serial.println(">> MOD: BEKCI MODU (Sadece Alarm - Guc Tasarrufu)");
        digitalWrite(LED_PIN, LOW);
      }
      else if (value.startsWith("LIMITS:")) {
        String values = value.substring(7); 
        int commaIndex = values.indexOf(',');
        if (commaIndex > 0) {
           String lowStr = values.substring(0, commaIndex);
           String highStr = values.substring(commaIndex + 1);
           low_bpm_limit = lowStr.toInt();
           high_bpm_limit = highStr.toInt();
           Serial.print(">> YENI ESIKLER: "); Serial.print(low_bpm_limit); Serial.print("-"); Serial.println(high_bpm_limit);
        }
      }
    }
};

// --- YARDIMCI FONKSİYONLAR ---

bool checkConnections() {
    Wire.beginTransmission(0x68); 
    if (Wire.endTransmission() != 0) return false;
    Wire.beginTransmission(0x57); 
    if (Wire.endTransmission() != 0) return false;
    return true;
}

bool initSensors() {
    Serial.println("Sensörler başlatılıyor...");
    if (!mpu.begin()) {
        Serial.println("mpu6050 sinyal alınmıyor");
        return false;}
    mpu.setAccelerometerRange(MPU6050_RANGE_16_G);
    mpu.setGyroRange(MPU6050_RANGE_500_DEG);
    mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);

    if (!pox.begin()){ 
        Serial.println("MAX30100 Başlatılamadı!");
        return false;
    }
    pox.setIRLedCurrent(MAX30100_LED_CURR_11MA);
    pox.setOnBeatDetectedCallback(onBeatDetected);
    return true;
}

void setup() {
    Serial.begin(115200);
    pinMode(BUTTON_PIN, INPUT_PULLUP);
    pinMode(LED_PIN, OUTPUT);
    
    Wire.begin(max_SDA, I2C_SCL); 

    Serial.println("Sistem Aciliyor...");
    if (initSensors()) {
        Serial.println("Sensörler OK.");
        sensorErrorState = false;
    } else {
        Serial.println("Sensör Hatası!");
        sensorErrorState = true;
    }

    lastMovementTime = millis();

    BLEDevice::init("BileklikProje");
    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new MyServerCallbacks());
    BLEService *pService = pServer->createService(SERVICE_UUID);

    pDataChar = pService->createCharacteristic(DATA_CHAR_UUID, BLECharacteristic::PROPERTY_NOTIFY);
    pDataChar->addDescriptor(new BLE2902());
    pAlertChar = pService->createCharacteristic(ALERT_CHAR_UUID, BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_INDICATE);
    pAlertChar->addDescriptor(new BLE2902());
    pControlChar = pService->createCharacteristic(CONTROL_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
    pControlChar->setCallbacks(new MyControlCallbacks());

    pService->start();
    pServer->getAdvertising()->start();
    Serial.println("BLE Yayinda.");
}

void loop() {
    // 1. Sensörleri sürekli güncelle (Mod fark etmeksizin çalışmalı!)
    if (!sensorErrorState) {
        pox.update();
    }

    // 2. ACİL DURUM BUTONU (Mod Kapalı olsa bile çalışır!)
    if (digitalRead(BUTTON_PIN) == LOW) {
        delay(50); 
        if (digitalRead(BUTTON_PIN) == LOW) {
            Serial.println("!!! ACIL BUTON !!!");
            if (deviceConnected && (millis() - lastAlertSentTime > ALERT_COOLDOWN)) {
                pAlertChar->setValue("ACIL_BUTON");
                pAlertChar->notify();
                lastAlertSentTime = millis();
            }
            delay(500); 
        }
    }
       
  


    // 3. PERİYODİK İŞLEMLER (500ms)
    if (millis() - tsLastReport > REPORTING_PERIOD_MS) {
        
        // --- BAĞLANTI KONTROLÜ (RECONNECT) ---
        bool physicallyConnected = checkConnections();
        if (!physicallyConnected) {
            if (!sensorErrorState) { 
                Serial.println("!!! SENSOR KOPTU !!!");
                if (deviceConnected) { // Sensör koptu uyarısını her zaman gönder
                    pAlertChar->setValue("SENSOR_HATA");
                    pAlertChar->notify();
                }
                sensorErrorState = true; 
            }
            tsLastReport = millis();
            return; 
        } else {
            if (sensorErrorState) {
                Serial.println("Baglantı geri geldi! Yeniden başlatılıyor...");
                delay(100); Wire.begin(I2C_SDA, I2C_SCL); delay(100);
                if (initSensors()) {
                    Serial.println("KURTARMA BASARILI!");
                    sensorErrorState = false; 
                }
                tsLastReport = millis();
                return; 
            }
        }

        // --- VERİ OKUMA ---
        sensors_event_t a, g, temp;
        mpu.getEvent(&a, &g, &temp);
        float bpm = pox.getHeartRate();
        uint8_t spo2 = pox.getSpO2();

        // --- GÜVENLİK ANALİZİ (Her zaman çalışır) ---
        float vectorMagnitude = sqrt(pow(a.acceleration.x, 2) + pow(a.acceleration.y, 2) + pow(a.acceleration.z, 2));
        String alertMsg = "";
        bool urgent = false;

        // A) Hareketsizlik
        if (abs(vectorMagnitude - lastVectorMagnitude) > MOVEMENT_SENSITIVITY) {
            lastMovementTime = millis();
        }
        lastVectorMagnitude = vectorMagnitude;
        if (millis() - lastMovementTime > INACTIVITY_LIMIT) {
             alertMsg = "HAREKETSIZLIK";
             urgent = true;
        }

        // B) Düşme ve Nabız
        if (vectorMagnitude > FALL_THRESHOLD) {
            alertMsg = "DUSME_ALGILANDI";
            urgent = true;
            lastMovementTime = millis(); 
        } else if (bpm > 40 && bpm < low_bpm_limit) {
            alertMsg = "NABIZ_DUSUK";
            urgent = true;
        } else if (bpm > high_bpm_limit) {
            alertMsg = "NABIZ_YUKSEK";
            urgent = true;
        }
         Serial.println("----------------------------------------");

        Serial.print("İvme (X,Y,Z): ");
        Serial.print(sqrt(pow(a.acceleration.x, 2) + pow(a.acceleration.y, 2) + pow(a.acceleration.z, 2)));
        Serial.print(", ");

        Serial.print("BPM: ");
        Serial.print(pox.getHeartRate());
        Serial.print(" | SpO2: ");
        Serial.println(pox.getSpO2());

        // --- VERİ GÖNDERİMİ ---
        if (deviceConnected) {
            
            // 1. CANLI VERİ AKIŞI: Sadece Sistem "START" durumundaysa gönderilir.
            // Bu kısım "Güç Tasarrufu" sağlar.
            if (systemActive) {
                String dataPackage = String(bpm, 0) + "," + String(spo2);
                pDataChar->setValue(dataPackage.c_str());
                pDataChar->notify();
            }

            // 2. ACİL DURUM: Sistem kapalı (Tasarruf Modu) olsa bile GÖNDERİLİR.
            if (urgent && (millis() - lastAlertSentTime > ALERT_COOLDOWN)) {
                pAlertChar->setValue(alertMsg.c_str());
                pAlertChar->notify();
                lastAlertSentTime = millis();
                Serial.println(">> ACIL DURUM UYARISI GONDERILDI: " + alertMsg);
            }
        }
        tsLastReport = millis();
    }
}