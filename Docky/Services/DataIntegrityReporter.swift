import Foundation

enum DataIntegrityReporter {
    /// Builds a dictionary from `pairs`, keeping the first value for any
    /// duplicate key. Duplicates are reported via NSLog.
    static func makeDictionary<Key: Hashable, Value>(
        _ pairs: [(Key, Value)],
        site: String
    ) -> [Key: Value] {
        var seen: Set<Key> = []
        var duplicates: [Key] = []
        var result: [Key: Value] = [:]
        result.reserveCapacity(pairs.count)
        for (key, value) in pairs {
            if seen.insert(key).inserted {
                result[key] = value
            } else {
                duplicates.append(key)
            }
        }
        if !duplicates.isEmpty {
            reportDuplicateKeys(site: site, duplicates: duplicates)
        }
        return result
    }

    static func reportDuplicateKeys<Key>(site: String, duplicates: [Key]) {
        guard !duplicates.isEmpty else { return }
        let sample = duplicates.prefix(5).map { String(describing: $0) }
        NSLog(
            "[Wharf] duplicate keys at \(site) count=\(duplicates.count) sample=\(sample)"
        )
    }
}
