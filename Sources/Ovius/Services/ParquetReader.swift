import Foundation

/// Reads flat Parquet files: the box tracks the GPU worker writes with pandas/pyarrow (`boxes.csv` → `.parquet`),
/// so the app can pick out one activity's boxes without the backend doing it.
///
/// It covers what that writer produces: a flat schema of required or optional columns; BOOLEAN, INT32, INT64, FLOAT,
/// DOUBLE and BYTE_ARRAY values; PLAIN, RLE and dictionary encodings (including a dictionary that overflows into plain
/// pages); data pages v1 and v2; several row groups; Snappy or no compression. Anything else (nested or repeated
/// columns, other codecs, delta encodings) fails with `ParquetError.unsupported` rather than being misread.
/// Format: https://github.com/apache/parquet-format
public enum ParquetReader {
    /// Reads `columns` (every column when nil) of a whole file.
    public static func read(_ data: Data, columns wanted: Set<String>? = nil) throws -> ParquetTable {
        let bytes = [UInt8](data)
        let meta = try FileMetadata(bytes)
        var columns: [String: ParquetColumn] = [:]
        for (index, leaf) in meta.leaves.enumerated() where wanted?.contains(leaf.name) ?? true {
            var builder = ColumnBuilder(type: leaf.type)
            for group in meta.rowGroups {
                guard index < group.count else { throw ParquetError.corrupt("a row group is missing column \(leaf.name)") }
                try readChunk(group[index], leaf: leaf, bytes: bytes, into: &builder)
            }
            guard builder.count == meta.rowCount else {
                throw ParquetError.corrupt("column \(leaf.name) has \(builder.count) values for \(meta.rowCount) rows")
            }
            columns[leaf.name] = builder.column
        }
        return ParquetTable(rowCount: meta.rowCount, columns: columns)
    }

    // MARK: Pages

    private static func readChunk(_ chunk: ChunkMetadata, leaf: Leaf, bytes: [UInt8], into builder: inout ColumnBuilder) throws {
        let start = chunk.dictionaryPageOffset.flatMap { $0 > 0 && $0 < chunk.dataPageOffset ? $0 : nil } ?? chunk.dataPageOffset
        let end = start + chunk.compressedSize
        guard start >= 4, chunk.compressedSize >= 0, end <= bytes.count - 8 else {
            throw ParquetError.corrupt("column \(leaf.name)'s pages lie outside the file")
        }
        var dictionary: PlainValues?
        var read = 0
        var pos = start
        while read < chunk.valueCount, pos < end {
            var thrift = ThriftReader(bytes, at: pos)
            let header = try thrift.readStruct()
            pos = thrift.pos
            let compressed = try header.int(3)
            let uncompressed = try header.int(2)
            let pageEnd = pos + compressed
            guard compressed >= 0, pageEnd <= end else { throw ParquetError.corrupt("a page of \(leaf.name) runs past its column") }
            let raw = bytes[pos..<pageEnd]

            switch try header.int(1) {
            case 2: // Dictionary page: PLAIN values.
                let info = try header.structure(7)
                let page = try decompress(raw, codec: chunk.codec, size: uncompressed)
                dictionary = try plain(page[...], type: leaf.type, count: try info.int(1))
            case 0: // Data page v1: [definition levels with a length prefix][values], all compressed together.
                let info = try header.structure(5)
                let count = try info.int(1)
                let page = try decompress(raw, codec: chunk.codec, size: uncompressed)
                var p = page.startIndex
                var present: [Bool]?
                if leaf.maxDefinition > 0 {
                    let length = try littleEndian(page[...], at: p, bytes: 4)
                    p += 4
                    guard p + length <= page.endIndex else { throw ParquetError.corrupt("definition levels run past their page") }
                    present = try hybrid(page[p..<p + length], bitWidth: 1, count: count).map { $0 == 1 }
                    p += length
                }
                let values = try decodeValues(page[p...], encoding: try info.int(2), type: leaf.type,
                                              count: present.map { $0.lazy.filter { $0 }.count } ?? count, dictionary: dictionary)
                try builder.append(values, present: present, count: count)
                read += count
            case 3: // Data page v2: [repetition levels][definition levels] uncompressed, then the values, maybe compressed.
                let info = try header.structure(8)
                let count = try info.int(1)
                let defLength = try info.int(5)
                let repLength = try info.int(6)
                guard repLength == 0 else { throw ParquetError.unsupported("repeated column \(leaf.name)") }
                guard defLength >= 0, defLength <= raw.count else { throw ParquetError.corrupt("definition levels run past their page") }
                var present: [Bool]?
                if leaf.maxDefinition > 0 {
                    present = try hybrid(raw.prefix(defLength), bitWidth: 1, count: count).map { $0 == 1 }
                }
                let rest = raw.dropFirst(defLength)
                let valuesData: ArraySlice<UInt8>
                if info[7]?.bool ?? true {
                    valuesData = try decompress(rest, codec: chunk.codec, size: uncompressed - defLength)[...]
                } else {
                    valuesData = rest
                }
                let values = try decodeValues(valuesData, encoding: try info.int(4), type: leaf.type,
                                              count: present.map { $0.lazy.filter { $0 }.count } ?? count, dictionary: dictionary)
                try builder.append(values, present: present, count: count)
                read += count
            default: // Index pages and anything newer carry no values.
                break
            }
            pos = pageEnd
        }
        guard read == chunk.valueCount else { throw ParquetError.corrupt("column \(leaf.name) ended after \(read) of \(chunk.valueCount) values") }
    }

