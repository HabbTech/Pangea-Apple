//
//  ProfileCard.swift
//  Pangea
//
//  What Pangea users share about themselves, and the small binary messages that
//  carry it. Everything rides on PRIVATE_APP, which other Meshtastic apps ignore.
//
//  Card     "PGP1" color(1) photoVersion(4) emojiLen(1) emoji nameLen(1) name   ≤ ~115 bytes
//  Request  "PGQ2" photoVersion(4) [bitmap of wanted chunks; none = all]
//  Chunk    "PGC1" photoVersion(4) index(1) count(1) bytes
//

import Foundation
import CryptoKit

struct ProfileCard: Equatable, Codable {
	var displayName: String
	var emoji: String
	var color: UInt8
	/// 0 when there's no photo; otherwise a hash of the photo's bytes.
	var photoVersion: UInt32

	static let maxNameBytes = 64
	/// Room for skin-tone pairs like 🧑🏻‍🤝‍🧑🏿.
	static let maxEmojiBytes = 40

	static func clamp(_ text: String, bytes: Int) -> String {
		var value = text
		while value.utf8.count > bytes {
			value = String(value.dropLast())
		}
		return value
	}

	/// Changes whenever anything on the card changes, so we know who has the latest one.
	var version: UInt32 {
		PangeaWire.hash(payload ?? Data())
	}

	var payload: Data? {
		let emoji = Data(Self.clamp(self.emoji, bytes: Self.maxEmojiBytes).utf8)
		let name = Data(Self.clamp(displayName, bytes: Self.maxNameBytes).utf8)
		var data = PangeaWire.cardMagic
		data.append(color)
		data.append(PangeaWire.bytes(photoVersion))
		data.append(UInt8(emoji.count))
		data.append(emoji)
		data.append(UInt8(name.count))
		data.append(name)
		return data
	}

	init(displayName: String, emoji: String, color: UInt8, photoVersion: UInt32) {
		self.displayName = displayName
		self.emoji = emoji
		self.color = color
		self.photoVersion = photoVersion
	}

	init?(payload: Data) {
		guard payload.starts(with: PangeaWire.cardMagic) else { return nil }
		var reader = PangeaWire.Reader(Data(payload.dropFirst(PangeaWire.cardMagic.count)))
		guard let color = reader.byte(),
			  let photoVersion = reader.uint32(),
			  let emojiLen = reader.byte(), let emoji = reader.take(Int(emojiLen)),
			  let nameLen = reader.byte(), let name = reader.take(Int(nameLen)),
			  emoji.count <= Self.maxEmojiBytes, name.count <= Self.maxNameBytes else { return nil }
		self.init(
			displayName: String(decoding: name, as: UTF8.self),
			emoji: String(decoding: emoji, as: UTF8.self),
			color: color,
			photoVersion: photoVersion
		)
	}
}

struct PhotoRequest: Equatable {
	var photoVersion: UInt32
	/// Chunk indexes wanted; nil means the whole photo.
	var wanted: Set<UInt8>?

	/// Bitmap of wanted chunks after the version; no bitmap means everything.
	var payload: Data {
		var data = PangeaWire.requestMagic + PangeaWire.bytes(photoVersion)
		if let wanted, let highest = wanted.max() {
			var bitmap = [UInt8](repeating: 0, count: Int(highest) / 8 + 1)
			for index in wanted {
				bitmap[Int(index) / 8] |= 1 << (index % 8)
			}
			data.append(contentsOf: bitmap)
		}
		return data
	}

	init(photoVersion: UInt32, wanted: Set<UInt8>? = nil) {
		self.photoVersion = photoVersion
		self.wanted = wanted
	}

	init?(payload: Data) {
		guard payload.starts(with: PangeaWire.requestMagic) else { return nil }
		var reader = PangeaWire.Reader(Data(payload.dropFirst(PangeaWire.requestMagic.count)))
		guard let version = reader.uint32() else { return nil }
		let bitmap = reader.rest()
		guard bitmap.count <= (PhotoChunk.maxChunks + 7) / 8 else { return nil }
		var wanted: Set<UInt8>?
		if !bitmap.isEmpty {
			var set = Set<UInt8>()
			for (byteIndex, byte) in bitmap.enumerated() {
				for bit in 0..<8 where byte & (1 << bit) != 0 {
					set.insert(UInt8(byteIndex * 8 + bit))
				}
			}
			wanted = set
		}
		self.init(photoVersion: version, wanted: wanted)
	}

