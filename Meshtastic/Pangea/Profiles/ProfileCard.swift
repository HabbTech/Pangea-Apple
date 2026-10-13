//
//  ProfileCard.swift
//  Pangea
//
//  What Pangea users share about themselves, and the small binary messages that
//  carry it. Everything rides on PRIVATE_APP, which other Meshtastic apps ignore.
//
//  Card      "PGP2" color(1) photoVersion(4) [pieces(1) partTag(8)×parts] emojiLen(1) emoji nameLen(1) name   ≤ ~150 bytes
//  Request   "PGQ3" photoVersion(4) [bitmap of wanted slots; none = all]
//  Manifest  "PGM1" photoVersion(4) part(1) pieceTag(8)×(up to 21)
//  Chunk     "PGC2" photoVersion(4) index(1) bytes
//  Card ask  "PGK1" (nothing after it): send me your card, privately
//
//  A photo goes out as its manifest parts, then its pieces; together they're its
//  "slots", numbered in that order. The card carries a tag for each manifest part,
//  each manifest part a tag for each piece, so every piece can be checked on arrival
//  against the card it was asked for, whichever channel it came in on. (The tag of
//  some bytes is the first 8 bytes of their SHA-256.)
//

import Foundation
import CryptoKit

struct ProfileCard: Equatable, Codable {
	var displayName: String
	var emoji: String
	var color: UInt8
	/// 0 when there's no photo; otherwise a hash of the photo's bytes.
	var photoVersion: UInt32
	/// How many pieces the photo comes in, and the tag of each part of its piece list.
	/// Empty when there's no photo.
	var photoPieces: UInt8 = 0
	var photoPartTags: [Data] = []

	static let maxNameBytes = 64
	/// Room for skin-tone pairs like 🧑🏻‍🤝‍🧑🏿.
	static let maxEmojiBytes = 40

	static func clamp(_ text: String, bytes: Int) -> String {
		text.clampedUTF8(bytes)
	}

	/// A name as shown: without invisible or direction-changing characters, spaces made
	/// plain, trimmed. "" when nothing visible is left, so callers fall back to the radio name.
	static func cleanName(_ name: String) -> String {
		let cleaned = name.cleanedName
		return cleaned.isBlankName ? "" : cleaned
	}

	/// One emoji the editor offers, or "" for anything else. Which sequences draw as a
	/// single emoji is a fixed list, not something the characters' properties tell.
	static func cleanEmoji(_ text: String) -> String {
		EmojiCatalog.contains(text) ? text : ""
	}

	/// The same card with its name and emoji cleaned, for cards stored before the rules
	/// were what they are now.
	var cleaned: ProfileCard {
		var card = self
		card.displayName = Self.cleanName(displayName)
		card.emoji = Self.cleanEmoji(emoji)
		return card
	}

	/// The card describes a photo that can be fetched and checked piece by piece.
	var hasPhotoLayout: Bool {
		photoVersion != 0 && photoPieces > 0 && Int(photoPieces) <= PhotoChunk.maxChunks
			&& photoPartTags.count == PhotoManifest.parts(forPieces: Int(photoPieces))
			&& photoPartTags.allSatisfy { $0.count == PangeaWire.tagBytes }
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
		// A photo that can't be described piece by piece isn't offered at all.
		if hasPhotoLayout {
			data.append(PangeaWire.bytes(photoVersion))
			data.append(photoPieces)
			for tag in photoPartTags { data.append(tag) }
		} else {
			data.append(PangeaWire.bytes(UInt32(0)))
		}
		data.append(UInt8(emoji.count))
		data.append(emoji)
		data.append(UInt8(name.count))
		data.append(name)
		return data
	}

	init(displayName: String, emoji: String, color: UInt8, photoVersion: UInt32, photoPieces: UInt8 = 0, photoPartTags: [Data] = []) {
		self.displayName = displayName
		self.emoji = emoji
		self.color = color
		self.photoVersion = photoVersion
		self.photoPieces = photoPieces
		self.photoPartTags = photoPartTags
	}

	/// My card, describing this photo when it's the one the version names.
	init(displayName: String, emoji: String, color: UInt8, photo: PhotoPieces?) {
		self.init(displayName: displayName, emoji: emoji, color: color, photoVersion: photo?.version ?? 0,
				  photoPieces: UInt8(photo?.chunks.count ?? 0), photoPartTags: photo?.partTags ?? [])
	}

