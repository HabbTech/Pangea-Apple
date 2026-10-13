//
//  VisibleNameTests.swift
//  MeshtasticTests
//

import Foundation
import Testing
import MeshtasticProtobufs
@testable import Meshtastic

@Suite("Hidden characters in names")
struct VisibleNameTests {

	/// Text that must come through exactly as it is.
	static let kept = [
		"❤️", "👨‍👩‍👧", "🏴󠁧󠁢󠁳󠁣󠁴󠁿", "1️⃣", "🇺🇸", "👍🏽", "🧑🏻‍🤝‍🧑🏿", "🏳️‍🌈", "🏴‍☠️", "❤️‍🔥",
		"Café", "O'Brien", "Bike Group", "Sam ❤️",
		"می\u{200C}خواهم",          // Persian, zero-width non-joiner
		"क्\u{200D}ष",              // Devanagari, zero-width joiner
		"ශ්\u{200D}රී",              // Sinhala, zero-width joiner
		"لا\u{200C}ل",              // Arabic, zero-width non-joiner
		"葛\u{E0100}",              // ideographic variation selector
		"e\u{0301}",                // a mark on its letter
		"क्ष"                        // Devanagari, virama
	]

	/// Text with something hidden in it, and what it cleans to.
	static let changed: [(String, String)] = [
		("admin\u{200D}", "admin"),
		("ad\u{200C}min", "admin"),
		("ad\u{00AD}min", "admin"),
		("ad\u{034F}min", "admin"),
		("\u{202E}nimda", "nimda"),
		("\u{206A}x", "x"),
		("\u{17B4}x", "x"),
		("\u{1D173}x", "x"),
		("x\u{180E}y", "xy"),
		("\u{115F}x", "x"),
		("😀\u{200D}", "😀"),
		("a\u{FE0F}", "a"),
		("x\u{E0041}", "x"),
		("\u{E0001}en", "en"),
		("🏴\u{E0067}\u{E0062}", "🏴"),
		("a\u{FE0F}\u{200D}😀", "a😀"),
		("क\u{200D}\u{FE0F}", "क"),
		("Bike\u{00A0}Group", "Bike Group"),
		("Bike\u{3000}\u{3000}Group", "Bike Group"),
		("a\u{2028}b", "a b"),
		("\u{E000}Sam", "Sam"),
		("\u{0301}Bob", "Bob"),
		("Bob \u{0301}x", "Bob x"),
		("\u{200B}\u{0301}\u{20E3}Bob", "Bob")
	]

	/// Nothing visible at all.
	static let blank = ["\u{3164}", "\u{2800}", "\u{FFA0}", "\u{1160}", "\u{FFFC}", "\u{200B}\u{200F}", "\u{E000}", " \u{00A0} ", "\u{0301}"]

	@Test(arguments: kept)
	func visibleTextIsKept(text: String) {
		#expect(text.cleanedName == text)
		#expect(!text.hasHiddenCharacters)
		#expect(!text.isBlankName)
		#expect(ProfileCard.cleanName(text) == text)
	}

	@Test(arguments: changed)
	func hiddenCharactersAreRemoved(text: String, expected: String) {
		#expect(text.cleanedName == expected)
		// Cleaning twice changes nothing more.
		#expect(text.cleanedName.cleanedName == expected)
	}

	@Test(arguments: blank)
	func blankNamesAreBlank(text: String) {
		#expect(text.cleanedName.isBlankName)
		#expect(ProfileCard.cleanName(text) == "")
	}

	@Test func everyPickableEmojiIsUntouched() {
		var count = 0
		for item in EmojiCatalog.groups.flatMap(\.emoji) {
			for emoji in [item.emoji] + item.variants {
				count += 1
				#expect(emoji.cleanedName == emoji, "\(item.name)")
				#expect(!emoji.hasHiddenCharacters, "\(item.name)")
				#expect(ProfileCard.cleanEmoji(emoji) == emoji, "\(item.name)")
			}
		}
		for emoji in ProfileEditorSheet.suggestedEmoji {
			#expect(ProfileCard.cleanEmoji(emoji) == emoji, "\(emoji)")
		}
		#expect(count > 3700)
	}