    private static func decompress(_ raw: ArraySlice<UInt8>, codec: Int, size: Int) throws -> [UInt8] {
        switch codec {
        case 0: return Array(raw)
        case 1:
            let out = try Snappy.decompress(raw)
            guard out.count == size else { throw ParquetError.corrupt("a page decompressed to \(out.count) bytes, not \(size)") }
            return out
        default:
            throw ParquetError.unsupported("compression codec \(codec) (only Snappy and none are read)")
        }
    }

    private static func decodeValues(_ data: ArraySlice<UInt8>, encoding: Int, type: Int, count: Int,
                                     dictionary: PlainValues?) throws -> PlainValues {
        switch encoding {
        case 0: // PLAIN
            return try plain(data, type: type, count: count)
        case 2, 8: // PLAIN_DICTIONARY, RLE_DICTIONARY: a bit width byte, then indices into the dictionary page.
            guard let dictionary else { throw ParquetError.corrupt("dictionary-encoded page without a dictionary") }
            guard count > 0 else { return dictionary.picking([]) }
            guard let width = data.first, width <= 32 else { throw ParquetError.corrupt("bad dictionary index width") }
            let indices = try hybrid(data.dropFirst(), bitWidth: Int(width), count: count)
            guard indices.allSatisfy({ Int($0) < dictionary.count }) else { throw ParquetError.corrupt("dictionary index out of range") }
            return dictionary.picking(indices)
        case 3 where type == PhysicalType.boolean: // RLE booleans (v2 pages): length-prefixed hybrid of width 1.
            let length = try littleEndian(data, at: data.startIndex, bytes: 4)
            let body = data.dropFirst(4)
            guard length <= body.count else { throw ParquetError.corrupt("boolean run past its page") }
            return .bool(try hybrid(body.prefix(length), bitWidth: 1, count: count).map { $0 == 1 })
        default:
            throw ParquetError.unsupported("value encoding \(encoding)")
        }
    }

    private static func plain(_ data: ArraySlice<UInt8>, type: Int, count: Int) throws -> PlainValues {
        var p = data.startIndex
        func need(_ n: Int) throws {
            guard n >= 0, p + n <= data.endIndex else { throw ParquetError.corrupt("plain values run past their page") }
        }
        switch type {
        case PhysicalType.boolean:
            try need((count + 7) / 8)
            return .bool((0..<count).map { i in (data[p + i / 8] >> UInt8(i % 8)) & 1 == 1 })
        case PhysicalType.int32:
            try need(count * 4)
            return .int32((0..<count).map { i in Int32(bitPattern: UInt32(truncatingIfNeeded: word(data, p + i * 4, 4))) })
        case PhysicalType.int64:
            try need(count * 8)
            return .int64((0..<count).map { i in Int64(bitPattern: word(data, p + i * 8, 8)) })
        case PhysicalType.float:
            try need(count * 4)
            return .float((0..<count).map { i in Float(bitPattern: UInt32(truncatingIfNeeded: word(data, p + i * 4, 4))) })
        case PhysicalType.double:
            try need(count * 8)
            return .double((0..<count).map { i in Double(bitPattern: word(data, p + i * 8, 8)) })
        case PhysicalType.byteArray:
            var strings: [String] = []
            strings.reserveCapacity(count)
            for _ in 0..<count {
                try need(4)
                let length = Int(word(data, p, 4))
                p += 4
                try need(length)
                strings.append(String(decoding: data[p..<p + length], as: UTF8.self))
                p += length
            }
            return .string(strings)
        default:
            throw ParquetError.unsupported("physical type \(type)")
        }
    }

