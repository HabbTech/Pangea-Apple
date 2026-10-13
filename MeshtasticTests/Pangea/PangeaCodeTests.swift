//
//  PangeaCodeTests.swift
//  MeshtasticTests
//

import Foundation
import Testing
import MeshtasticProtobufs
@testable import Meshtastic

@Suite("PangeaCode")
// The CoreData tests use a main-queue context, so they must run on the main thread.
@MainActor
struct PangeaCodeTests {

	@Test(arguments: [Int64(4), 0x1A2B3C4D, 0xDEADBEEF, Int64(UInt32.max) - 1])
	func roundTrips(_ nodeNum: Int64) {
		let code = PangeaCode.code(for: nodeNum)
		#expect(PangeaCode.nodeNum(from: code) == nodeNum)
	}

	@Test func formatIsAtFourDashFour() {
		let code = PangeaCode.code(for: 0x1A2B3C4D)
		#expect(code.hasPrefix("@"))
		#expect(code.count == 10)
		#expect(Array(code)[5] == "-")
	}

	@Test func forgivingInput() throws {
		let code = PangeaCode.code(for: 0x1A2B3C4D)
		let bare = code.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: "-", with: "")
		#expect(PangeaCode.nodeNum(from: bare.lowercased()) == 0x1A2B3C4D)
		#expect(PangeaCode.nodeNum(from: " \(code) ") == 0x1A2B3C4D)
		// O and I/L are read as 0 and 1
		let lookalike = bare.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "1", with: "l")
		#expect(PangeaCode.nodeNum(from: lookalike) == 0x1A2B3C4D)
	}

	/// What a paste from a message or a web page can carry around a code.
	@Test func invisibleAndTypographicCharactersAreIgnored() {
		let code = PangeaCode.code(for: 0x1A2B3C4D)
		let raw = code.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: "-", with: "")
		let first = raw.prefix(4), last = raw.suffix(4)
		for pasted in ["@\(first)\u{2011}\(last)", "@\(first)\u{2013}\(last)", "\u{00A0}@\(first)-\(last)\u{00A0}",
					   "\u{200E}@\(first)\u{200B}-\(last)\u{202C}", "\u{FEFF}\(first)\u{200D}\(last)", "\(first)\t\(last)\n"] {
			#expect(PangeaCode.nodeNum(from: pasted) == 0x1A2B3C4D, "\(pasted.unicodeScalars.map { String($0.value, radix: 16) })")
		}
		// A mark that changes a letter still makes it a different, wrong code.
		#expect(PangeaCode.nodeNum(from: "\(first)\(last.dropLast())\(last.last!)\u{0301}") == nil)
	}

	/// "my code is @256T-ARZ6." copied out of a message, a quote, or a fullwidth keyboard.
	@Test func pastedPunctuationAndWidthFormsAreAccepted() {
		let nodeNum: Int64 = 0x8A6D2B1F
		let code = PangeaCode.code(for: nodeNum)
		#expect(code == "@256T-ARZ6")
		let fullwidth = String(String.UnicodeScalarView(code.unicodeScalars.map { Unicode.Scalar($0.value + 0xFEE0)! }))
		for pasted in ["\(code).", "\u{201C}\(code)\u{201D}", "\"\(code)\"", "(\(code))", "\(code)!", fullwidth,
					   "!8a6d\u{200B}2b1f", "\u{200E}!8a6d2b1f", "\u{201C}!8a6d2b1f\u{201D}.", "!８ａ６ｄ２ｂ１ｆ"] {
			#expect(PangeaCode.invite(from: pasted)?.nodeNum == nodeNum, "\(pasted.unicodeScalars.map { String($0.value, radix: 16) })")
			#expect(PangeaCode.looksComplete(pasted))
		}
		// Still a different, wrong code: a mark on a letter, or one wrong letter.
		#expect(PangeaCode.invite(from: "\(code)\u{0301}") == nil)
		#expect(PangeaCode.invite(from: "@256T-ARZ7.") == nil)
		#expect(PangeaCode.invite(from: "\u{FF20}256T-ARZ7") == nil)
	}

	/// A huge paste is turned down before any work, so typing next to it stays quick.
	@Test func hugePastesAreRefusedQuickly() {
		let code = PangeaCode.code(for: 0x8A6D2B1F)
		let huge = String(repeating: " ", count: 1_000_000) + code
		#expect(PangeaCode.invite(from: huge) == nil)
		#expect(PangeaCode.nodeNum(from: huge) == nil)
		#expect(PangeaCode.looksComplete(huge))
		let start = Date()
		for _ in 0..<100 { _ = PangeaCode.invite(from: huge); _ = PangeaCode.looksComplete(huge) }
		#expect(Date().timeIntervalSince(start) < 0.5)
	}

	@Test func everySingleTypoIsRejected() {
		let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
		let nodeNum: Int64 = 0x1A2B3C4D
		let raw = Array(PangeaCode.code(for: nodeNum).filter { $0 != "@" && $0 != "-" })
		for position in raw.indices {
			for replacement in alphabet where replacement != raw[position] {
				var typo = raw
				typo[position] = replacement
				let decoded = PangeaCode.nodeNum(from: String(typo))
				#expect(decoded == nil, "Typo at \(position) -> \(replacement) decoded to \(String(describing: decoded))")
			}
		}
	}

	@Test func neighbourSwapsAreRejected() {
		// The one pair Luhn mod 32 can't tell apart is "0" next to "Z".
		let blind: Set<Character> = ["0", "Z"]
		for nodeNum in stride(from: Int64(4), to: Int64(UInt32.max), by: 9_973_331) {
			let raw = Array(PangeaCode.code(for: nodeNum).filter { $0 != "@" && $0 != "-" })
			for position in raw.indices.dropLast() where raw[position] != raw[position + 1] {
				guard Set([raw[position], raw[position + 1]]) != blind else { continue }
				var swapped = raw
				swapped.swapAt(position, position + 1)
				#expect(PangeaCode.nodeNum(from: String(swapped)) == nil, "Swap at \(position) of \(String(raw)) was accepted")
			}
		}
	}

	@Test func codeOnlyLooksWrongOnceItsComplete() {
		#expect(!PangeaCode.looksComplete("@4KQ2-F9"))
		#expect(!PangeaCode.looksComplete("@4KQ2-F9M"))
		#expect(PangeaCode.looksComplete("@4KQ2-F9MX"))
		#expect(PangeaCode.looksComplete("4kq2f9mx"))
		#expect(!PangeaCode.looksComplete("!a1b2"))
		#expect(PangeaCode.looksComplete("!a1b2c3d4"))
	}

	@Test func rejectsReservedAndBroadcast() {
		#expect(PangeaCode.nodeNum(from: PangeaCode.code(for: 0)) == nil)
		#expect(PangeaCode.nodeNum(from: PangeaCode.code(for: Int64(UInt32.max))) == nil)
	}

	@Test func rejectsWrongLength() {
		#expect(PangeaCode.nodeNum(from: "@4KQ2") == nil)
		#expect(PangeaCode.nodeNum(from: "") == nil)
	}

	@Test func acceptsMeshtasticNodeId() {
		#expect(PangeaCode.invite(from: "!1a2b3c4d")?.nodeNum == 0x1A2B3C4D)
	}

	@Test func linkCarriesContact() throws {
		var user = User()
		user.longName = "Sam Rivera"
		user.shortName = "SR"
		user.publicKey = Data(repeating: 7, count: 32)
		let url = try #require(PangeaCode.link(nodeNum: 0x1A2B3C4D, user: user))
		#expect(url.scheme == "pangea")

		let invite = try #require(PangeaCode.invite(from: url))
		#expect(invite.nodeNum == 0x1A2B3C4D)
		#expect(invite.displayName == "Sam Rivera")
		#expect(invite.contact?.user.publicKey == user.publicKey)

		// Same thing pasted as text
		#expect(PangeaCode.invite(from: url.absoluteString)?.nodeNum == 0x1A2B3C4D)
	}

	@Test func linkWithoutContactFallsBackToCode() throws {
		let code = PangeaCode.code(for: 0x1A2B3C4D).filter { $0 != "@" && $0 != "-" }
		let url = try #require(URL(string: "pangea://dm/\(code)"))
		let invite = try #require(PangeaCode.invite(from: url))
		#expect(invite.nodeNum == 0x1A2B3C4D)
		#expect(invite.contact == nil)
	}

	@Test func linkWhoseCodeIsSomeoneElseIsRefused() throws {
		var user = User()
		user.longName = "Sam Rivera"
		let real = try #require(PangeaCode.link(nodeNum: 0x1A2B3C4D, user: user))
		let otherCode = PangeaCode.code(for: 0xDEADBEEF).filter { $0 != "@" && $0 != "-" }
		let fragment = try #require(real.fragment)
		let forged = try #require(URL(string: "pangea://dm/\(otherCode)#\(fragment)"))
		#expect(PangeaCode.invite(from: forged) == nil)
		// No code in the path: the contact alone decides.
		let bare = try #require(URL(string: "pangea://dm/#\(fragment)"))
		#expect(PangeaCode.invite(from: bare)?.nodeNum == 0x1A2B3C4D)
	}

	@Test func shortNamesSkipInitialsThatDontFit() {
		#expect(RadioAutoConfig.shortName(for: "Mary Jo Kim") == "MJK")
		#expect(RadioAutoConfig.shortName(for: "🇺🇸 Andy") == "A")
		#expect(RadioAutoConfig.shortName(for: "🇺🇸Andy") == "ANDY")
		#expect(RadioAutoConfig.shortName(for: "🇺🇸") == "ME")
		#expect(RadioAutoConfig.shortName(for: "Sam") == "SAM")
	}

	@Test func ignoresUnrelatedLinks() throws {
		#expect(PangeaCode.invite(from: try #require(URL(string: "https://example.com/dm/ABC"))) == nil)
		#expect(PangeaCode.invite(from: "hello there") == nil)
	}

	@Test func pairingCodeIsTurnedOffOnceSettingsAreKnown() {
		let random = Int32(Config.BluetoothConfig.PairingMode.randomPin.rawValue)
		let fixed = Int32(Config.BluetoothConfig.PairingMode.fixedPin.rawValue)
		let none = Int32(Config.BluetoothConfig.PairingMode.noPin.rawValue)
		#expect(RadioAutoConfig.needsCodeTurnedOff(mode: random, expertMode: false))
		#expect(RadioAutoConfig.needsCodeTurnedOff(mode: fixed, expertMode: false))
		#expect(!RadioAutoConfig.needsCodeTurnedOff(mode: none, expertMode: false))
		// Settings not downloaded yet, or chosen by hand in Expert Mode: left alone.
		#expect(!RadioAutoConfig.needsCodeTurnedOff(mode: nil, expertMode: false))
		#expect(!RadioAutoConfig.needsCodeTurnedOff(mode: fixed, expertMode: true))
	}

	@Test func oldPlaceholderNamesAreRenamed() throws {
		let controller = PersistenceController(inMemory: true)
		let context = controller.container.viewContext
		func user(_ id: String, _ name: String, hw: String = "UNSET") -> UserEntity {
			let user = UserEntity(context: context)
			user.userId = id
			user.longName = name
			user.shortName = String(id.suffix(4))
			user.hwModel = hw
			return user
		}
		let placeholder = user("!b6699e8a", "Pangea 9e8a")
		let named = user("!a617a1ca", "Pangea Base")
		let known = user("!c7f09e50", "Pangea 9e50", hw: "RAK4631")
		try context.save()
		renameOldPlaceholderNames(context: context)
		#expect(placeholder.longName == "Meshtastic 9e8a")
		// Names someone chose, or radios we know more about, are left alone.
		#expect(named.longName == "Pangea Base")
		#expect(known.longName == "Pangea 9e50")
		#expect(createNodeInfo(num: 0x30148b0b, context: context).user?.longName == "Meshtastic 8b0b")
		withExtendedLifetime(controller) {}
	}

	@Test func everyoneNearbyNotifiesOnlyWhenTurnedOn() {
		#expect(!GroupChats.mayNotify(channelIndex: 0, expertMode: false, everyoneOn: false))
		#expect(GroupChats.mayNotify(channelIndex: 0, expertMode: false, everyoneOn: true))
		// Groups notify as before; Expert Mode keeps its per-channel alerts.
		#expect(GroupChats.mayNotify(channelIndex: 2, expertMode: false, everyoneOn: false))
		#expect(GroupChats.mayNotify(channelIndex: 0, expertMode: true, everyoneOn: false))
	}
}