	init?(payload: Data) {
		guard payload.starts(with: PangeaWire.cardMagic) else { return nil }
		var reader = PangeaWire.Reader(Data(payload.dropFirst(PangeaWire.cardMagic.count)))
		guard let color = reader.byte(), let photoVersion = reader.uint32() else { return nil }
		var pieces: UInt8 = 0
		var tags: [Data] = []
		if photoVersion != 0 {
			guard let count = reader.byte(), count > 0, Int(count) <= PhotoChunk.maxChunks else { return nil }
			pieces = count
			for _ in 0..<PhotoManifest.parts(forPieces: Int(count)) {
				guard let tag = reader.take(PangeaWire.tagBytes) else { return nil }
				tags.append(tag)
			}
		}
		guard let emojiLen = reader.byte(), let emoji = reader.take(Int(emojiLen)),
			  let nameLen = reader.byte(), let name = reader.take(Int(nameLen)),
			  emoji.count <= Self.maxEmojiBytes, name.count <= Self.maxNameBytes else { return nil }
		// Bytes that aren't UTF-8 count as no name (or no emoji), not as U+FFFD marks.
		self.init(
			displayName: Self.cleanName(String(bytes: name, encoding: .utf8) ?? ""),
			emoji: Self.cleanEmoji(String(bytes: emoji, encoding: .utf8) ?? ""),
			color: color,
			photoVersion: photoVersion,
			photoPieces: pieces,
			photoPartTags: tags
		)
	}
}

// Decoded field by field, so a card stored by an older version (no photo layout) still loads.
extension ProfileCard {
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		displayName = try container.decode(String.self, forKey: .displayName)
		emoji = container.tolerant(String.self, forKey: .emoji, decoder) ?? ""
		color = container.tolerant(UInt8.self, forKey: .color, decoder) ?? 0
		photoVersion = container.tolerant(UInt32.self, forKey: .photoVersion, decoder) ?? 0
		photoPieces = container.tolerant(UInt8.self, forKey: .photoPieces, decoder) ?? 0
		photoPartTags = container.tolerant([Data].self, forKey: .photoPartTags, decoder) ?? []
	}
}

/// Records that a stored value was there but couldn't be read, so the file can be
/// copied aside before it's rewritten without it.
final class DecodeLoss: @unchecked Sendable {
	var happened = false
}

extension CodingUserInfoKey {
	static let pangeaDecodeLoss = CodingUserInfoKey(rawValue: "pangeaDecodeLoss")!
}

extension KeyedDecodingContainer {
	/// The value, nil when it's absent, or nil (noting the loss) when it's there but unreadable.
	func tolerant<T: Decodable>(_ type: T.Type, forKey key: Key, _ decoder: Decoder) -> T? {
		do {
			return try decodeIfPresent(type, forKey: key)
		} catch {
			(decoder.userInfo[.pangeaDecodeLoss] as? DecodeLoss)?.happened = true
			return nil
		}
	}
}

struct PhotoRequest: Equatable {
	var photoVersion: UInt32
	/// Slots wanted (manifest parts first, then pieces); nil means the whole photo.
	var wanted: Set<UInt8>?

	/// Most slots a photo can have: every manifest part, then every piece.
	static let maxSlots = PhotoManifest.parts(forPieces: PhotoChunk.maxChunks) + PhotoChunk.maxChunks

	/// Bitmap of wanted slots after the version; no bitmap means everything.
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
		guard bitmap.count <= (Self.maxSlots + 7) / 8 else { return nil }
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

	func wants(_ slot: UInt8) -> Bool {
		wanted?.contains(slot) ?? true
	}
}

/// One part of a photo's piece list: the tag of each piece it covers.
struct PhotoManifest: Equatable {
	var photoVersion: UInt32
	var part: UInt8
	var tags: [Data]

	/// 21 × 8 bytes, the same room a piece gets.
	static let tagsPerPart = 21

	static func parts(forPieces count: Int) -> Int {
		(count + tagsPerPart - 1) / tagsPerPart
	}

	/// What the card carries for this part.
	var tag: Data {
		PangeaWire.tag(tags.reduce(Data(), +))
	}

	var payload: Data {
		tags.reduce(PangeaWire.manifestMagic + PangeaWire.bytes(photoVersion) + Data([part]), +)
	}

	init(photoVersion: UInt32, part: UInt8, tags: [Data]) {
		self.photoVersion = photoVersion
		self.part = part
		self.tags = tags
	}

