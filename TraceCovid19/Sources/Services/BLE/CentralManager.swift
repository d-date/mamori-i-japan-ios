// Copyright (c) 2020- Masakazu Ohtsuka / maaash.jp
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE
// OR OTHER DEALINGS IN THE SOFTWARE.

import Foundation
import CoreBluetooth
import UIKit

// Magic number to keep the apps talking in background for a long time
let longSessionBackgroundTaskInterval: TimeInterval = 15

class CentralManager: NSObject {
    private var started: Bool = false
    private var centralManager: CBCentralManager!
    private var queue: DispatchQueue
    private let services: [Service]
    private var commands: [Command] = []

    private var peripherals: [UUID: Peripheral] = [:]
    private var androidIdentifiers: [Data] = []

    struct LongSession {
        var backgroundTask: UIBackgroundTaskIdentifier
        weak var timer: Timer? // RunLoop retains the timer
    }
    private var longSessions: [CBPeripheral: LongSession] = [:]

    private var didUpdateValue: CharacteristicDidUpdateValue!
    private var didReadRSSI: DidReadRSSI!
    private var didDiscoverTxPower: DidDiscoverTxPower!

    var centralDidUpdateStateCallback: ((CBManagerState) -> Void)?

    init(queue: DispatchQueue, services: [Service]) {
        self.services = services
        self.queue = queue
        super.init()
        let options = [
            // CBCentralManagerOptionShowPowerAlertKey: 1,
            CBCentralManagerOptionRestoreIdentifierKey: "jp.mamori-i.app.CentralManager"
        ] as [String: Any]
        centralManager = CBCentralManager(delegate: self, queue: queue, options: options)
    }

    func turnOn() {
        started = true
        startScanning()
    }

    func turnOff() {
        started = false
        stopScan()
    }

    func restartScan() {
        log()
        stopScan()
        peripherals.values.forEach { peripheral in
            disconnect(peripheral)
        }
        peripherals = [:]
        androidIdentifiers = []

        if started {
            startScanning()
        }
    }

    func getState() -> CBManagerState {
        centralManager.state
    }

    private func startScanning() {
        guard centralManager.state == .poweredOn else { return }

        let options = [CBCentralManagerScanOptionAllowDuplicatesKey: false as NSNumber]
        let cbuuids = services.map { $0.toCBUUID() }
        centralManager.scanForPeripherals(withServices: cbuuids, options: options)
    }

    private func stopScan() {
        centralManager.stopScan()
    }

    func appendCommand(command: Command) -> CentralManager {
        self.commands.append(command)
        return self // for chaining
    }

    func didUpdateValue(_ callback :@escaping CharacteristicDidUpdateValue) -> CentralManager {
        didUpdateValue = callback
        return self
    }

    func didReadRSSI(_ callback: @escaping DidReadRSSI) -> CentralManager {
        didReadRSSI = callback
        return self
    }

    func didDiscoverTxPower(_ callback: @escaping DidDiscoverTxPower) -> CentralManager {
        didDiscoverTxPower = callback
        return self
    }

    func disconnect(_ peripheral: Peripheral) {
        centralManager.cancelPeripheralConnection(peripheral.peripheral)
    }

    func disconnectAllPeripherals() {
        peripherals.forEach { _, peripheral in
            centralManager.cancelPeripheralConnection(peripheral.peripheral)
        }
    }

    func addPeripheral(_ peripheral: CBPeripheral) {
        let p = Peripheral(peripheral: peripheral, queue: queue, services: services, commands: commands, didUpdateValue: didUpdateValue, didReadRSSI: didReadRSSI)
        peripherals[peripheral.identifier] = p
    }
}

extension CentralManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("state=\(central.state.toString)")
        if central.state == .poweredOn && started {
            startScanning()
        }
        centralDidUpdateStateCallback?(central.state)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("peripheral=\(peripheral.shortId)")

        let p = peripherals[peripheral.identifier]
        if let p = p {
            p.discoverServices()
        }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("peripheral=\(peripheral.shortId), error=\(String(describing: error))")
        peripherals.removeValue(forKey: peripheral.identifier)

        startLongSession(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        log("peripheral=\(peripheral.shortId), rssi=\(RSSI)")

        if let txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? Double {
            // It seems iOS13.3.1 also sends TxPower, eg. 12. But iOS12.4.5 does not...
            // and we can't "read" TxPower afterwards, so this is the time we should save it.
            didDiscoverTxPower(peripheral.identifier, txPower)
        }
        if let p = peripherals[peripheral.identifier] {
            // We read RSSI after connect, and didDiscover shouldn't be called again because of "CBCentralManagerScanOptionAllowDuplicatesKey: false",
            // but still sometimes this is called, and since we know RSSI fluctuates, it's better to measure many times.
            didReadRSSI(p, RSSI, nil)
        }

        // Android
        // iphones will "mask" the peripheral's identifier for android devices, resulting in the same android device being discovered multiple times with different peripheral identifier. Hence android is using CBAdvertisementDataServiceDataKey data for identifying an android pheripheral
        if let manuData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            let androidIdentifierData = manuData.subdata(in: 2..<manuData.count)
            if androidIdentifiers.contains(androidIdentifierData) {
                log("Android Peripheral \(peripheral.shortId) has been discovered already in this window, will not attempt to connect to it again")
                return
            }
            androidIdentifiers.append(androidIdentifierData)
            addPeripheral(peripheral)
            central.connect(peripheral, options: nil)
            return
        }

        if peripherals[peripheral.identifier] != nil {
            log("iOS Peripheral \(peripheral.shortId) has been discovered already")
            return
        }
        addPeripheral(peripheral)
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("peripheral=\(peripheral.shortId), error=\(String(describing: error))")

        endLongSession(peripheral)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        log("dict=\(dict)")

        // Hmm, no we want to reconnect to them and re-record the proximity event
//        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
//            peripherals.forEach { (peripheral) in
//                addPeripheral(peripheral)
//            }
//        }
    }
}

extension CentralManager {
    private func startLongSession(_ peripheral: CBPeripheral) {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "CentralManager-\(peripheral.identifier)") { [weak self] in
            log("background task[peripheral=\(peripheral.shortId)] expired")
            self?.queue.async {
                self?.centralManager?.cancelPeripheralConnection(peripheral)
            }
        }
        let timer = Timer(timeInterval: longSessionBackgroundTaskInterval, repeats: false) { [weak self] _ in
            log("timer fired for peripheral=\(peripheral.shortId), connecting again")
            self?.queue.async {
                self?.endLongSession(peripheral)
                self?.addPeripheral(peripheral)
                self?.centralManager.connect(peripheral, options: nil)
            }
        }
        DispatchQueue.main.async {
            log("begin background task[peripheral=\(peripheral.shortId)] time remaining=\(UIApplication.shared.backgroundTimeRemaining)")
            RunLoop.current.add(timer, forMode: .common)
        }
        longSessions[peripheral] = LongSession(backgroundTask: backgroundTask, timer: timer)
    }

    private func endLongSession(_ peripheral: CBPeripheral) {
        if let longConnection = longSessions.removeValue(forKey: peripheral) {
            UIApplication.shared.endBackgroundTask(longConnection.backgroundTask)
            DispatchQueue.main.async {
                longConnection.timer?.invalidate()
            }
        }
    }
}
