//
//  EditNameSheet.swift
//  Pangea
//
//  Change the name other people see. It's stored on the radio, so it follows
//  the radio to whichever phone or Mac it's paired with.
//

import SwiftUI
import OSLog

struct EditNameSheet: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@Environment(\.dismiss) private var dismiss

	@State private var name: String
	@State private var isSaving = false
	@State private var error: String?
	@FocusState private var focused: Bool

	private let original: String

	init(currentName: String) {
		original = currentName
		_name = State(initialValue: currentName)
	}

	private var trimmed: String {
		name.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var body: some View {
		NavigationStack {
			VStack(spacing: 20) {
				Image(systemName: "person.crop.circle.fill")
					.font(.system(size: 56))
					.foregroundStyle(Color.accentColor)
					.padding(.top, 24)
				TextField("Your name", text: $name)
					.font(.title3)
					.multilineTextAlignment(.center)
					.textContentType(.name)
					.submitLabel(.done)
					.focused($focused)
					.onSubmit { Task { await save() } }
					.onChange(of: name) { _, value in
						if value.utf8.count > 36 {
							name = RadioAutoConfig.clampedLongName(value)
						}
					}
					.padding()
					.background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
				Text("This is the name people see when you message them. In small spaces they'll see \(RadioAutoConfig.shortName(for: trimmed.isEmpty ? original : trimmed)).")
					.font(.footnote)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
				if let error {
					Label(error, systemImage: "exclamationmark.triangle.fill")
						.font(.footnote)
						.foregroundStyle(.orange)
				}
				Spacer()
			}
			.padding(.horizontal)
			.navigationTitle("Your Name")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
				ToolbarItem(placement: .confirmationAction) {
					if isSaving {
						ProgressView()
					} else {
						Button("Save") { Task { await save() } }
							.disabled(trimmed.isEmpty || trimmed == original)
					}
				}
			}
			.onAppear { focused = true }
		}
	}

	private func save() async {
		guard !isSaving, !trimmed.isEmpty, trimmed != original else { return }
		guard accessoryManager.state == .subscribed else {
			error = String(localized: "Connect your radio first, then try again.")
			return
		}
		isSaving = true
		defer { isSaving = false }
		do {
			_ = try await RadioAutoConfig.apply(name: trimmed, region: nil, accessoryManager: accessoryManager)
			dismiss()
		} catch {
			Logger.services.error("🧭 [Settings] Name change failed: \(error.localizedDescription, privacy: .public)")
			self.error = String(localized: "Couldn't save your name. Make sure your radio is connected and try again.")
		}
	}
}