	init?(payload: Data) {
		guard payload.starts(with: PangeaWire.manifestMagic) else { return nil }
		var reader = PangeaWire.Reader(Data(payload.dropFirst(PangeaWire.manifestMagic.count)))
		guard let version = reader.uint32(), let part = reader.byte(),
			  Int(part) < PhotoManifest.parts(forPieces: PhotoChunk.maxChunks) else { return nil }
		let rest = reader.rest()
		guard !rest.isEmpty, rest.count % PangeaWire.tagBytes == 0, rest.count / PangeaWire.tagBytes <= Self.tagsPerPart else { return nil }
		let tags = stride(from: 0, to: rest.count, by: PangeaWire.tagBytes).map { Data(rest[rest.startIndex + $0 ..< rest.startIndex + $0 + PangeaWire.tagBytes]) }
		self.init(photoVersion: version, part: part, tags: tags)
	}
}

struct PhotoChunk: Equatable {
	var photoVersion: UInt32
	var index: UInt8
	var bytes: Data

	/// Leaves room for PKI overhead inside a single LoRa packet.
	static let maxBytes = 180
	/// 80 × 180 bytes ≈ 14 KB, enough for a 256 px photo.
	static let maxChunks = 80

	var payload: Data {
		PangeaWire.chunkMagic + PangeaWire.bytes(photoVersion) + Data([index]) + bytes
	}

	init(photoVersion: UInt32, index: UInt8, bytes: Data) {
		self.photoVersion = photoVersion
		self.index = index
		self.bytes = bytes
	}

	init?(payload: Data) {
		guard payload.starts(with: PangeaWire.chunkMagic) else { return nil }
		var reader = PangeaWire.Reader(Data(payload.dropFirst(PangeaWire.chunkMagic.count)))
		guard let version = reader.uint32(), let index = reader.byte(), Int(index) < Self.maxChunks else { return nil }
		let bytes = reader.rest()
		guard !bytes.isEmpty, bytes.count <= Self.maxBytes else { return nil }
		self.init(photoVersion: version, index: index, bytes: bytes)
	}

	static func split(_ photo: Data) -> [PhotoChunk] {
		let version = PangeaWire.hash(photo)
		let pieces = stride(from: 0, to: photo.count, by: maxBytes).map { photo[$0..<min($0 + maxBytes, photo.count)] }
		guard !pieces.isEmpty, pieces.count <= maxChunks else { return [] }
		return pieces.enumerated().map { index, piece in
			PhotoChunk(photoVersion: version, index: UInt8(index), bytes: Data(piece))
		}
	}

	/// Nil until every piece is there and the result matches the version it claims.
	/// Pieces at or past `count` are ignored.
	static func assemble(_ chunks: [UInt8: Data], count: UInt8, version: UInt32) -> Data? {
		guard count > 0 else { return nil }
		var photo = Data()
		for index in 0..<count {
			guard let piece = chunks[index] else { return nil }
			photo.append(piece)
		}
		return PangeaWire.hash(photo) == version ? photo : nil
	}
}

/// My photo as it goes on the air: manifest parts first, then pieces.
struct PhotoPieces {
	let version: UInt32
	let chunks: [PhotoChunk]
	let manifest: [PhotoManifest]

	init?(photo: Data) {
		let chunks = PhotoChunk.split(photo)
		guard !chunks.isEmpty else { return nil }
		let version = PangeaWire.hash(photo)
		let tags = chunks.map { PangeaWire.tag($0.bytes) }
		self.version = version
		self.chunks = chunks
		self.manifest = stride(from: 0, to: tags.count, by: PhotoManifest.tagsPerPart).enumerated().map { part, start in
			PhotoManifest(photoVersion: version, part: UInt8(part), tags: Array(tags[start..<min(start + PhotoManifest.tagsPerPart, tags.count)]))
		}
	}

	var partTags: [Data] { manifest.map(\.tag) }

	var slotCount: Int { manifest.count + chunks.count }

	func payload(slot: UInt8) -> Data? {
		let slot = Int(slot)
		if slot < manifest.count { return manifest[slot].payload }
		let index = slot - manifest.count
		return index < chunks.count ? chunks[index].payload : nil
	}
}