	/// Built from emoji parts, but not one emoji: they draw two to five glyphs wide.
	@Test(arguments: ["🇦🇦", "🦊\u{200D}🦊", Array(repeating: "😀", count: 5).joined(separator: "\u{200D}")])
	func emojiThatArentOnTheListAreRefused(text: String) {
		#expect(ProfileCard.cleanEmoji(text) == "")
	}

	@Test(arguments: ["1\u{FE0F}", "1\u{0301}", "©", "™", "🏻", "🇺", "😀\u{0301}\u{0301}\u{0301}", "😀\u{200D}", "\u{200D}😀", "hi", "🦊🦊", "1", "#", "a\u{20E3}", "🏴\u{E0067}"])
	func notAnEmoji(text: String) {
		#expect(ProfileCard.cleanEmoji(text) == "")
	}

	@Test(arguments: ["©️", "™️", "#️⃣", "⭐️", "🏕️", "🕵🏽‍♀️", "🫱🏻‍🫲🏿", "🏴󠁧󠁢󠁥󠁮󠁧󠁿", "👍🏽"])
	func wellFormedEmoji(text: String) {
		#expect(ProfileCard.cleanEmoji(text) == text)
	}

	@Test func myOwnNamesAreCleanedToo() {
		#expect(RadioAutoConfig.clampedLongName(" Sam\u{200B} Rivera\u{202E} ") == "Sam Rivera")
		#expect(RadioAutoConfig.clampedLongName("Sam ❤️") == "Sam ❤️")
		#expect(RadioAutoConfig.clampedLongName("\u{3164}") == "")
		#expect("Sam\u{00A0}\u{00A0}Rivera".cleanedName(fitting: ProfileCard.maxNameBytes) == "Sam Rivera")
		// A cut that would leave a joiner with nothing after it drops the joiner too.
		let joined = String(repeating: "a", count: 27) + "क्\u{200D}ष"
		#expect(!RadioAutoConfig.clampedLongName(joined).hasSuffix("\u{200D}"))
		#expect(RadioAutoConfig.clampedLongName(joined).utf8.count <= 36)
	}

	@Test func shortNamesHaveNoHiddenCharacters() {
		#expect(RadioAutoConfig.shortName(for: "\u{202E}Sam") == "SAM")
		#expect(RadioAutoConfig.shortName(for: "\u{200B}Sam \u{200B}Rivera") == "SR")
		#expect(RadioAutoConfig.shortName(for: "\u{3164}") == "ME")
		// ❤️ keeps its selector, so at 6 bytes it doesn't fit as an initial.
		#expect(RadioAutoConfig.shortName(for: "❤️ Sam") == "S")
	}

	@Test func aHugePasteIsCleanedQuickly() {
		let huge = String(repeating: "a\u{200B}", count: 500_000)
		let start = Date()
		let name = huge.cleanedName(fitting: 36)
		#expect(Date().timeIntervalSince(start) < 0.5)
		#expect(name == String(repeating: "a", count: 36))
	}

	/// The cut is by what's kept, not by how much was pasted: hidden padding in front
	/// doesn't push the name out, and an emoji isn't cut out of its family.
	@Test func hiddenPaddingDoesntCutTheName() {
		#expect((String(repeating: "\u{200B}", count: 90) + "Hike").cleanedName(fitting: GroupInvite.maxNameBytes) == "Hike")
		#expect((String(repeating: "\u{200B}", count: 511) + "👨‍👩‍👧").cleanedName(fitting: ProfileCard.maxNameBytes) == "👨‍👩‍👧")
		let start = Date()
		let padded = String(repeating: "\u{200B}", count: 300_000) + "Sam"
		#expect(padded.cleanedName(fitting: ProfileCard.maxNameBytes) == "Sam")
		#expect(Date().timeIntervalSince(start) < 2)
		// One base and 500 marks is one character, too big for either budget.
		let zalgo = "a" + String(repeating: "\u{0301}", count: 500)
		#expect(zalgo.cleanedName(fitting: GroupInvite.maxNameBytes) == "")
		#expect(zalgo.cleanedName(fitting: ProfileCard.maxNameBytes) == "")
	}