    /// The RLE / bit-packed hybrid encoding of definition levels, dictionary indices and RLE booleans.
    static func hybrid(_ data: ArraySlice<UInt8>, bitWidth: Int, count: Int) throws -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(count)
        var p = data.startIndex
        let byteWidth = (bitWidth + 7) / 8
        let mask: UInt64 = bitWidth == 0 ? 0 : (1 << UInt64(bitWidth)) - 1
        while out.count < count {
            guard p < data.endIndex else { throw ParquetError.corrupt("encoded values ended early") }
            var header: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard p < data.endIndex, shift < 64 else { throw ParquetError.corrupt("bad run header") }
                let b = data[p]
                p += 1
                header |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { break }
                shift += 7
            }
            if header & 1 == 1 { // Bit-packed: groups of 8 values, least significant bit first.
                let values = Int(header >> 1) * 8
                let length = Int(header >> 1) * bitWidth
                guard p + length <= data.endIndex else { throw ParquetError.corrupt("bit-packed run past its data") }
                for i in 0..<min(values, count - out.count) {
                    let bit = i * bitWidth
                    let first = p + bit / 8
                    var window: UInt64 = 0
                    for k in 0..<min(8, p + length - first) { window |= UInt64(data[first + k]) << UInt64(8 * k) }
                    out.append(UInt32(truncatingIfNeeded: (window >> UInt64(bit % 8)) & mask))
                }
                p += length
            } else { // A run of one value.
                let run = Int(header >> 1)
                guard p + byteWidth <= data.endIndex else { throw ParquetError.corrupt("RLE run past its data") }
                let value = UInt32(truncatingIfNeeded: word(data, p, byteWidth))
                out.append(contentsOf: repeatElement(value, count: min(run, count - out.count)))
                p += byteWidth
            }
        }
        return out
    }

    private static func littleEndian(_ data: ArraySlice<UInt8>, at p: Int, bytes n: Int) throws -> Int {
        guard p >= data.startIndex, p + n <= data.endIndex else { throw ParquetError.corrupt("a length runs past its page") }
        return Int(word(data, p, n))
    }

    /// `n` bytes from `p`, little-endian (callers check bounds).
    private static func word(_ data: ArraySlice<UInt8>, _ p: Int, _ n: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<n { v |= UInt64(data[p + k]) << UInt64(8 * k) }
        return v
    }
}

// MARK: - Results

public enum ParquetError: LocalizedError, Equatable {
    case notParquet
    case corrupt(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notParquet: "The file isn't a Parquet file."
        case .corrupt(let why): "The Parquet file is damaged: \(why)."
        case .unsupported(let what): "The Parquet file uses something this app doesn't read: \(what)."
        }
    }
}

/// One column's values, a missing value as nil.
public enum ParquetColumn: Sendable, Equatable {
    case bool([Bool?])
    case int32([Int32?])
    case int64([Int64?])
    case float([Float?])
    case double([Double?])
    case string([String?])
}

public struct ParquetTable: Sendable, Equatable {
    public let rowCount: Int
    public let columns: [String: ParquetColumn]

    /// Any numeric column as doubles.
    public func doubles(_ name: String) -> [Double?]? {
        switch columns[name] {
        case .double(let v): v
        case .float(let v): v.map { $0.map(Double.init) }
        case .int64(let v): v.map { $0.map(Double.init) }
        case .int32(let v): v.map { $0.map(Double.init) }
        default: nil
        }
    }

