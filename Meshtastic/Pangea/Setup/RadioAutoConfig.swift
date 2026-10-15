//
//  RadioAutoConfig.swift
//  Pangea
//
//  Figures out what a freshly paired radio still needs before it can message,
//  and applies those settings without the user having to understand them.
//

import Foundation
import SwiftData
import MeshtasticProtobufs
import OSLog

enum RadioAutoConfig {

	/// Radios sold by Pangea advertise as `PANGEA:ID:<serial>` and ship pre-configured.
	static let pangeaNamePrefix = "PANGEA:ID:"

	static func isPangeaRadio(_ device: Device) -> Bool {
		device.name.uppercased().hasPrefix(pangeaNamePrefix)
	}

	/// The serial after the prefix, for display ("Pangea Radio · A1B2").
	static func pangeaSerial(_ device: Device) -> String? {
		guard isPangeaRadio(device) else { return nil }
		let serial = device.name.dropFirst(pangeaNamePrefix.count)
		return serial.isEmpty ? nil : String(serial)
	}

	// MARK: Region

	/// Best guess at the legal LoRa region for where the phone is set up.
	/// Returns nil when the country isn't one we can map confidently, so the UI asks instead.
	static func suggestedRegion(countryCode: String? = Locale.current.region?.identifier) -> RegionCodes? {
		guard let code = countryCode?.uppercased() else { return nil }
		if euCountries.contains(code) { return .eu868 }
		switch code {
		case "US", "CA", "MX", "PR", "GU", "VI", "AS", "MP": return .us
		case "AU", "NZ", "BR", "CL", "AR", "CO", "PE", "UY", "CR", "PA": return .anz
		case "CN": return .cn
		case "JP": return .jp
		case "KR": return .kr
		case "TW": return .tw
		case "RU": return .ru
		case "IN": return .in
		case "TH": return .th
		case "UA": return .eu868 // UA 868 was folded into EU 868 (firmware #10994)
		case "MY": return .my919
		case "SG": return .sg923
		case "PH": return .ph915
		case "KZ": return .kz863
		default: return nil
		}
	}

	/// EU 868 MHz band: EU/EEA members plus neighbours that follow ETSI rules.
	private static let euCountries: Set<String> = [
		"AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT",
		"LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE",
		"GB", "NO", "IS", "LI", "CH", "RS", "ME", "MK", "AL", "BA", "MD", "TR", "ZA"
	]

	// MARK: State of the connected radio

	struct Status {
		var region: RegionCodes
		var longName: String
		var shortName: String

		var needsRegion: Bool { region == .unset }

		/// Stock firmware names radios "Meshtastic 1a2b"; Pangea radios use the serial.
		var hasDefaultName: Bool {
			longName.isEmpty
				|| longName.hasPrefix("Meshtastic ")
				|| longName.uppercased().hasPrefix(RadioAutoConfig.pangeaNamePrefix)
		}
	}

	@MainActor
	static func status(of accessoryManager: AccessoryManager) -> Status? {
		guard let num = accessoryManager.activeDeviceNum,
			  let node = getNodeInfo(id: num, context: accessoryManager.context) else { return nil }
		let region = RegionCodes(rawValue: Int(node.loRaConfig?.regionCode ?? 0)) ?? .unset
		return Status(
			region: region,
			longName: node.user?.longName ?? "",
			shortName: node.user?.shortName ?? ""
		)
	}

	// MARK: Names