extension String {
	/// The longest prefix of whole Characters that fits in `limit` UTF-8 bytes. One
	/// pass, so a pasted or received megabyte of text doesn't stall the main thread.
	func clampedUTF8(_ limit: Int) -> String {
		guard utf8.count > limit else { return self }
		var used = 0
		var end = startIndex
		for index in indices {
			let size = self[index].utf8.count
			if used + size > limit { break }
			used += size
			end = self.index(after: index)
		}
		return String(self[..<end])
	}

	// MARK: Names
	//
	// One rule for every name that's shown: people's names (theirs and mine), short
	// names, group names and emoji. A character is hidden when Unicode says it draws
	// nothing (control and format characters, line and paragraph separators, private-use
	// and unassigned code points, anything default-ignorable such as zero-width spaces,
	// soft hyphens, variation selectors, tags and the Hangul fillers) or it's a blank
	// that looks like a gap (U+2800 braille blank, U+FFFC). Hidden characters make text
	// look like something else: "admin" + a zero-width joiner, a blank-looking name, or a
	// direction override. A few are kept where visible text needs them:
	// - a zero-width joiner between two emoji (👨‍👩‍👧, 🏳️‍🌈), or between two letters
	//   or marks of a non-Latin script (Devanagari क्‍ष)
	// - a zero-width non-joiner between two such letters or marks (Persian می‌خواهم)
	// - an emoji or text variation selector right after an emoji (❤️)
	// - an ideographic variation selector right after an ideograph
	// - the tag characters of a subdivision flag (🏴󠁧󠁢󠁳󠁣󠁴󠁿): 🏴, tag letters, cancel tag
	// A combining mark at the very start, or right after a space, goes too: with nothing
	// to sit on it draws as a floating accent or a dotted circle.

	/// Without hidden characters. Spaces and line breaks are left as they are.
	var withoutHiddenCharacters: String {
		String(VisibleText.scalars(of: self, plainSpaces: false))
	}

	/// Hidden characters that can make it look like another name, or cut it short on the
	/// radio. A combining mark with nothing to sit on doesn't count: it shows, as a dotted
	/// circle, so a channel already named that way is still listed (an invite to one is
	/// still refused, by `cleanedName`).
	var hasHiddenCharacters: Bool {
		VisibleText.scalars(of: self, plainSpaces: false, dropStrayMarks: false).count != unicodeScalars.count
	}

	/// Without hidden characters, every kind of space or line break made one plain
	/// space, and trimmed. Idempotent.
	var cleanedName: String {
		String(VisibleText.scalars(of: self, plainSpaces: true)).trimmingCharacters(in: .whitespaces)
	}

	/// A name I typed for myself, as `cleanedName`, cut to fit in whole characters (a
	/// joiner left dangling by the cut goes too). "" when nothing visible is left.
	func cleanedName(fitting bytes: Int) -> String {
		cutName(fitting: bytes).name
	}

	/// `cleanedName(fitting:)`, and whether it's "" only because not even the first visible
	/// character fits (one emoji family is 25 bytes), as opposed to there being nothing.
	func cutName(fitting bytes: Int) -> (name: String, tooLong: Bool) {
		// Cleaning stops once the kept text is past the budget, so however much is pasted,
		// and however much of it is hidden, only what can survive the cut is kept.
		let start = String(VisibleText.scalars(of: self, plainSpaces: true, stopPast: bytes)).trimmingCharacters(in: .whitespaces)
		let cleaned = start.clampedUTF8(bytes).cleanedName
		if cleaned.isBlankName {
			return ("", !start.isBlankName)
		}
		return (cleaned, false)
	}

	/// Nothing to see: no letter, number, punctuation or symbol.
	var isBlankName: Bool {
		!contains { character in
			guard let base = character.unicodeScalars.first, !base.isHiddenByDefault else { return false }
			switch base.properties.generalCategory {
			case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
				 .decimalNumber, .letterNumber, .otherNumber,
				 .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
				 .initialPunctuation, .finalPunctuation, .otherPunctuation,
				 .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
				return true
			default:
				return false
			}
		}
	}
}