    /// Any integer column as Ints.
    public func ints(_ name: String) -> [Int?]? {
        switch columns[name] {
        case .int64(let v): v.map { $0.map { Int(truncatingIfNeeded: $0) } }
        case .int32(let v): v.map { $0.map(Int.init) }
        default: nil
        }
    }

    public func strings(_ name: String) -> [String?]? {
        if case .string(let v) = columns[name] { v } else { nil }
    }

    public func bools(_ name: String) -> [Bool?]? {
        if case .bool(let v) = columns[name] { v } else { nil }
    }
}

// MARK: - Internals

private enum PhysicalType {
    static let boolean = 0, int32 = 1, int64 = 2, int96 = 3, float = 4, double = 5, byteArray = 6, fixedLength = 7
}

/// Values without gaps, as a page or a dictionary holds them.
private enum PlainValues {
    case bool([Bool])
    case int32([Int32])
    case int64([Int64])
    case float([Float])
    case double([Double])
    case string([String])

    var count: Int {
        switch self {
        case .bool(let v): v.count
        case .int32(let v): v.count
        case .int64(let v): v.count
        case .float(let v): v.count
        case .double(let v): v.count
        case .string(let v): v.count
        }
    }

    func picking(_ indices: [UInt32]) -> PlainValues {
        switch self {
        case .bool(let v): .bool(indices.map { v[Int($0)] })
        case .int32(let v): .int32(indices.map { v[Int($0)] })
        case .int64(let v): .int64(indices.map { v[Int($0)] })
        case .float(let v): .float(indices.map { v[Int($0)] })
        case .double(let v): .double(indices.map { v[Int($0)] })
        case .string(let v): .string(indices.map { v[Int($0)] })
        }
    }
}

/// Gathers a column's pages, putting the gaps back where the definition levels say.
private struct ColumnBuilder {
    private(set) var column: ParquetColumn
    private(set) var count = 0

    init(type: Int) {
        column = switch type {
        case PhysicalType.boolean: .bool([])
        case PhysicalType.int32: .int32([])
        case PhysicalType.float: .float([])
        case PhysicalType.double: .double([])
        case PhysicalType.byteArray: .string([])
        default: .int64([])
        }
    }

    mutating func append(_ values: PlainValues, present: [Bool]?, count n: Int) throws {
        func spread<T>(_ v: [T]) throws -> [T?] {
            guard let present else {
                guard v.count == n else { throw ParquetError.corrupt("a page has \(v.count) values for \(n) rows") }
                return v
            }
            var out: [T?] = []
            out.reserveCapacity(n)
            var next = 0
            for isPresent in present {
                if isPresent {
                    guard next < v.count else { throw ParquetError.corrupt("fewer values than definition levels") }
                    out.append(v[next])
                    next += 1
                } else {
                    out.append(nil)
                }
            }
            return out
        }
        switch (column, values) {
        case (.bool(let a), .bool(let v)): column = try .bool(a + spread(v))
        case (.int32(let a), .int32(let v)): column = try .int32(a + spread(v))
        case (.int64(let a), .int64(let v)): column = try .int64(a + spread(v))
        case (.float(let a), .float(let v)): column = try .float(a + spread(v))
        case (.double(let a), .double(let v)): column = try .double(a + spread(v))
        case (.string(let a), .string(let v)): column = try .string(a + spread(v))
        default: throw ParquetError.corrupt("a page's values don't match its column's type")
        }
        count += n
    }
}

private struct Leaf {
    let name: String
    let type: Int
    let maxDefinition: Int
}

private struct ChunkMetadata {
    let codec: Int
    let valueCount: Int
    let compressedSize: Int
    let dataPageOffset: Int
    let dictionaryPageOffset: Int?
}

/// The footer: `[metadata][4-byte length]PAR1`, the metadata in Thrift's compact protocol.
private struct FileMetadata {
    let rowCount: Int
    let leaves: [Leaf]
    let rowGroups: [[ChunkMetadata]]

