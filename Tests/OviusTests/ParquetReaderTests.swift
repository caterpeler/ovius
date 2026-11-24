import Foundation
import Testing
@testable import Ovius

/// The Parquet reader against files pyarrow wrote, checked against pyarrow's own reading of them
/// (`scripts/make-parquet-fixtures.py`): the GPU worker's real box file for `sample.mp4`, and variants of it in the
/// layouts the worker's writer uses on bigger files.
struct ParquetReaderTests {
    private struct Expected: Decodable {
        let null_every: Int
        let columns: [String]
        let values: [String: [Value]]

        enum Value: Decodable, Equatable {
            case number(Double)
            case text(String)
            case flag(Bool)

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let b = try? c.decode(Bool.self) { self = .flag(b) }
                else if let d = try? c.decode(Double.self) { self = .number(d) }
                else { self = .text(try c.decode(String.self)) }
            }
        }
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func expected() throws -> Expected {
        try JSONDecoder().decode(Expected.self, from: fixture("boxes_expected.json"))
    }

    /// The column as the fixture's values, for comparing whatever its type.
    private func values(_ table: ParquetTable, _ name: String) -> [Expected.Value?] {
        switch table.columns[name] {
        case .int64(let v): v.map { $0.map { .number(Double($0)) } }
        case .int32(let v): v.map { $0.map { .number(Double($0)) } }
        case .double(let v): v.map { $0.map { .number($0) } }
        case .float(let v): v.map { $0.map { .number(Double($0)) } }
        case .string(let v): v.map { $0.map { .text($0) } }
        case .bool(let v): v.map { $0.map { .flag($0) } }
        case nil: []
        }
    }

    @Test func readsTheWorkersRealBoxFile() throws {
        let want = try expected()
        let table = try ParquetReader.read(fixture("boxes_real.parquet"))

        #expect(table.rowCount == 1548)
        #expect(Set(table.columns.keys) == Set(want.columns))
        for name in want.columns {
            #expect(values(table, name) == want.values[name], "column \(name)")
        }
        #expect(table.strings("cls")?.compactMap { $0 }.allSatisfy { ["dumptruck", "excavator"].contains($0) } == true)
    }

    @Test(arguments: ["boxes_v2.parquet", "boxes_fallback.parquet", "boxes_plain.parquet"])
    func readsTheOtherLayoutsWithGaps(_ file: String) throws {
        let want = try expected()
        let table = try ParquetReader.read(fixture(file))

        #expect(table.rowCount == 1548)
        for (c, name) in want.columns.enumerated() {
            let full = try #require(want.values[name])
            let holed: [Expected.Value?] = full.enumerated().map { r, v in (r + c) % want.null_every == 0 ? nil : v }
            #expect(values(table, name) == holed, "\(file) column \(name)")
        }
    }

    @Test func readsOnlyTheColumnsAskedFor() throws {
        let table = try ParquetReader.read(fixture("boxes_real.parquet"), columns: ["t", "cls"])
        #expect(Set(table.columns.keys) == ["t", "cls"])
        #expect(table.doubles("t")?.first == 0)
        #expect(table.ints("t") == nil)
    }

    @Test func rejectsWhatIsntParquetOrIsCutShort() throws {
        #expect(throws: ParquetError.notParquet) { try ParquetReader.read(Data("{\"error\":\"Not Found\"}".utf8)) }
        let real = try fixture("boxes_real.parquet")
        #expect(throws: ParquetError.self) { try ParquetReader.read(real.prefix(real.count / 2) + Data("PAR1".utf8)) }
        var damaged = real
        damaged[damaged.count / 3] ^= 0xff
        damaged[damaged.count / 3 + 1] ^= 0xff
        // A flipped byte inside page data must fail or still give 1548 rows, never crash.
        if let table = try? ParquetReader.read(damaged) { #expect(table.rowCount == 1548) }
    }

    @Test func snappyCopiesThatOverlapRepeatTheLastBytes() throws {
        // Length 10; literal "ab"; copy 8 bytes from 2 back (1-byte-offset form: len 8 → (8-4)<<2 | 0b01).
        let compressed: [UInt8] = [10, 0b0000_0100, 0x61, 0x62, (4 << 2) | 1, 2]
        #expect(try Snappy.decompress(compressed[...]) == Array("ababababab".utf8))
        #expect(throws: ParquetError.self) { try Snappy.decompress([10, (4 << 2) | 1, 2][...]) }
    }
}
