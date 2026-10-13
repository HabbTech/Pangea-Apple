//
//  PangeaCode.swift
//  Pangea
//
//  A person's @code is their radio's node number written in Crockford base32
//  with a check character, e.g. "@4KQ2-F9MX". Short enough to say out loud,
//  forgiving of O/0 and I/1 mix-ups, and a typo is caught instead of reaching
//  a stranger.
//
//  Links and QR codes carry the code plus the full contact (name + public key),
//  so scanning one connects instantly without a round trip over the mesh.
//

import Foundation
import MeshtasticProtobufs

enum PangeaCode {

	private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
	private static let dataLength = 7 // 7 × 5 bits covers a 32-bit node number

	static let scheme = "pangea"
	static let contactHost = "dm"

	// MARK: Code <-> node number

	/// "@4KQ2-F9MX"
	static func code(for nodeNum: Int64) -> String {
		let raw = rawCode(for: UInt32(truncatingIfNeeded: nodeNum))
		return "@" + raw.prefix(4) + "-" + raw.suffix(4)
	}

	/// Node number for a typed or pasted code, or nil if it isn't a valid code.
	static func nodeNum(from text: String) -> Int64? {
		guard let text = clean(text) else { return nil }
		let cleaned = normalize(text)
		guard cleaned.count == dataLength + 1 else { return nil }
		var value: UInt64 = 0
		var digits: [Int] = []
		for char in cleaned {
			guard let digit = alphabet.firstIndex(of: char) else { return nil }
			digits.append(digit)
		}
		for digit in digits.prefix(dataLength) {
			value = value << 5 | UInt64(digit)
		}
		guard value <= UInt64(UInt32.max),
			  checkDigit(for: Array(digits.prefix(dataLength))) == digits[dataLength],
			  isUsable(UInt32(value)) else { return nil }
		return Int64(value)
	}

	private static func rawCode(for nodeNum: UInt32) -> String {
		var digits = [Int](repeating: 0, count: dataLength)
		var value = UInt64(nodeNum)
		for index in stride(from: dataLength - 1, through: 0, by: -1) {
			digits[index] = Int(value & 31)
			value >>= 5
		}
		let check = checkDigit(for: digits)
		return String((digits + [check]).map { alphabet[$0] })
	}

	/// Luhn mod 32: catches any single wrong character, and every swap of two
	/// neighbouring characters except "0" with "Z" (as decimal Luhn misses 09 ↔ 90).
	/// Changing it would change everyone's code, so that one gap stays.
	private static func checkDigit(for digits: [Int]) -> Int {
		let base = alphabet.count
		var factor = 2
		var sum = 0
		for digit in digits.reversed() {
			let addend = factor * digit
			sum += addend / base + addend % base
			factor = factor == 2 ? 1 : 2
		}
		return (base - sum % base) % base
	}

	/// Uppercases, drops "@", dashes and spaces, and maps look-alike letters. Works on scalars,
	/// so the invisible characters a paste can bring (no-break spaces, zero-width and
	/// direction marks) are dropped instead of joining the letter next to them.
	private static func normalize(_ text: String) -> [Character] {
		text.uppercased().unicodeScalars.compactMap { scalar -> Character? in
			if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.properties.generalCategory == .format {
				return nil
			}
			switch scalar {
			case "@", "-", "_", "\u{2010}"..."\u{2015}", "\u{2212}": return nil
			case "O": return "0"
			case "I", "L": return "1"
			default: return Character(scalar)
			}
		}
	}

	/// The most a code, node ID or link can take up. Anything longer is refused before any
	/// other work, so a huge paste doesn't slow down every keystroke.
	private static let maxInputLength = 2048

