import XCTest
@testable import MoleLite

// MARK: - Fixture 读取

/// 测试用的 fixture 加载器。Fixtures 由 Package.swift 的 `.copy("Fixtures")` 打进测试 bundle。
enum Fixture {
    /// 一次取齐所有 fixture，路径解析失败直接 XCTFail 并返回空 Data。
    static let names = [
        "clean-preview",
        "clean-execute",
        "uninstall-preview",
        "uninstall-execute",
        "rules-sample",
        "analyze",
    ]

    static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Data {
        guard let url = url(name) else {
            XCTFail("测试 bundle 里找不到 Fixtures/\(name).json", file: file, line: line)
            return Data()
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            XCTFail("读取 \(url.path) 失败：\(error)", file: file, line: line)
            return Data()
        }
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> T? {
        let payload = data(name, file: file, line: line)
        guard !payload.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: payload)
        } catch {
            XCTFail("\(name).json 解码为 \(T.self) 失败：\(error)", file: file, line: line)
            return nil
        }
    }

    private static func url(_ name: String) -> URL? {
        if let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: "json") {
            return url
        }
        // 某些平台把 .copy 的目录平铺或放在 Resources 下，再兜底扫一遍。
        if let root = Bundle.module.resourceURL {
            let candidates = [
                root.appendingPathComponent("Fixtures/\(name).json"),
                root.appendingPathComponent("Resources/Fixtures/\(name).json"),
            ]
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
