//
//  BLEService.swift
//  TraceCovid19
//
//  Created by yosawa on 2020/04/10.
//

import UIKit
import CoreBluetooth

let traceDataRecordThrottleInterval: TimeInterval = 30

enum Service: CustomStringConvertible {
    case trace

    private var bleSSID: String {
        #if DEV
        return "416DFC7B-D6E2-4373-9299-D81ACD3CC728"
        #elseif STG
        return "0E2FD244-2114-466C-9F18-2D493CD70407"
        #else
        return "90FA7ABE-FAB6-485E-B700-1A17804CAA13"
        #endif
    }

    func toCBUUID() -> CBUUID {
        CBUUID(string: bleSSID)
    }

    var description: String {
        switch self {
        case .trace:
            return "trace"
        }
    }
}

enum Characteristic: CustomStringConvertible {
    case contact

    private static var characteristicId: String {
        #if DEV
        return "416DFC7B-D6E2-4373-9299-D81ACD3CC729"
        #elseif STG
        return "0E2FD244-2114-466C-9F18-2D493CD70408"
        #else
        return "90FA7ABE-FAB6-485E-B700-1A17804CAA14"
        #endif
    }

    func toService() -> Service {
        switch self {
        case .contact:
            return .trace
        }
    }

    func toCBUUID() -> CBUUID {
        CBUUID(string: type(of: self).characteristicId)
    }

    var description: String {
        switch self {
        case .contact:
            return "contact"
        }
    }

    static func fromCBCharacteristic(_ c: CBCharacteristic) -> Characteristic? {
        guard c.uuid.uuidString == characteristicId else { return nil }
        return .contact
    }
}

indirect enum Command: CustomStringConvertible {
    case read(from: Characteristic)
    case write(to: Characteristic, value: (Peripheral) -> (Data?))
    case readRSSI
    case scheduleCommands(commands: [Command], withTimeInterval: TimeInterval, repeatCount: Int)
    case cancel(callback: (Peripheral) -> Void)
    var description: String {
        switch self {
        case .read:
            return "read"
        case .write:
            return "write"
        case .readRSSI:
            return "readRSSI"
        case .scheduleCommands:
            return "schedule"
        case .cancel:
            return "cancel"
        }
    }
}

typealias CharacteristicDidUpdateValue = (Peripheral, Characteristic, Data?, Error?) -> Void
typealias DidReadRSSI = (Peripheral, NSNumber, Error?) -> Void
typealias DidDiscoverTxPower = (UUID, Double) -> Void

// BLEService holds all the business logic related to BLE.
final class BLEService {
    private var peripheralManager: PeripheralManager?
    private var centralManager: CentralManager?
    private var coreData: CoreDataService!
    private var tempId: TempIdService!

    // Access traceData from the queue only, except in init, otherwise race can happen
    private var traceData: [UUID: TraceDataRecord]!

    private let queue: DispatchQueue!
    private var backgroundTaskId: UIBackgroundTaskIdentifier?
    var bluetoothDidUpdateStateCallback: ((CBManagerState) -> Void)?

    init(
        queue: DispatchQueue,
        coreData: CoreDataService,
        tempId: TempIdService
    ) {
        self.queue = queue
        self.peripheralManager = nil
        self.centralManager = nil
        self.coreData = coreData
        self.tempId = tempId
        self.traceData = [:]
    }