	@Test(arguments: ["Bike Group A", " x" + String(repeating: "y", count: 10), "😀\u{200B}😀😀", String(repeating: "\u{200B} ", count: 50) + "Hike Trip!!"])
	func cuttingIsTheSameAsCleaningThenCutting(text: String) {
		// The cut stops early, but it must give what cleaning everything and then cutting would.
		let full = text.cleanedName.clampedUTF8(GroupInvite.maxNameBytes).cleanedName
		#expect(text.cleanedName(fitting: GroupInvite.maxNameBytes) == (full.isBlankName ? "" : full))
	}
}

@Suite("Group names")
struct GroupNameTests {

	@Test(arguments: ["admin\u{200D}", "\u{3164}", "Bike\u{00A0}Group", "Bike  Group", "ad\u{00AD}min", "\u{2800}", "admin\u{00A0}"])
	func invitesWithHiddenOrLookalikeNamesAreRefused(name: String) {
		var settings = ChannelSettings()
		settings.name = name
		settings.psk = Data(repeating: 1, count: 32)
		#expect(GroupInvite(settings: settings) == nil)
	}

	@Test func reservedNamesAreFoundThroughLookalikes() {
		#expect(GroupInvite.isReserved("admin\u{200D}"))
		#expect(GroupInvite.isReserved("\u{3164}"))
		#expect(GroupInvite.isReserved("Admin\u{00A0}"))
		#expect(!GroupInvite.isReserved("Bike  Group"))
		#expect(!GroupInvite.isReserved(""))
		#expect(!GroupInvite.isReserved("Hike ❤️"))
	}

	/// A lone accent shows (as a dotted circle), so it doesn't make a joined channel's name
	/// reserved; it still isn't a name an invite can carry.
	@Test(arguments: ["\u{0301}Hike", "Bike \u{0301}x"])
	func aStrayMarkIsNotHiddenButNotCleanEither(name: String) {
		#expect(!name.hasHiddenCharacters)
		#expect(!GroupInvite.isReserved(name))
		#expect(name.cleanedName != name)
		#expect(!GroupInvite.isAcceptableName(name))
	}

	@Test(arguments: ["Bike Group A", "  Weekend Camping Trip ", "Hiking", "ab🇺🇸cdefg", "क्\u{200D}ष क्\u{200D}ष", "12345678901 2"])
	func clampingTwiceChangesNothing(name: String) {
		let once = GroupInvite.clampedName(name)
		#expect(GroupInvite.clampedName(once) == once)
		#expect(!once.hasSuffix(" "))
		#expect(once.utf8.count <= GroupInvite.maxNameBytes)
	}

	@Test func aNameLongerThanTheRadioTakesIsRefusedNotCut() {
		// "Bike Group A" is 12 bytes; cut, it would be "Bike Group", a different channel.
		var settings = ChannelSettings()
		settings.name = "Bike Group A"
		settings.psk = Data(repeating: 1, count: 32)
		#expect(GroupInvite(settings: settings) == nil)
	}

	@Test func newGroupNamesAreCleanedOrRefused() {
		func name(_ typed: String) -> String? { try? GroupInvite.nameForNewGroup(typed).get() }
		#expect(name("Hike\u{200B}") == "Hike")
		#expect(name(" Bike\u{00A0}Group ") == "Bike Group")
		#expect(name("Admin") == nil)
		#expect(name("MQTT") == nil)
		#expect(name("serial\u{200B}") == nil)
		#expect(name("\u{3164}") == nil)
		#expect(name("Weekend Camping Trip") == "Weekend Cam")
		#expect(name("Hike ❤️") == "Hike ❤️")
		#expect(name(String(repeating: "\u{200B}", count: 90) + "Hike") == "Hike")
	}

	@Test func whyANewGroupNameWasRefused() {
		func reason(_ typed: String) -> GroupChatError? {
			if case .failure(let error) = GroupInvite.nameForNewGroup(typed) { return error }
			return nil
		}
		// 25 bytes, and one character: nothing of it fits in 11.
		#expect(reason("👨‍👩‍👧‍👦") == .tooLong)
		#expect(reason("\u{3164}") == .blankName)
		#expect(reason("   ") == .blankName)
		#expect(reason("admin") == .reservedName)
		#expect(reason("Hike") == nil)
	}
}
