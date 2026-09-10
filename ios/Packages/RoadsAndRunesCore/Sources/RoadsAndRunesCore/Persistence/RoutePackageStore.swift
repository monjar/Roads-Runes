import Foundation

/// Offline storage for `RoutePackage`s (PRODUCT_SPEC §50).
public protocol RoutePackageStore: Sendable {
    func save(_ package: RoutePackage) throws
    func load(routeId: UUID) throws -> RoutePackage?
    func delete(routeId: UUID) throws
    func storedRouteIDs() throws -> [UUID]
}

/// One JSON file per route under `directory`.
public struct FileRoutePackageStore: RoutePackageStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(_ package: RoutePackage) throws {
        try FileStorage.ensureDirectory(directory)
        let data = try JSONCoding.encode(package)
        try data.write(to: fileURL(for: package.route.id), options: .atomic)
    }

    public func load(routeId: UUID) throws -> RoutePackage? {
        let url = fileURL(for: routeId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONCoding.decode(RoutePackage.self, from: data)
    }

    public func delete(routeId: UUID) throws {
        let url = fileURL(for: routeId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func storedRouteIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(5)))
        }
    }

    private func fileURL(for routeId: UUID) -> URL {
        directory.appendingPathComponent("\(routeId.uuidString).json")
    }
}

enum FileStorage {
    static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }
}