	/// Sentence punctuation, quotes and brackets a code is often pasted with.
	private static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?\"'\u{201C}\u{201D}\u{2018}\u{2019}()[]<>")

	/// What a paste carries around a code: fullwidth forms fold to ASCII, invisible format
	/// characters (zero-width and direction marks) go, and so do whitespace, punctuation and
	/// quotes at either end, except a leading "!", which is the node ID form. Nil when it's
	/// too long to be a code at all.
	private static func clean(_ input: String) -> String? {
		guard input.utf8.count <= maxInputLength else { return nil }
		let scalars = Array(input.precomposedStringWithCompatibilityMapping.unicodeScalars
			.filter { $0.properties.generalCategory != .format })
		func isEdge(_ scalar: Unicode.Scalar) -> Bool {
			CharacterSet.whitespacesAndNewlines.contains(scalar) || edgePunctuation.contains(scalar)
		}
		var start = scalars.startIndex
		var end = scalars.endIndex
		while start < end, scalars[start] != "!", isEdge(scalars[start]) { start += 1 }
		while end > start, isEdge(scalars[end - 1]) { end -= 1 }
		return String(String.UnicodeScalarView(scalars[start..<end]))
	}

	/// Long enough to be a whole code (or link / node ID), so a "doesn't look right"
	/// message isn't shown while someone is still typing.
	static func looksComplete(_ input: String) -> Bool {
		// Too long for a code: it's whole, and wrong.
		guard let text = clean(input) else { return true }
		if text.contains("://") || text.hasPrefix("!") { return text.count >= 9 }
		return normalize(text).count >= dataLength + 1
	}

	/// 0 and broadcast aren't people; 1–3 are reserved by the firmware.
	private static func isUsable(_ num: UInt32) -> Bool {
		num > 3 && num != UInt32.max
	}

	// MARK: Invites

	/// Everything we learned from whatever the user typed, pasted or scanned.
	struct Invite: Equatable, Identifiable {
		var nodeNum: Int64
		/// Present when the invite came from a link or QR code.
		var contact: SharedContact?

		var id: Int64 { nodeNum }
		var code: String { PangeaCode.code(for: nodeNum) }
		var displayName: String? {
			guard let name = contact?.user.longName, !name.isEmpty else { return nil }
			return name
		}
	}

	/// Accepts "@4KQ2-F9MX", "4kq2f9mx", "!a1b2c3d4", pangea:// links and Meshtastic contact links.
	static func invite(from input: String) -> Invite? {
		guard let text = clean(input), !text.isEmpty else { return nil }

		if let url = URL(string: text), url.scheme != nil {
			return invite(from: url)
		}
		if text.hasPrefix("!"), let num = UInt32(text.dropFirst(), radix: 16), isUsable(num) {
			return Invite(nodeNum: Int64(num))
		}
		if let num = nodeNum(from: text) {
			return Invite(nodeNum: num)
		}
		return nil
	}

	static func invite(from url: URL) -> Invite? {
		let absolute = url.absoluteString
		if url.scheme?.lowercased() == scheme, url.host?.lowercased() == contactHost {
			let code = url.pathComponents.dropFirst().first ?? ""
			let contact = url.fragment.flatMap(decodeContact)
			if let contact, isUsable(contact.nodeNum) {
				// The code shown in the link has to be the person it opens.
				if !code.isEmpty, nodeNum(from: code) != Int64(contact.nodeNum) { return nil }
				return Invite(nodeNum: Int64(contact.nodeNum), contact: contact)
			}
			return nodeNum(from: code).map { Invite(nodeNum: $0) }
		}
		if absolute.lowercased().contains("meshtastic.org/v/#"),
		   let fragment = absolute.components(separatedBy: "#").last,
		   let contact = decodeContact(fragment),
		   isUsable(contact.nodeNum) {
			return Invite(nodeNum: Int64(contact.nodeNum), contact: contact)
		}
		return nil
	}

	/// pangea://dm/4KQ2F9MX#<SharedContact>
	static func link(nodeNum: Int64, user: User) -> URL? {
		var contact = SharedContact()
		contact.nodeNum = UInt32(truncatingIfNeeded: nodeNum)
		contact.user = user
		guard let data = try? contact.serializedData() else { return nil }
		let raw = rawCode(for: contact.nodeNum)
		return URL(string: "\(scheme)://\(contactHost)/\(raw)#\(data.base64EncodedString().base64ToBase64url())")
	}

	private static func decodeContact(_ fragment: String) -> SharedContact? {
		guard let data = Data(base64Encoded: fragment.base64urlToBase64()) else { return nil }
		return try? SharedContact(serializedBytes: data)
	}
}