    init(_ bytes: [UInt8]) throws {
        let magic: [UInt8] = Array("PAR1".utf8)
        guard bytes.count >= 12, Array(bytes.prefix(4)) == magic, Array(bytes.suffix(4)) == magic else {
            throw ParquetError.notParquet
        }
        var length = 0
        for k in 0..<4 { length |= Int(bytes[bytes.count - 8 + k]) << (8 * k) }
        let start = bytes.count - 8 - length
        guard length > 0, start >= 4 else { throw ParquetError.corrupt("bad footer length") }
        var thrift = ThriftReader(bytes, at: start)
        let meta = try thrift.readStruct()

        let schema = try meta.list(2).map { try $0.asStruct() }
        guard let root = schema.first else { throw ParquetError.corrupt("empty schema") }
        let elements = schema.dropFirst()
        guard (try? root.int(5)) == elements.count, elements.allSatisfy({ $0[5] == nil }) else {
            throw ParquetError.unsupported("nested columns")
        }
        leaves = try elements.map { element in
            let repetition = element[3]?.int ?? 0
            guard repetition != 2 else { throw ParquetError.unsupported("repeated columns") }
            return Leaf(name: try element.string(4), type: try element.int(1), maxDefinition: repetition == 1 ? 1 : 0)
        }
        rowCount = try meta.int(3)
        rowGroups = try meta.list(4).map { group in
            try group.asStruct().list(1).map { chunk in
                let c = try chunk.asStruct()
                if c[1] != nil { throw ParquetError.unsupported("columns stored in other files") }
                let m = try c.structure(3)
                return ChunkMetadata(codec: try m.int(4), valueCount: try m.int(5), compressedSize: try m.int(7),
                                     dataPageOffset: try m.int(9), dictionaryPageOffset: m[11]?.int)
            }
        }
    }
}

// MARK: - Thrift compact protocol

private indirect enum Thrift {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case binary(ArraySlice<UInt8>)
    case list([Thrift])
    case structure([Int16: Thrift])

    var int: Int? { if case .int(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }

    func asStruct() throws -> [Int16: Thrift] {
        guard case .structure(let s) = self else { throw ParquetError.corrupt("expected a struct in the metadata") }
        return s
    }
}

private extension Dictionary where Key == Int16, Value == Thrift {
    func int(_ id: Int16) throws -> Int {
        guard let v = self[id]?.int else { throw ParquetError.corrupt("metadata field \(id) is missing") }
        return v
    }

    func structure(_ id: Int16) throws -> [Int16: Thrift] {
        guard let v = self[id] else { throw ParquetError.corrupt("metadata field \(id) is missing") }
        return try v.asStruct()
    }

    func list(_ id: Int16) throws -> [Thrift] {
        guard case .list(let v)? = self[id] else { throw ParquetError.corrupt("metadata field \(id) is missing") }
        return v
    }

    func string(_ id: Int16) throws -> String {
        guard case .binary(let v)? = self[id] else { throw ParquetError.corrupt("metadata field \(id) is missing") }
        return String(decoding: v, as: UTF8.self)
    }
}

private struct ThriftReader {
    let bytes: [UInt8]
    var pos: Int

    init(_ bytes: [UInt8], at pos: Int) {
        self.bytes = bytes
        self.pos = pos
    }

    mutating func readStruct(depth: Int = 0) throws -> [Int16: Thrift] {
        guard depth < 32 else { throw ParquetError.corrupt("metadata nested too deeply") }
        var fields: [Int16: Thrift] = [:]
        var last: Int16 = 0
        while true {
            let header = try byte()
            if header == 0 { return fields }
            let delta = Int16(header >> 4)
            let id = delta != 0 ? last &+ delta : Int16(truncatingIfNeeded: try zigzag())
            last = id
            fields[id] = try value(type: header & 0x0f, inField: true, depth: depth)
        }
    }

    private mutating func value(type: UInt8, inField: Bool, depth: Int) throws -> Thrift {
        switch type {
        case 1, 2:
            if inField { return .bool(type == 1) }
            return .bool(try byte() == 1)
        case 3: return .int(Int(Int8(bitPattern: try byte())))
        case 4, 5, 6: return .int(Int(truncatingIfNeeded: try zigzag()))
        case 7:
            guard pos + 8 <= bytes.count else { throw ParquetError.corrupt("metadata ended early") }
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(bytes[pos + k]) << UInt64(8 * k) }
            pos += 8
            return .double(Double(bitPattern: bits))
        case 8:
            let length = Int(try varint())
            guard length <= bytes.count - pos else { throw ParquetError.corrupt("metadata ended early") }
            defer { pos += length }
            return .binary(bytes[pos..<pos + length])
        case 9, 10:
            let header = try byte()
            var size = Int(header >> 4)
            if size == 15 { size = Int(try varint()) }
            guard size <= bytes.count - pos else { throw ParquetError.corrupt("metadata list too long") }
            return .list(try (0..<size).map { _ in try value(type: header & 0x0f, inField: false, depth: depth + 1) })
        case 11:
            let size = Int(try varint())
            guard size <= bytes.count - pos else { throw ParquetError.corrupt("metadata map too long") }
            guard size > 0 else { return .list([]) }
            let types = try byte()
            var items: [Thrift] = []
            for _ in 0..<size {
                items.append(try value(type: types >> 4, inField: false, depth: depth + 1))
                items.append(try value(type: types & 0x0f, inField: false, depth: depth + 1))
            }
            return .list(items)
        case 12:
            return .structure(try readStruct(depth: depth + 1))
        default:
            throw ParquetError.corrupt("unknown metadata type \(type)")
        }
    }

    private mutating func byte() throws -> UInt8 {
        guard pos < bytes.count else { throw ParquetError.corrupt("metadata ended early") }
        defer { pos += 1 }
        return bytes[pos]
    }

    private mutating func varint() throws -> UInt64 {
        var v: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try byte()
            guard shift < 64 else { throw ParquetError.corrupt("bad number in the metadata") }
            v |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return v }
            shift += 7
        }
    }

    private mutating func zigzag() throws -> Int64 {
        let v = try varint()
        return Int64(bitPattern: v >> 1) ^ -Int64(bitPattern: v & 1)
    }
}