private enum VisibleText {
	/// The visible scalars of `text`. With `stopPast`, stops once what's kept is more than
	/// that many UTF-8 bytes (a single leading space, trimmed later, not counted): every
	/// scalar is judged only by what's kept before it and the one after it, so this is a
	/// prefix of the whole result, ending past the budget. `dropStrayMarks` drops a mark at
	/// the start or after a space.
	static func scalars(of text: String, plainSpaces: Bool, dropStrayMarks: Bool = true, stopPast limit: Int? = nil) -> String.UnicodeScalarView {
		let scalars = text.unicodeScalars
		var out = String.UnicodeScalarView()
		var bytes = 0
		func keep(_ scalar: Unicode.Scalar) {
			out.append(scalar)
			bytes += UTF8.width(scalar)
		}
		var i = scalars.startIndex
		while i < scalars.endIndex {
			if let limit, bytes - (out.first == " " ? 1 : 0) > limit { break }
			let scalar = scalars[i]
			let after = scalars.index(after: i)
			if scalar.properties.isWhitespace {
				if !plainSpaces {
					keep(scalar)
				} else if out.last != " " {
					keep(" ")
				}
				i = after
				continue
			}
			guard scalar.isHiddenByDefault else {
				// A mark with nothing to sit on draws as a floating accent or a dotted circle.
				if !dropStrayMarks || !scalar.isMark || !(out.last.map { $0.properties.isWhitespace } ?? true) {
					keep(scalar)
				}
				i = after
				continue
			}
			// Judged by what's kept before it and the visible character after it, so the
			// result is the same if it's cleaned again.
			let previous = out.last
			let next = after < scalars.endIndex && !scalars[after].isHiddenByDefault ? scalars[after] : nil
			switch scalar.value {
			case 0x200D:
				if let previous, let next,
				   (previous.isEmojiPart && next.properties.isEmoji && !next.isASCII)
					|| (previous.isScriptLetterOrMark && next.isScriptLetterOrMark) {
					keep(scalar)
				}
			case 0x200C:
				if let previous, let next, previous.isScriptLetterOrMark && next.isScriptLetterOrMark {
					keep(scalar)
				}
			case 0xFE0E, 0xFE0F:
				if let previous, previous.properties.isEmoji {
					keep(scalar)
				}
			case 0xFE00...0xFE0D, 0xE0100...0xE01EF:
				if let previous, previous.properties.isIdeographic {
					keep(scalar)
				}
			case 0xE0020...0xE007F:
				// The run of tag characters is kept whole if it's a subdivision flag, else dropped whole.
				var end = i
				while end < scalars.endIndex, scalars[end].isTagCharacter, scalars[end].value != 0xE007F {
					end = scalars.index(after: end)
				}
				let closed = end < scalars.endIndex && scalars[end].value == 0xE007F
				if closed, end > i, previous?.value == 0x1F3F4 {
					for tag in scalars[i...end] { keep(tag) }
				}
				i = closed ? scalars.index(after: end) : end
				continue
			default:
				break
			}
			i = after
		}
		return out
	}
}

private extension Unicode.Scalar {
	var isHiddenByDefault: Bool {
		switch properties.generalCategory {
		case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
			return true
		default:
			return properties.isDefaultIgnorableCodePoint || value == 0x2800 || value == 0xFFFC
		}
	}

	/// A letter or mark outside ASCII: the scripts that need joiners and non-joiners.
	var isScriptLetterOrMark: Bool {
		guard !isASCII else { return false }
		switch properties.generalCategory {
		case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
			 .nonspacingMark, .spacingMark, .enclosingMark:
			return true
		default:
			return false
		}
	}

	var isTagCharacter: Bool { (0xE0020...0xE007F).contains(value) }

	var isMark: Bool {
		switch properties.generalCategory {
		case .nonspacingMark, .spacingMark, .enclosingMark:
			return true
		default:
			return false
		}
	}

	var isEmojiPart: Bool {
		properties.isEmoji || properties.isEmojiModifier || value == 0xFE0F || value == 0x20E3 || isTagCharacter
	}
}

enum PangeaWire {
	static let cardMagic = Data("PGP2".utf8)
	static let requestMagic = Data("PGQ3".utf8)
	static let manifestMagic = Data("PGM1".utf8)
	static let chunkMagic = Data("PGC2".utf8)
	static let cardRequestMagic = Data("PGK1".utf8)

	static let tagBytes = 8

	/// First four bytes of SHA-256, never 0 (0 means "no photo").
	static func hash(_ data: Data) -> UInt32 {
		let digest = Array(SHA256.hash(data: data))
		let value = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
		return value == 0 ? 1 : value
	}

	/// First eight bytes of SHA-256: what pieces and manifest parts are checked against.
	static func tag(_ data: Data) -> Data {
		Data(SHA256.hash(data: data).prefix(tagBytes))
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
