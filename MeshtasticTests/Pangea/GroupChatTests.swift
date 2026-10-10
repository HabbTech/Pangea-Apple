//
//  GroupChatTests.swift
//  MeshtasticTests
//

import Foundation
import Testing
@testable import Meshtastic

@Suite("GroupInvite")
struct GroupInviteTests {

	let invite = GroupInvite(name: "Hiking", psk: Data((0..<32).map { UInt8($0) }))

	@Test func linkRoundTrips() throws {
		let url = try #require(invite.link)
		#expect(url.scheme == "pangea")
		#expect(url.host == "group")
		#expect(GroupInvite(url: url) == invite)
	}

	@Test func payloadRoundTrips() throws {
		let payload = try #require(invite.invitePayload)
		#expect(GroupInvite(invitePayload: payload) == invite)
	}

	@Test func ignoresForeignPrivateAppPayloads() {
		#expect(GroupInvite(invitePayload: Data("hello".utf8)) == nil)
		#expect(GroupInvite(invitePayload: Data()) == nil)
	}

	@Test func rejectsWeakOrMissingKeys() throws {
		let noKey = GroupInvite(name: "Open", psk: Data([1]))
		let url = try #require(noKey.link)
		#expect(GroupInvite(url: url) == nil)
	}

	@Test func clampsNameToFirmwareLimit() {
		#expect(GroupInvite.clampedName("  Weekend Camping Trip ").utf8.count <= GroupInvite.maxNameBytes)
		#expect(GroupInvite.clampedName("Hiking") == "Hiking")
	}

	@Test func dmCodesAreNotGroupLinks() throws {
		let url = try #require(URL(string: "pangea://dm/0D2PF2DZ"))
		#expect(GroupInvite(url: url) == nil)
	}
}

@Suite("Mentions")
@MainActor
struct MentionTests {

	let people = [
		Mentions.Person(name: "Sam Rivera", num: 0x1A2B3C4D),
		Mentions.Person(name: "Sam", num: 0x0000BEEF)
	]

	@Test func linksLongestMatchingName() {
		let result = Mentions.linkify("hey @Sam Rivera, lunch?", people: people)
		#expect(result.contains("[@Sam Rivera](pangea://dm/"))
		#expect(result.hasSuffix(", lunch?"))
	}

	@Test func linksShortName() {
		let result = Mentions.linkify("@sam you there", people: people)
		#expect(result.hasPrefix("[@sam](pangea://dm/"))
	}

	@Test func linkedCodeResolvesToThePerson() throws {
		let result = Mentions.linkify("@Sam Rivera", people: people)
		let start = try #require(result.range(of: "(")).upperBound
		let end = try #require(result.range(of: ")")).lowerBound
		let url = try #require(URL(string: String(result[start..<end])))
		#expect(PangeaCode.invite(from: url)?.nodeNum == 0x1A2B3C4D)
	}

	@Test func leavesEmailsAndUnknownNamesAlone() {
		#expect(Mentions.linkify("mail sam@Sam.com", people: people) == "mail sam@Sam.com")
		#expect(Mentions.linkify("@Alex hi", people: people) == "@Alex hi")
		#expect(Mentions.linkify("@Samantha hi", people: people) == "@Samantha hi")
	}

	@Test func leavesExistingLinksAlone() {
		let markdown = "[@Sam](https://example.com)"
		#expect(Mentions.linkify(markdown, people: people) == markdown)
	}

	@Test func activeQueryOnlyAtWordStart() {
		#expect(Mentions.activeQuery(in: "hi @Sa") == "Sa")
		#expect(Mentions.activeQuery(in: "@") == "")
		#expect(Mentions.activeQuery(in: "mail me@ex") == nil)
		#expect(Mentions.activeQuery(in: "no mention") == nil)
	}
}