// MARK: - Snappy

/// Snappy's block format (https://github.com/google/snappy/blob/main/format_description.txt), which Parquet pages use.
enum Snappy {
    static func decompress(_ src: ArraySlice<UInt8>) throws -> [UInt8] {
        var p = src.startIndex
        var length = 0
        var shift = 0
        while true {
            guard p < src.endIndex, shift <= 28 else { throw ParquetError.corrupt("bad Snappy length") }
            let b = src[p]
            p += 1
            length |= Int(b & 0x7f) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        var out: [UInt8] = []
        out.reserveCapacity(length)
        func le(_ n: Int) throws -> Int {
            guard p + n <= src.endIndex else { throw ParquetError.corrupt("Snappy data ended early") }
            var v = 0
            for k in 0..<n { v |= Int(src[p + k]) << (8 * k) }
            p += n
            return v
        }
        while p < src.endIndex {
            let tag = src[p]
            p += 1
            let copyLength: Int
            let offset: Int
            switch tag & 3 {
            case 0: // Literal.
                var n = Int(tag >> 2)
                if n >= 60 { n = try le(n - 59) }
                n += 1
                guard p + n <= src.endIndex, out.count + n <= length else { throw ParquetError.corrupt("Snappy literal too long") }
                out.append(contentsOf: src[p..<p + n])
                p += n
                continue
            case 1:
                copyLength = Int((tag >> 2) & 7) + 4
                let low = try le(1)
                offset = (Int(tag >> 5) << 8) | low
            case 2:
                copyLength = Int(tag >> 2) + 1
                offset = try le(2)
            default:
                copyLength = Int(tag >> 2) + 1
                offset = try le(4)
            }
            guard offset > 0, offset <= out.count, out.count + copyLength <= length else {
                throw ParquetError.corrupt("bad Snappy copy")
            }
            let from = out.count - offset
            if offset >= copyLength {
                out.append(contentsOf: out[from..<from + copyLength])
            } else { // Overlapping: repeats the last `offset` bytes.
                for k in 0..<copyLength { out.append(out[from + k]) }
            }
        }
        guard out.count == length else { throw ParquetError.corrupt("Snappy data is \(out.count) bytes, not \(length)") }
        return out
    }
}
