//
//  SetupProfileView.swift
//  Pangea
//
//  Last step of setup: the user's name, plus any radio settings the radio is
//  missing (region). Applies everything with one button.
//

import SwiftUI
import OSLog

struct SetupProfileView: View {
	@EnvironmentObject var accessoryManager: AccessoryManager

	var onFinished: () -> Void

	@State private var name = ""
	@State private var region: RegionCodes = .unset
	@State private var needsRegion = false
	@State private var phase: Phase = .editing
	@FocusState private var nameFocused: Bool

	private enum Phase: Equatable {
		case editing
		case saving
		case restarting
		case done
		case failed(String)
	}

	private var isFailed: Bool {
		if case .failed = phase { return true }
		return false
	}

	/// What gets saved: no hidden characters, plain spaces, trimmed. Cleaned here
	/// rather than while typing, so a joiner typed before its next letter isn't lost.
	private var trimmedName: String {
		name.cleanedName(fitting: 36)
	}

	private var canContinue: Bool {
		!trimmedName.isEmpty && (!needsRegion || region != .unset) && (phase == .editing || isFailed)
	}

	var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				VStack(spacing: 28) {
					VStack(spacing: 12) {
						Image(systemName: "person.crop.circle.fill")
							.font(.system(size: 56))
							.foregroundStyle(Color.accentColor)
						Text("What should people call you?")
							.font(.title.bold())
							.multilineTextAlignment(.center)
						Text("This is the name your friends see when you message them.")
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
					}
					.padding(.top, 24)

					TextField("Your name", text: $name)
						.font(.title3)
						.textContentType(.name)
						.submitLabel(.done)
						.focused($nameFocused)
						.padding()
						.background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
						.onChange(of: name) { _, newValue in
							if newValue.utf8.count > 36 {
								name = RadioAutoConfig.clampedLongName(newValue)
							}
						}

					if needsRegion {
						regionCard
					}

					statusView
				}
				.padding()
			}
			Button {
				Task { await save() }
			} label: {
				Text(phase == .saving || phase == .restarting ? "Setting up…" : "Continue")
					.frame(maxWidth: 400)
			}
			.capsuleButtonStyle()
			.disabled(!canContinue)
			.padding(.bottom)
		}
		.onAppear(perform: load)
		.onChange(of: accessoryManager.state) { _, state in
			if phase == .restarting, state == .subscribed {
				phase = .done
				onFinished()
			}
		}
	}

	private var regionCard: some View {
		VStack(alignment: .leading, spacing: 8) {
			Picker(selection: $region) {
				if region == .unset {
					Text("Choose your country").tag(RegionCodes.unset)
				}
				ForEach(RegionCodes.allCases.filter { $0 != .unset }) { code in
					Text(code.description).tag(code)
				}
			} label: {
				Label("Where you'll use it", systemImage: "globe")
			}
			.pickerStyle(.navigationLink)
			Text("Radios must use the frequencies allowed where you are. We picked this from your phone's settings.")
				.font(.footnote)
				.foregroundStyle(.secondary)
		}
		.padding()
		.background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
	}

	@ViewBuilder
	private var statusView: some View {
		switch phase {
		case .editing, .done:
			EmptyView()
		case .saving:
			ProgressView("Saving to your radio…")
		case .restarting:
			VStack(spacing: 8) {
				ProgressView()
				Text("Your radio is restarting with the new settings. This takes about 20 seconds.")
					.font(.footnote)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}
		case .failed(let message):
			Label(message, systemImage: "exclamationmark.triangle.fill")
				.font(.footnote)
				.foregroundStyle(.orange)
		}
	}

	private func load() {
		guard let status = RadioAutoConfig.status(of: accessoryManager) else { return }
		if name.isEmpty && !status.hasDefaultName {
			name = status.longName
		}
		needsRegion = status.needsRegion
		if needsRegion {
			region = RadioAutoConfig.suggestedRegion() ?? .unset
		}
		if name.isEmpty {
			nameFocused = true
		}
	}

	private func save() async {
		phase = .saving
		do {
			let rebooting = try await RadioAutoConfig.apply(
				name: trimmedName,
				region: needsRegion ? region : nil,
				accessoryManager: accessoryManager
			)
			if rebooting {
				phase = .restarting
				// The radio usually comes back well within this; don't trap the user if it doesn't.
				try? await Task.sleep(for: .seconds(45))
				if phase == .restarting {
					phase = .done
					onFinished()
				}
			} else {
				phase = .done
				onFinished()
			}
		} catch {
			Logger.services.error("🧭 [Setup] Saving profile failed: \(error.localizedDescription, privacy: .public)")
			phase = .failed(String(localized: "Couldn't save to your radio. Make sure it's still on and nearby, then try again."))
		}
	}
}