	/// "Andrew Davis" -> "AD", "Sam" -> "SAM", "Mary Jo Kim" -> "MJK". Max 4 bytes, as the firmware requires.
	/// Initials too big to fit (a flag is 8 bytes) are skipped rather than ending the
	/// name early, then plain letters from the name are tried before falling back to "ME".
	/// Hidden characters are dropped first (an emoji keeps the selector that makes it one,
	/// so ❤️ is too big to be an initial rather than turning into a text-style ❤).
	static func shortName(for longName: String) -> String {
		let longName = longName.cleanedName
		let words = longName.split(whereSeparator: { $0.isWhitespace })
		var candidate: String
		if words.count > 1 {
			let initials = words.compactMap(\.first).map { String($0).uppercased() }
			candidate = ""
			for initial in initials where candidate.utf8.count + initial.utf8.count <= 4 {
				candidate.append(initial)
			}
		} else {
			candidate = String(longName.prefix(4)).uppercased().clampedUTF8(4)
		}
		if candidate.isEmpty {
			candidate = String(longName.filter { $0.isASCII && $0.isLetter }.prefix(4)).uppercased()
		}
		return candidate.isEmpty ? "ME" : candidate
	}

	/// Without hidden characters, spaces made plain, cut to the firmware's 36 bytes.
	static func clampedLongName(_ name: String) -> String {
		name.cleanedName(fitting: 36)
	}

	// MARK: Pairing code

	/// Whether a radio paired with these Bluetooth settings should be switched to pairing
	/// without a code. Only once its settings are known, so nothing else is guessed;
	/// Expert Mode leaves the pairing mode to the user.
	static func needsCodeTurnedOff(mode: Int32?, expertMode: Bool) -> Bool {
		guard let mode, !expertMode else { return false }
		return mode != Int32(Config.BluetoothConfig.PairingMode.noPin.rawValue)
	}

	/// How many times each radio has been sent the change, by node number. The radio restarts
	/// each time, so one that keeps coming back with a code would otherwise restart on every
	/// connect, losing whatever it had queued to send.
	static let pairingCodeAttemptsKey = "pangeaPairingCodeAttempts"
	static let maxPairingCodeAttempts = 2

	/// Whether to send the change again to a radio that has been sent it `attempts` times.
	static func mayTryTurningOffCode(attempts: Int) -> Bool {
		attempts < maxPairingCodeAttempts
	}

	static func pairingCodeAttempts(for num: Int64, defaults: UserDefaults = .standard) -> Int {
		(defaults.dictionary(forKey: pairingCodeAttemptsKey)?[String(num)] as? Int) ?? 0
	}

	/// The same radio now reports another node number (see `NodeRenumber`): its tries go with it,
	/// or a radio that refused twice would be sent the change twice more.
	static func renumberPairingCodeAttempts(from oldNum: Int64, to newNum: Int64, defaults: UserDefaults = .standard) {
		let attempts = pairingCodeAttempts(for: oldNum, defaults: defaults)
		guard attempts > 0 else { return }
		setPairingCodeAttempts(max(attempts, pairingCodeAttempts(for: newNum, defaults: defaults)), for: newNum, defaults: defaults)
		var all = defaults.dictionary(forKey: pairingCodeAttemptsKey) ?? [:]
		all[String(oldNum)] = nil
		defaults.set(all, forKey: pairingCodeAttemptsKey)
	}

	static func setPairingCodeAttempts(_ attempts: Int, for num: Int64, defaults: UserDefaults = .standard) {
		var all = defaults.dictionary(forKey: pairingCodeAttemptsKey) ?? [:]
		all[String(num)] = attempts
		defaults.set(all, forKey: pairingCodeAttemptsKey)
	}

