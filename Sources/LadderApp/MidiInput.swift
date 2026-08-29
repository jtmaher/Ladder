import CoreMIDI
import Foundation
import Synchronization

enum MidiEventKind: UInt8 {
    case noteOn, noteOff, controlChange, pitchBend
}

struct MidiEvent {
    var kind: MidiEventKind = .noteOn
    var note: UInt8 = 0   // note number, or CC number for controlChange
    var value: Float = 0  // velocity/CC 0...1, pitch bend -1...1
}

/// Single-producer (CoreMIDI thread) single-consumer (audio thread) ring buffer.
/// Capacity must be a power of two. When full, events are dropped rather than blocking.
final class MidiEventFIFO: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<MidiEvent>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    init(capacity: Int = 1024) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0)
        self.capacity = capacity
        self.mask = capacity - 1
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: MidiEvent(), count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    func push(_ event: MidiEvent) {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        guard t - h < capacity else { return }
        storage[t & mask] = event
        tail.store(t + 1, ordering: .releasing)
    }

    func pop() -> MidiEvent? {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard h < t else { return nil }
        let event = storage[h & mask]
        head.store(h + 1, ordering: .releasing)
        return event
    }
}

/// Connects to every MIDI source on the system (and re-connects on hot-plug),
/// parses incoming UMP packets, and pushes events into the FIFO. The receive
/// block runs on CoreMIDI's thread: parse + atomic push only, no allocation.
final class MidiInput {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let fifo: MidiEventFIFO
    private var connectedSources = Set<MIDIEndpointRef>()

    /// Called on the main thread whenever the set of connected sources changes.
    var onSourcesChanged: (([String]) -> Void)?

    // Words per Universal MIDI Packet, indexed by message type nibble.
    private static let umpWordCounts: [Int] = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]

    init(fifo: MidiEventFIFO) {
        self.fifo = fifo
    }

    func start() {
        let clientStatus = MIDIClientCreateWithBlock("Ladder" as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.connectAllSources() }
        }
        guard clientStatus == noErr else { return }

        let portStatus = MIDIInputPortCreateWithProtocol(client, "LadderIn" as CFString, ._2_0, &port) { [weak self] eventList, _ in
            self?.handle(eventList: eventList)
        }
        guard portStatus == noErr else { return }

        connectAllSources()
    }

    private func connectAllSources() {
        var names: [String] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            if !connectedSources.contains(source) {
                if MIDIPortConnectSource(port, source, nil) == noErr {
                    connectedSources.insert(source)
                }
            }
            names.append(Self.displayName(of: source))
        }
        onSourcesChanged?(names)
    }

    private static func displayName(of endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr,
           let name = name?.takeRetainedValue() {
            return name as String
        }
        return "Unknown device"
    }

    // MARK: - UMP parsing (CoreMIDI thread)

    private func handle(eventList: UnsafePointer<MIDIEventList>) {
        for packetPtr in eventList.unsafeSequence() {
            let packet = packetPtr.pointee
            let wordCount = min(Int(packet.wordCount), 64)
            withUnsafeBytes(of: packet.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < wordCount {
                    let word0 = words[i]
                    let messageType = Int(word0 >> 28)
                    let length = Self.umpWordCounts[messageType]
                    guard i + length <= wordCount else { break }
                    switch messageType {
                    case 0x2:
                        parseMidi1ChannelVoice(word0)
                    case 0x4:
                        parseMidi2ChannelVoice(word0, words[i + 1])
                    default:
                        break
                    }
                    i += length
                }
            }
        }
    }

    private func parseMidi1ChannelVoice(_ w0: UInt32) {
        let status = (w0 >> 16) & 0xF0
        let data1 = UInt8((w0 >> 8) & 0x7F)
        let data2 = UInt8(w0 & 0x7F)
        switch status {
        case 0x90 where data2 > 0:
            fifo.push(MidiEvent(kind: .noteOn, note: data1, value: Float(data2) / 127.0))
        case 0x80, 0x90:
            fifo.push(MidiEvent(kind: .noteOff, note: data1))
        case 0xB0:
            fifo.push(MidiEvent(kind: .controlChange, note: data1, value: Float(data2) / 127.0))
        case 0xE0:
            let bend14 = (UInt32(data2) << 7) | UInt32(data1)
            fifo.push(MidiEvent(kind: .pitchBend, note: 0, value: Float(bend14) / 8192.0 - 1.0))
        default:
            break
        }
    }

    private func parseMidi2ChannelVoice(_ w0: UInt32, _ w1: UInt32) {
        let status = (w0 >> 16) & 0xF0
        let index = UInt8((w0 >> 8) & 0x7F)
        switch status {
        case 0x90:
            let velocity = UInt16(w1 >> 16)
            if velocity == 0 {
                fifo.push(MidiEvent(kind: .noteOff, note: index))
            } else {
                fifo.push(MidiEvent(kind: .noteOn, note: index, value: Float(velocity) / 65535.0))
            }
        case 0x80:
            fifo.push(MidiEvent(kind: .noteOff, note: index))
        case 0xB0:
            fifo.push(MidiEvent(kind: .controlChange, note: index, value: Float(w1) / Float(UInt32.max)))
        case 0xE0:
            fifo.push(MidiEvent(kind: .pitchBend, note: 0, value: Float(w1) / Float(UInt32.max) * 2.0 - 1.0))
        default:
            break
        }
    }
}