    func setupBluetooth() {
        guard centralManager == nil && peripheralManager == nil else {
            // Already setup
            return
        }
        centralManager = CentralManager(queue: queue, services: [.trace])
        centralManager?.centralDidUpdateStateCallback = centralDidUpdateStateCallback

        let tracerService = CBMutableService(type: Service.trace.toCBUUID(), primary: true)
        let characteristic = CBMutableCharacteristic(type: Characteristic.contact.toCBUUID(), properties: [.read, .write, .writeWithoutResponse], value: nil, permissions: [.readable, .writeable])
        tracerService.characteristics = [characteristic]

        peripheralManager = PeripheralManager(peripheralName: "mamori-i", queue: queue, services: [tracerService])

        _ = peripheralManager?
            // Central is trying to read from us
            .onRead { [unowned self] _, ch in
                switch ch {
                case .contact:
                    let userId = self.tempId.getTempId()
                    let payload = ReadData(tempID: userId.tempId)
                    return payload.data
                }
            }
            // Central is trying to write into us
            .onWrite { [unowned self] central, ch, data in
                switch ch {
                case .contact:
                    guard let writeData = WriteData(from: data) else {
                        let str = String(data: data, encoding: .utf8)
                        log("failed to deserialize data=\(String(describing: str))")
                        return false
                    }
                    let record = TraceDataRecord(from: writeData)
                    if self.shouldSave(record: record, about: central.identifier) {
                        log("save: \(record.tempId ?? "nil")")
                        self.coreData.save(traceDataRecord: record)
                        self.traceData[central.identifier] = record

                        #if DEBUG
                        debugNotify(message: "written=\(writeData.i)")
                        #endif
                    } else {
                        log("not saving now")
                    }
                    return true
                }
            }

        let writeCommand: Command = .write(to: .contact, value: { [unowned self] peripheral in
            let record = self.traceData[peripheral.id] ?? TraceDataRecord()
            let userId = self.tempId.getTempId()
            let writeData = WriteData(RSSI: record.rssi ?? 0, tempID: userId.tempId)
            return writeData.data
        })

        // Commands and callbacks should happen in this order
        _ = centralManager?
            .didDiscoverTxPower { [unowned self] uuid, txPower in
                var record = self.traceData[uuid] ?? TraceDataRecord()
                record.txPower = txPower
                self.traceData[uuid] = record
            }
            .appendCommand(
                command: .readRSSI
            )
            .didReadRSSI { [unowned self] peripheral, RSSI, error in
                log("peripheral=\(peripheral.shortId), RSSI=\(RSSI), error=\(String(describing: error))")

                guard error == nil else {
                    self.centralManager?.disconnect(peripheral)
                    return
                }
                var record = self.traceData[peripheral.id] ?? TraceDataRecord()
                if record.rssi == nil || (record.rssi! < RSSI.doubleValue) {
                    record.rssi = RSSI.doubleValue
                    self.traceData[peripheral.id] = record
                }
            }
            .appendCommand(
                command: writeCommand
            )
            .appendCommand(
                command: .read(from: .contact)
            )
            .didUpdateValue { [unowned self] peripheral, ch, data, error in
                log("didUpdateValueFor peripheral=\(peripheral.shortId), ch=\(ch), data=\(String(describing: data)), error=\(String(describing: error))")

                guard error == nil && data != nil else {
                    self.centralManager?.disconnect(peripheral)
                    return
                }

                guard let readData = ReadData(from: data!) else {
                    self.centralManager?.disconnect(peripheral)
                    return
                }
                var record = self.traceData[peripheral.id] ?? TraceDataRecord()
                record.tempId = readData.i
                record.timestamp = Date()

                if self.shouldSave(record: record, about: peripheral.id) {
                    log("save: \(record.tempId ?? "nil")")
                    self.coreData.save(traceDataRecord: record)
                    self.traceData[peripheral.id] = record

                    #if DEBUG
                    debugNotify(message: "read=\(readData.i)")
                    #endif
                } else {
                    log("not saving now")
                }
            }
            .appendCommand(
                command: .cancel(callback: { [unowned self] peripheral in
                    self.centralManager?.disconnect(peripheral)
                })
            )
    }

    func turnOn() {
        setupBluetooth()
        peripheralManager?.turnOn()
        centralManager?.turnOn()
    }

    func turnOff() {
        peripheralManager?.turnOff()
        centralManager?.turnOff()
    }

    // shouldSave throttles the records and saves a new record only after 30seconds has passed since the last record from the same peer, identified by the UUID.
    // Caller should update the timestamp only when shouldSave returns true.
    // record parameter should include a non nil timestamp.
    func shouldSave(record: TraceDataRecord, about peerUUID: UUID) -> Bool {
        guard let lastRecord = traceData[peerUUID] else {
            return true
        }
        guard lastRecord.timestamp != nil else {
            return true
        }
        guard record.timestamp != nil else {
            // warning, a record without a timestamp will not be saved.
            return false
        }
        if record.timestamp!.timeIntervalSince(lastRecord.timestamp!) > traceDataRecordThrottleInterval {
            return true
        }
        return false
    }

    func isBluetoothAuthorized() -> Bool {
        if #available(iOS 13.1, *) {
            return CBManager.authorization == .allowedAlways
        } else {
            // NOTE: iOS13.0だと挙動が違うので注意
            return CBPeripheralManager.authorizationStatus() == .authorized
        }
    }

    func isBluetoothOn() -> Bool {
        guard centralManager != nil else {
            return false
        }
        switch centralManager!.getState() {
        case .poweredOff:
            log("[BLEService] Bluetooth is off")
        case .resetting:
            log("[BLEService] Resetting State")
        case .unauthorized:
            log("[BLEService] Unauth State")
        case .unknown:
            log("[BLEService] Unknown State")
        case .unsupported:
            centralManager!.turnOn()
            log("[BLEService] Unsupported State")
        default:
            log("[BLEService] Bluetooth is on")
        }
        return centralManager!.getState() == CBManagerState.poweredOn
    }

    func centralDidUpdateStateCallback(_ state: CBManagerState) {
        bluetoothDidUpdateStateCallback?(state)
    }
}

#if DEBUG
func debugNotify(message: String) {
    let content = UNMutableNotificationContent()
    content.title = message
    let notification = UNNotificationRequest(identifier: NSUUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(notification) { er in
        if er != nil {
            log("notification error: \(er!)")
        }
    }
}
#endif
