//
//  EmojiPicker.swift
//  Pangea
//
//  Every emoji, searchable, with skin tones. Picking never depends on the
//  keyboard, so it works the same on iPhone and Mac.
//

import SwiftUI

struct EmojiPickerSheet: View {
	@Environment(\.dismiss) private var dismiss
	var onPick: (String) -> Void

	@State private var search = ""
	@State private var choosingVariant: EmojiCatalog.Emoji?

	private var results: [EmojiCatalog.Group] {
		let query = search.trimmingCharacters(in: .whitespaces).lowercased()
		guard !query.isEmpty else { return EmojiCatalog.groups }
		let matches = EmojiCatalog.groups.flatMap(\.emoji).filter { $0.name.lowercased().contains(query) || $0.emoji == query }
		return matches.isEmpty ? [] : [EmojiCatalog.Group(name: String(localized: "Results"), emoji: matches)]
	}

	var body: some View {
		NavigationStack {
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
			.safeAreaInset(edge: .bottom) {
				if let item = choosingVariant {
					VariantBar(item: item, onPick: pick) { choosingVariant = nil }
						.transition(.move(edge: .bottom).combined(with: .opacity))
				}
			}
			.animation(.snappy, value: choosingVariant)
			.searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search emoji")
			.navigationTitle("Choose Emoji")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
			}
		}
	}

	private func cell(_ item: EmojiCatalog.Emoji) -> some View {
		Button {
			if item.variants.isEmpty {
				pick(item.emoji)
			} else {
				choosingVariant = item
			}
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
		}
		.buttonStyle(.plain)
		.background(choosingVariant == item ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
		.accessibilityLabel(item.name)
	}

	private func pick(_ emoji: String) {
		choosingVariant = nil
		onPick(emoji)
		dismiss()
	}
}

/// The base emoji plus every skin tone (and, for pairs, every combination).
private struct VariantBar: View {
	let item: EmojiCatalog.Emoji
	var onPick: (String) -> Void
	var onClose: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text(item.name.capitalized(with: .current))
					.font(.subheadline.weight(.semibold))
				Spacer()
				Button(action: onClose) {
					Image(systemName: "xmark.circle.fill")
						.font(.title3)
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.plain)
				.accessibilityLabel("Close")
			}
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 4) {
					ForEach([item.emoji] + item.variants, id: \.self) { emoji in
						Button {
							onPick(emoji)
						} label: {
							Text(emoji)
								.font(.system(size: 36))
								.frame(width: 52, height: 52)
						}
						.buttonStyle(.plain)
					}
				}
			}
		}
		.padding(14)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
		.padding(.horizontal)
		.padding(.bottom, 8)
	}
}
