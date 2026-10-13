//
//  ChatIconTests.swift
//  MeshtasticTests
//

import Foundation
import Testing
@testable import Meshtastic

@MainActor
@Suite struct ChatIconTests {
	private func scratchDefaults() -> UserDefaults {
		let name = "ChatIconTests-\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: name)!
		defaults.removePersistentDomain(forName: name)
		return defaults
	}

	@Test func iconsAreKeptAndPutBack() {
		let defaults = scratchDefaults()
		let store = ChatIconStore(defaults: defaults)
		store.set(ChatIcon(emoji: "🏕️", color: 2), for: "everyone")
		#expect(ChatIconStore(defaults: defaults).icon(for: "everyone") == ChatIcon(emoji: "🏕️", color: 2))
		store.set(nil, for: "everyone")
		#expect(ChatIconStore(defaults: defaults).icon(for: "everyone") == nil)
	}

	/// Only an emoji the pickers offer is kept, so the icon always draws as one emoji.
	@Test func onlyRealEmojiAreKept() {
		let defaults = scratchDefaults()
		let store = ChatIconStore(defaults: defaults)
		store.set(ChatIcon(emoji: "AB", color: 0), for: "x")
		store.set(ChatIcon(emoji: "", color: 0), for: "y")
		#expect(store.icons.isEmpty)
		defaults.set(try? JSONEncoder().encode(["z": ChatIcon(emoji: "hi", color: 1)]), forKey: ChatIconStore.defaultsKey)
		#expect(ChatIconStore(defaults: defaults).icons.isEmpty)
	}

	/// A group is its name and key: the same group gets the same icon in any slot, another group doesn't.
	@Test func groupKeys() {
		let key = Data(repeating: 7, count: 32)
		#expect(ChatIconStore.key(name: "Hike", psk: key) == ChatIconStore.key(name: "Hike", psk: key))
		#expect(ChatIconStore.key(name: "Hike", psk: key) != ChatIconStore.key(name: "Hike", psk: Data(repeating: 8, count: 32)))
		#expect(ChatIconStore.key(name: "Hike", psk: key) != ChatIconStore.key(name: "Hikes", psk: key))
		#expect(ChatIconStore.key(name: "Hike", psk: key) != "everyone")
	}

	@Test func forgetAllDropsTheLoadedCopy() {
		let defaults = scratchDefaults()
		let store = ChatIconStore(defaults: defaults)
		store.set(ChatIcon(emoji: "🔥", color: 0), for: "everyone")
		defaults.removeObject(forKey: ChatIconStore.defaultsKey)
		store.forgetAll()
		store.set(ChatIcon(emoji: "🐻", color: 1), for: "other")
		#expect(ChatIconStore(defaults: defaults).icons == ["other": ChatIcon(emoji: "🐻", color: 1)])
	}
}