	func wants(_ index: UInt8) -> Bool {
		wanted?.contains(index) ?? true
	}
}

struct PhotoChunk: Equatable {
	var photoVersion: UInt32
	var index: UInt8
	var count: UInt8
	var bytes: Data

	/// Leaves room for PKI overhead inside a single LoRa packet.
	static let maxBytes = 180
	/// 80 × 180 bytes ≈ 14 KB, enough for a 256 px photo.
	static let maxChunks = 80

	var payload: Data {
		PangeaWire.chunkMagic + PangeaWire.bytes(photoVersion) + Data([index, count]) + bytes
	}

	init(photoVersion: UInt32, index: UInt8, count: UInt8, bytes: Data) {
		self.photoVersion = photoVersion
		self.index = index
		self.count = count
		self.bytes = bytes
	}

	init?(payload: Data) {
		guard payload.starts(with: PangeaWire.chunkMagic) else { return nil }
		var reader = PangeaWire.Reader(Data(payload.dropFirst(PangeaWire.chunkMagic.count)))
		guard let version = reader.uint32(), let index = reader.byte(), let count = reader.byte(),
			  count > 0, Int(count) <= Self.maxChunks, index < count else { return nil }
		self.init(photoVersion: version, index: index, count: count, bytes: reader.rest())
	}

	static func split(_ photo: Data) -> [PhotoChunk] {
		let version = PangeaWire.hash(photo)
		let pieces = stride(from: 0, to: photo.count, by: maxBytes).map { photo[$0..<min($0 + maxBytes, photo.count)] }
		guard !pieces.isEmpty, pieces.count <= maxChunks else { return [] }
		return pieces.enumerated().map { index, piece in
			PhotoChunk(photoVersion: version, index: UInt8(index), count: UInt8(pieces.count), bytes: Data(piece))
		}
	}

	/// Nil until every piece is there and the result matches the version it claims.
	static func assemble(_ chunks: [UInt8: Data], count: UInt8, version: UInt32) -> Data? {
		guard chunks.count == Int(count) else { return nil }
		var photo = Data()
		for index in 0..<count {
			guard let piece = chunks[index] else { return nil }
			photo.append(piece)
		}
		return PangeaWire.hash(photo) == version ? photo : nil
	}
}

enum PangeaWire {
	static let cardMagic = Data("PGP1".utf8)
	static let requestMagic = Data("PGQ2".utf8)
	static let chunkMagic = Data("PGC1".utf8)

	/// First four bytes of SHA-256, never 0 (0 means "no photo").
	static func hash(_ data: Data) -> UInt32 {
		let digest = Array(SHA256.hash(data: data))
		let value = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
		return value == 0 ? 1 : value
	}

	static func bytes(_ value: UInt32) -> Data {
		Data([UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
	}

	static func bytes(_ value: UInt16) -> Data {
		Data([UInt8(value >> 8), UInt8(value & 0xff)])
	}

	struct Reader {
		private let data: [UInt8]
		private var offset = 0

		init(_ data: Data) { self.data = Array(data) }

		mutating func byte() -> UInt8? {
			guard offset < data.count else { return nil }
			defer { offset += 1 }
			return data[offset]
		}

		mutating func take(_ count: Int) -> Data? {
			guard count >= 0, offset + count <= data.count else { return nil }
			defer { offset += count }
			return Data(data[offset..<offset + count])
		}

		mutating func uint16() -> UInt16? {
			guard let bytes = take(2) else { return nil }
			return UInt16(bytes[bytes.startIndex]) << 8 | UInt16(bytes[bytes.startIndex + 1])
		}

		mutating func uint32() -> UInt32? {
			guard let bytes = take(4) else { return nil }
			return bytes.reduce(0) { $0 << 8 | UInt32($1) }
		}

		mutating func rest() -> Data {
			defer { offset = data.count }
			return Data(data[min(offset, data.count)...])
		}
	}
}
