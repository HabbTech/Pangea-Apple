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

	/// Luhn mod 32: catches any single wrong character and adjacent swaps.
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

	/// Uppercases, drops "@", dashes and spaces, and maps look-alike letters.
	private static func normalize(_ text: String) -> [Character] {
		text.uppercased().compactMap { char -> Character? in
			switch char {
			case "@", "-", " ", "_": return nil
			case "O": return "0"
			case "I", "L": return "1"
			default: return char
			}
		}
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
		let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return nil }

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
