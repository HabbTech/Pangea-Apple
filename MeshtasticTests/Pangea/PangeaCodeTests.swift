//
//  PangeaCodeTests.swift
//  MeshtasticTests
//

import Foundation
import Testing
import MeshtasticProtobufs
@testable import Meshtastic

@Suite("PangeaCode")
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

	@Test func ignoresUnrelatedLinks() throws {
		#expect(PangeaCode.invite(from: try #require(URL(string: "https://example.com/dm/ABC"))) == nil)
		#expect(PangeaCode.invite(from: "hello there") == nil)
	}
}
