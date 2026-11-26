import Foundation

// VERIFY: ZIPFoundation reads these stored entries (MS-DOS "made by", no external attributes) like real packs.
/// Writes a plain ZIP (stored entries, no compression) so the tests can make packs, including hostile ones, without
/// depending on the library under test.
enum ZipBuilder {
    static func make(_ files: [(name: String, data: Data)]) -> Data {
        var archive = Data()
        var directory = Data()
        for file in files {
            let name = Data(file.name.utf8)
            let crc = crc32(file.data)
            let offset = UInt32(archive.count)

            // Local file header.
            archive.append(le: UInt32(0x0403_4B50))
            archive.append(le: UInt16(20)) // version needed
            archive.append(le: UInt16(0)) // flags
            archive.append(le: UInt16(0)) // method: stored
            archive.append(le: UInt16(0)) // time
            archive.append(le: UInt16(0x21)) // date: 1980-01-01
            archive.append(le: crc)
            archive.append(le: UInt32(file.data.count))
            archive.append(le: UInt32(file.data.count))
            archive.append(le: UInt16(name.count))
            archive.append(le: UInt16(0)) // extra length
            archive.append(name)
            archive.append(file.data)

            // Central directory entry.
            directory.append(le: UInt32(0x0201_4B50))
            directory.append(le: UInt16(20)) // made by
            directory.append(le: UInt16(20)) // version needed
            directory.append(le: UInt16(0))
            directory.append(le: UInt16(0))
            directory.append(le: UInt16(0))
            directory.append(le: UInt16(0x21))
            directory.append(le: crc)
            directory.append(le: UInt32(file.data.count))
            directory.append(le: UInt32(file.data.count))
            directory.append(le: UInt16(name.count))
            directory.append(le: UInt16(0)) // extra length
            directory.append(le: UInt16(0)) // comment length
            directory.append(le: UInt16(0)) // disk number
            directory.append(le: UInt16(0)) // internal attributes
            directory.append(le: UInt32(0)) // external attributes
            directory.append(le: offset)
            directory.append(name)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)

        // End of central directory.
        archive.append(le: UInt32(0x0605_4B50))
        archive.append(le: UInt16(0))
        archive.append(le: UInt16(0))
        archive.append(le: UInt16(files.count))
        archive.append(le: UInt16(files.count))
        archive.append(le: UInt32(directory.count))
        archive.append(le: directoryOffset)
        archive.append(le: UInt16(0))
        return archive
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

extension Data {
    fileprivate mutating func append<T: FixedWidthInteger>(le value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
