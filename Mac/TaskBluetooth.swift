import CoreBluetooth
import Foundation

/// Workload over Bluetooth: this Mac offers its task list to nearby phones, so Workload on
/// the iPhone syncs as soon as it's in range — even with the app closed (iOS wakes it for a
/// pending Bluetooth connection). Pairing is encrypted (iOS asks once), and the phone also
/// sends its Musiplex key (this Mac's, or the linked server's).
///
/// Protocol: service 6B5E0001-…; the phone writes a request to 6B5E0002-… and gets the reply
/// as notifications on 6B5E0003-…. Both are framed as a 4-byte big-endian length, then UTF-8
/// JSON, split into pieces that fit the connection. Request {"t": key, "tasks": [...]};
/// reply {"tasks": [...], "now": epoch} after merging, or {"error": "unauthorized"}.
final class TaskBluetooth: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    static let service = CBUUID(string: "6B5E0001-4D55-5349-504C-4558574B4C44")
    static let request = CBUUID(string: "6B5E0002-4D55-5349-504C-4558574B4C44")
    static let reply = CBUUID(string: "6B5E0003-4D55-5349-504C-4558574B4C44")

    private let queue = DispatchQueue(label: "musiplex.tasks.bluetooth")
    private var manager: CBPeripheralManager!
    private var replyChar: CBMutableCharacteristic?
    private var incoming: [UUID: Data] = [:]
    private var outgoing: [(central: CBCentral, chunks: [Data])] = []
    private let accepts: @Sendable (String?) -> Bool

    init(accepts: @escaping @Sendable (String?) -> Bool) {
        self.accepts = accepts
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: queue)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        let request = CBMutableCharacteristic(type: Self.request, properties: [.write],
                                              value: nil, permissions: [.writeEncryptionRequired])
        let reply = CBMutableCharacteristic(type: Self.reply, properties: [.notify],
                                            value: nil, permissions: [.readEncryptionRequired])
        let service = CBMutableService(type: Self.service, primary: true)
        service.characteristics = [request, reply]
        replyChar = reply
        peripheral.removeAllServices()
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.service],
                                     CBAdvertisementDataLocalNameKey: "Musiplex"])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == Self.request {
            var buffer = incoming[r.central.identifier] ?? Data()
            if r.offset == 0 || buffer.isEmpty { buffer.append(r.value ?? Data()) } else { buffer.append(r.value ?? Data()) }
            incoming[r.central.identifier] = buffer
            if buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                if length > 8 << 20 { incoming[r.central.identifier] = nil }     // nonsense: drop
                else if buffer.count - 4 >= length {
                    incoming[r.central.identifier] = nil
                    handle(Data(buffer.dropFirst(4).prefix(length)), from: r.central)
                }
            }
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }

    private func handle(_ body: Data, from central: CBCentral) {
        var reply: Data
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], accepts(obj["t"] as? String) {
            TaskHub.shared.merge(obj["tasks"] as? [[String: Any]] ?? [])
            reply = TaskHub.shared.snapshot()
        } else {
            reply = Data(#"{"error":"unauthorized"}"#.utf8)
        }
        var framed = Data([UInt8(reply.count >> 24 & 0xFF), UInt8(reply.count >> 16 & 0xFF), UInt8(reply.count >> 8 & 0xFF), UInt8(reply.count & 0xFF)])
        framed.append(reply)
        let size = max(20, central.maximumUpdateValueLength)
        let chunks = stride(from: 0, to: framed.count, by: size).map { framed.subdata(in: $0..<min($0 + size, framed.count)) }
        outgoing.append((central, chunks))
        pump()
    }

    /// Sends queued reply pieces; when the link is full, waits for "ready" and goes on.
    private func pump() {
        guard let replyChar else { return }
        while !outgoing.isEmpty {
            var job = outgoing[0]
            while !job.chunks.isEmpty {
                guard manager.updateValue(job.chunks[0], for: replyChar, onSubscribedCentrals: [job.central]) else {
                    outgoing[0] = job
                    return
                }
                job.chunks.removeFirst()
            }
            outgoing.removeFirst()
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { pump() }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        outgoing.removeAll { $0.central.identifier == central.identifier }
        incoming[central.identifier] = nil
    }
}
