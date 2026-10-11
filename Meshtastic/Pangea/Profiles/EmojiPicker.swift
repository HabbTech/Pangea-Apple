//
//  EmojiPicker.swift
//  Pangea
//
//  A built-in emoji grid, so picking an avatar never depends on the keyboard.
//

import SwiftUI

enum ProfileEmoji {
	/// The last emoji in typed text, ignoring letters, numbers and punctuation.
	static func last(in text: String) -> String? {
		text.reversed().first(where: isEmoji).map { String($0) }
	}

	static func isEmoji(_ character: Character) -> Bool {
		let scalars = character.unicodeScalars
		if scalars.contains(where: { $0.properties.isEmojiPresentation }) { return true }
		// Text-style symbols like ❤ or ☀ count when followed by the emoji selector,
		// and keycaps like 1️⃣; a bare digit or # does not.
		return scalars.contains { $0.value == 0xFE0F || $0.value == 0x20E3 }
			&& scalars.contains { $0.properties.isEmoji }
	}

	static let sections: [(String, [String])] = [
		("Smileys", ["😀", "😃", "😄", "😁", "😆", "😊", "🙂", "😉", "😍", "🥰", "😘", "😋", "😛", "😜", "🤪", "😎", "🤓", "🧐", "🤠", "🥳", "😇", "🤗", "🤔", "🤫", "😴", "🤯", "😬", "🙃", "😏", "😤", "👻", "🤖", "👽", "💀", "🤡", "😺"]),
		("People", ["👋", "👍", "✌️", "🤙", "💪", "🙏", "👀", "🧠", "🧑‍🚀", "🧑‍🚒", "🧑‍🌾", "🧑‍🍳", "🧑‍🔧", "🧑‍⚕️", "🥷", "🧙", "🏃", "🧗", "🚴", "🏄", "🎣", "⛷️", "🏂", "🤿"]),
		("Animals", ["🐶", "🐱", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔", "🐧", "🦅", "🦉", "🐺", "🐗", "🐴", "🦄", "🐝", "🦋", "🐢", "🐍", "🦖", "🐙", "🦈", "🐬", "🐳", "🦌", "🦬", "🐿️"]),
		("Outdoors", ["⛰️", "🏔️", "🗻", "🏕️", "🏞️", "🌲", "🌳", "🌵", "🍁", "🍄", "🌊", "🏝️", "🏜️", "🌋", "☀️", "🌙", "⭐️", "🌈", "⚡️", "❄️", "🔥", "💧", "🌍", "🧭"]),
		("Things", ["🚙", "🛻", "🏍️", "🚲", "⛵️", "🛶", "✈️", "🚁", "🚀", "🛰️", "📡", "📻", "🔦", "🎒", "⛺️", "🪓", "🗺️", "⚓️", "🎸", "🎮", "📷", "☕️", "🍕", "🌮", "🍔", "🍺", "⚽️", "🏀", "🏈", "🎯"]),
		("Symbols", ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💯", "✅", "⚠️", "☮️", "♻️", "🔱", "⚜️", "🏴‍☠️", "🏳️‍🌈", "🇺🇸", "🇨🇦", "🇲🇽", "🇬🇧", "🇦🇺"])
	]
}

struct EmojiPickerSheet: View {
	@Environment(\.dismiss) private var dismiss
	var onPick: (String) -> Void

	var body: some View {
		NavigationStack {
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 18) {
					ForEach(ProfileEmoji.sections, id: \.0) { title, items in
						Text(title)
							.font(.headline)
							.foregroundStyle(.secondary)
						LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], spacing: 6) {
							ForEach(items, id: \.self) { item in
								Button {
									onPick(item)
									dismiss()
								} label: {
									Text(item)
										.font(.system(size: 30))
										.frame(width: 44, height: 44)
								}
								.buttonStyle(.plain)
							}
						}
					}
				}
				.padding()
			}
			.navigationTitle("Choose Emoji")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
			}
		}
		.presentationDetents([.medium, .large])
	}
}
