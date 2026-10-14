//
//  EmojiPicker.swift
//  Pangea
//
//  Every emoji, searchable, with skin tones. Picking never depends on the
//  keyboard, so it works the same on iPhone and Mac. Pushed inside the sheet that
//  opens it rather than presented over it: on a Mac a sheet over a sheet could close
//  before the pick reached the one below.
//

import SwiftUI

struct EmojiPickerView: View {
	@Environment(\.dismiss) private var dismiss
	var onPick: (String) -> Void

	@State private var search = ""

	private var results: [EmojiCatalog.Group] {
		let query = search.trimmingCharacters(in: .whitespaces).lowercased()
		guard !query.isEmpty else { return EmojiCatalog.groups }
		let matches = EmojiCatalog.groups.flatMap(\.emoji).filter { $0.name.lowercased().contains(query) || $0.emoji == query }
		return matches.isEmpty ? [] : [EmojiCatalog.Group(name: String(localized: "Results"), emoji: matches)]
	}

	var body: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
				ForEach(results) { group in
					Section {
						LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 4)], spacing: 4) {
							ForEach(group.emoji) { item in
								cell(item)
							}
						}
						.padding(.bottom, 12)
					} header: {
						Text(group.name)
							.font(.subheadline.weight(.semibold))
							.foregroundStyle(.secondary)
							.frame(maxWidth: .infinity, alignment: .leading)
							.padding(.vertical, 6)
							.background(.background)
					}
				}
				if results.isEmpty {
					ContentUnavailableView.search(text: search)
				}
			}
			.padding(.horizontal)
		}
		.searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search emoji")
		.navigationTitle("Choose Emoji")
		.navigationBarTitleDisplayMode(.inline)
	}

	/// A tap picks the emoji as shown, like the keyboard; holding it (or a right-click on a Mac)
	/// offers the skin tones. A tap that only opened the tones looked like a pick that didn't take.
	private func cell(_ item: EmojiCatalog.Emoji) -> some View {
		Button {
			pick(item.emoji)
		} label: {
			Text(item.emoji)
				.font(.system(size: 32))
				.frame(width: 44, height: 44)
				.overlay(alignment: .bottomTrailing) {
					if !item.variants.isEmpty {
						// Hint that more versions are available, like the keyboard.
						Image(systemName: "triangle.fill")
							.font(.system(size: 5))
							.rotationEffect(.degrees(135))
							.foregroundStyle(.tertiary)
					}
				}
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.contextMenu {
			if !item.variants.isEmpty {
				ForEach([item.emoji] + item.variants, id: \.self) { emoji in
					Button(emoji) { pick(emoji) }
				}
			}
		}
		.accessibilityLabel(item.name)
		.accessibilityHint(item.variants.isEmpty ? "" : String(localized: "Hold for skin tones."))
	}

	private func pick(_ emoji: String) {
		onPick(emoji)
		dismiss()
	}
}