	/// The phone has to enter a code the first time it pairs, which a radio without a screen
	/// can't show. Once paired, the radio is set to pair without one, so reconnecting, pairing
	/// again after Forget, or pairing another phone never asks. The radio restarts to apply it
	/// and the app reconnects on its own. Sent at most `maxPairingCodeAttempts` times per radio,
	/// ever: the setting saved here reads as no code until the radio reports again, so seeing
	/// no code isn't proof the radio took it.
	@MainActor
	static func turnOffPairingCode(accessoryManager: AccessoryManager) async {
		// A fresh context, as readiness uses: the config is saved by the packet actor and the
		// main context can lag behind it when the radio first turns ready.
		let context = ModelContext(accessoryManager.context.container)
		guard let num = accessoryManager.activeDeviceNum,
			  let node = getNodeInfo(id: num, context: context),
			  let user = node.user,
			  let bluetooth = node.bluetoothConfig,
			  needsCodeTurnedOff(mode: bluetooth.mode, expertMode: UserDefaults.expertModeEnabled) else { return }
		let attempts = pairingCodeAttempts(for: num)
		guard mayTryTurningOffCode(attempts: attempts) else {
			Logger.pangea.info("🧭 [Setup] Radio kept its pairing code after \(attempts, privacy: .public) tries; leaving it")
			return
		}
		var config = Config.BluetoothConfig()
		config.enabled = true
		config.mode = .noPin
		config.fixedPin = UInt32(clamping: bluetooth.fixedPin)
		// Counted before sending, and kept if sending fails after the write: the radio may take
		// the change and restart before the call returns, which can look like a failure. A send
		// that failed before anything was written doesn't count.
		setPairingCodeAttempts(attempts + 1, for: num)
		do {
			_ = try await accessoryManager.saveBluetoothConfig(config: config, fromUser: user, toUser: user)
			Logger.pangea.info("🧭 [Setup] Turned off the pairing code")
		} catch {
			if AccessoryError.neverSent(error) {
				setPairingCodeAttempts(attempts, for: num)
			}
			// Tried again the next time the radio connects, while it has tries left.
			Logger.pangea.error("🧭 [Setup] Couldn't turn off the pairing code: \(error.localizedDescription, privacy: .public)")
		}
	}

	// MARK: Apply

	/// Saves the owner name, then the region if the radio has none.
	/// Setting the region makes the firmware reboot; the app reconnects to the preferred radio on its own.
	/// - Returns: true when a reboot is expected.
	@MainActor
	@discardableResult
	static func apply(name: String, region: RegionCodes?, accessoryManager: AccessoryManager) async throws -> Bool {
		guard let num = accessoryManager.activeDeviceNum,
			  let node = getNodeInfo(id: num, context: accessoryManager.context),
			  let user = node.user else {
			throw AccessoryError.connectionFailed("No connected radio")
		}

		let longName = clampedLongName(name)
		if !longName.isEmpty && longName != user.longName {
			var owner = User()
			owner.longName = longName
			owner.shortName = shortName(for: longName)
			_ = try await accessoryManager.saveUser(config: owner, fromUser: user, toUser: user)
			// The radio only reports the new name after it reconnects; show it now.
			user.longName = owner.longName
			user.shortName = owner.shortName
			try? accessoryManager.context.save()
			Logger.pangea.info("🧭 [Setup] Saved owner name")
		}

		let currentRegion = RegionCodes(rawValue: Int(node.loRaConfig?.regionCode ?? 0)) ?? .unset
		guard let region, region != .unset, region != currentRegion else { return false }

		// Keep whatever else is on the radio; only fill in what's required to transmit.
		// The app keeps the radio's LoRa settings in LoRaConfigEntity, so start from that
		// rather than from defaults. Fields the entity doesn't store (ignore list, fan)
		// are the firmware defaults on a radio that has never had a region set.
		var lora: Config.LoRaConfig
		if let existing = node.loRaConfig {
			lora = existing.toProto()
			lora.frequencyOffset = existing.frequencyOffset
			lora.overrideDutyCycle = existing.overrideDutyCycle
		} else {
			lora = Config.LoRaConfig()
			lora.usePreset = true
			lora.modemPreset = ModemPresets.longFast.protoEnumValue()
			lora.hopLimit = 3
		}
		lora.region = region.protoEnumValue()
		lora.txEnabled = true
		_ = try await accessoryManager.saveLoRaConfig(config: lora, fromUser: user, toUser: user)
		Logger.pangea.info("🧭 [Setup] Set region to \(region.description, privacy: .public)")
		return true
	}
}
