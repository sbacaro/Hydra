// Hydra Audio — GPL-3.0
// Control-plane stores: channel labels and scenes. Both persisted as JSON in
// ~/Library/Application Support/Hydra/. Labels live apart from system IDs
// (Section 7.7); scenes are full-matrix snapshots applied atomically.

import Foundation
import HydraCore

func hydraSupportURL(_ file: String) -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hydra", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.appendingPathComponent(file)
}

// MARK: - Labels

final class LabelStore {
    private let queue = DispatchQueue(label: "hydra.labels")
    private var payload = ChannelLabelsPayload()
    private static let url = hydraSupportURL("labels.json")

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let loaded = try? JSONDecoder().decode(ChannelLabelsPayload.self, from: data) {
            payload = loaded
        }
    }

    func all() -> ChannelLabelsPayload {
        queue.sync { payload }
    }

    /// Returns true if anything changed.
    func set(_ change: SetLabelPayload) -> Bool {
        queue.sync {
            let trimmed = change.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let newValue = (trimmed?.isEmpty ?? true) ? nil : trimmed
            switch change.scope {
            case .input:
                guard payload.inputs[change.index] != newValue else { return false }
                payload.inputs[change.index] = newValue
            case .output:
                guard payload.outputs[change.index] != newValue else { return false }
                payload.outputs[change.index] = newValue
            }
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: Self.url, options: .atomic)
            }
            return true
        }
    }
}

// MARK: - Scenes

final class SceneStore {
    private let queue = DispatchQueue(label: "hydra.scenes")
    private var scenes: [PatchScene] = []
    private static let url = hydraSupportURL("scenes.json")

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let loaded = try? JSONDecoder().decode([PatchScene].self, from: data) {
            scenes = loaded
        }
    }

    func all() -> [PatchScene] {
        queue.sync { scenes }
    }

    func scene(id: UUID) -> PatchScene? {
        queue.sync { scenes.first { $0.id == id } }
    }

    /// Snapshot `connections` under `name`. Same name overwrites (updates) it.
    func save(name: String, connections: [Connection]) {
        queue.sync {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if let idx = scenes.firstIndex(where: { $0.name == trimmed }) {
                scenes[idx].connections = connections
                scenes[idx].modifiedAt = Date()
            } else {
                scenes.append(PatchScene(name: trimmed, connections: connections))
            }
            persistLocked()
        }
    }

    /// Returns true if a scene was deleted.
    func delete(id: UUID) -> Bool {
        queue.sync {
            let before = scenes.count
            scenes.removeAll { $0.id == id }
            if scenes.count != before {
                persistLocked()
                return true
            }
            return false
        }
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(scenes) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}

// MARK: - Config

final class ConfigStore {
    private let queue = DispatchQueue(label: "hydra.config")
    private var payload = ConfigPayload()
    private static let url = hydraSupportURL("config.json")

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let loaded = try? JSONDecoder().decode(ConfigPayload.self, from: data) {
            payload = loaded
        }
    }

    func current() -> ConfigPayload {
        queue.sync { payload }
    }

    func update(_ new: ConfigPayload) {
        queue.sync {
            payload = new
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: Self.url, options: .atomic)
            }
        }
    }
}

// MARK: - Virtual interfaces

/// Named blocks of the 256-channel pool. The daemon owns allocation: each
/// interface gets the first contiguous free slice that fits, and deleting
/// frees the slice. Persisted to interfaces.json.
final class InterfaceStore {
    private let queue = DispatchQueue(label: "hydra.interfaces")
    private var list: [VirtualInterfaceInfo] = []
    private static let url = hydraSupportURL("interfaces.json")

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let loaded = try? JSONDecoder().decode([VirtualInterfaceInfo].self, from: data) {
            list = loaded
        }
    }

    func all() -> [VirtualInterfaceInfo] {
        queue.sync { list.sorted { min($0.inBase, $0.outBase) < min($1.inBase, $1.outBase) } }
    }

    /// Allocates independent in/out slices from one pool free-space map
    /// (slices are exclusive regardless of direction, so an interface's
    /// inputs can never alias another interface's outputs through the
    /// driver loopback). Returns nil + warning when the pool can't fit it.
    @discardableResult
    func create(name: String, inChannels: Int, outChannels: Int,
                ndiTX: Bool = false, aes67TX: Bool = false) -> VirtualInterfaceInfo? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              inChannels >= 0, outChannels >= 0,
              inChannels + outChannels >= 1,
              inChannels + outChannels <= Hydra.backplaneChannels else { return nil }
        return queue.sync {
            var occupied: [(base: Int, count: Int)] = list.flatMap {
                [($0.inBase, $0.inChannels), ($0.outBase, $0.outChannels)]
            }.filter { $0.1 > 0 }

            func allocate(_ count: Int) -> Int? {
                guard count > 0 else { return 0 } // empty side: base unused
                var base = 0
                for slot in occupied.sorted(by: { $0.base < $1.base }) {
                    if slot.base - base >= count { break }
                    base = max(base, slot.base + slot.count)
                }
                guard base + count <= Hydra.backplaneChannels else { return nil }
                occupied.append((base, count))
                return base
            }

            guard let inBase = allocate(inChannels),
                  let outBase = allocate(outChannels) else {
                EventCenter.shared.emit(.warning, "No room for \"\(trimmed)\": the soundcard pool (\(Hydra.backplaneChannels) channels) is full.")
                return nil
            }
            let info = VirtualInterfaceInfo(name: trimmed,
                                            inChannels: inChannels, outChannels: outChannels,
                                            inBase: inBase, outBase: outBase,
                                            ndiTX: ndiTX, aes67TX: aes67TX)
            list.append(info)
            persistLocked()
            log("Interface created: \"\(trimmed)\" — \(inChannels) in @ \(inBase + 1), \(outChannels) out @ \(outBase + 1)")
            return info
        }
    }

    /// Toggles NDI TX for an interface. Returns true when something changed.
    func setNDI(id: UUID, enabled: Bool) -> Bool {
        queue.sync {
            guard let index = list.firstIndex(where: { $0.id == id }),
                  list[index].ndiTX != enabled else { return false }
            list[index].ndiTX = enabled
            persistLocked()
            log("Interface \"\(list[index].name)\": NDI TX \(enabled ? "on" : "off")")
            return true
        }
    }

    /// Toggles AES67 TX for an interface. Returns true when something changed.
    func setAES67(id: UUID, enabled: Bool) -> Bool {
        queue.sync {
            guard let index = list.firstIndex(where: { $0.id == id }),
                  list[index].aes67TX != enabled else { return false }
            list[index].aes67TX = enabled
            persistLocked()
            log("Interface \"\(list[index].name)\": AES67 TX \(enabled ? "on" : "off")")
            return true
        }
    }

    @discardableResult
    func delete(id: UUID) -> VirtualInterfaceInfo? {
        queue.sync {
            guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
            let removed = list.remove(at: index)
            persistLocked()
            log("Interface deleted: \"\(removed.name)\"")
            return removed
        }
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}
