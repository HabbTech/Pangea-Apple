//
//  RadioAutoConfig.swift
//  Pangea
//
//  Figures out what a freshly paired radio still needs before it can message,
//  and applies those settings without the user having to understand them.
//

import Foundation
import CoreData
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
		case "UA": return .ua868
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
	static func shortName(for longName: String) -> String {
		let words = longName.split(whereSeparator: { $0.isWhitespace })
		var candidate: String
		if words.count > 1 {
			candidate = words.compactMap(\.first).map(String.init).joined()
		} else {
			candidate = String(longName.prefix(4))
		}
		candidate = candidate.withoutVariationSelectors.uppercased()
		while candidate.utf8.count > 4 {
			candidate = String(candidate.dropLast())
		}
		return candidate.isEmpty ? "ME" : candidate
	}

	static func clampedLongName(_ name: String) -> String {
		var value = name.trimmingCharacters(in: .whitespacesAndNewlines).withoutVariationSelectors
		while value.utf8.count > 36 {
			value = String(value.dropLast())
		}
		return value
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
			Logger.services.info("🧭 [Setup] Saved owner name")
		}

		let currentRegion = RegionCodes(rawValue: Int(node.loRaConfig?.regionCode ?? 0)) ?? .unset
		guard let region, region != .unset, region != currentRegion else { return false }

		// Keep whatever else is on the radio; only fill in what's required to transmit.
		var lora = Config.LoRaConfig()
		let existing = node.loRaConfig
		lora.region = region.protoEnumValue()
		lora.usePreset = existing?.usePreset ?? true
		lora.modemPreset = (ModemPresets(rawValue: Int(existing?.modemPreset ?? 0)) ?? .longFast).protoEnumValue()
		lora.hopLimit = UInt32(existing?.hopLimit ?? 3)
		lora.txEnabled = true
		lora.txPower = Int32(existing?.txPower ?? 0)
		lora.channelNum = UInt32(existing?.channelNum ?? 0)
		lora.bandwidth = UInt32(existing?.bandwidth ?? 0)
		lora.codingRate = UInt32(existing?.codingRate ?? 0)
		lora.spreadFactor = UInt32(existing?.spreadFactor ?? 0)
		lora.sx126XRxBoostedGain = existing?.sx126xRxBoostedGain ?? false
		lora.overrideFrequency = existing?.overrideFrequency ?? 0
		lora.ignoreMqtt = existing?.ignoreMqtt ?? false
		lora.configOkToMqtt = existing?.okToMqtt ?? false
		_ = try await accessoryManager.saveLoRaConfig(config: lora, fromUser: user, toUser: user)
		Logger.services.info("🧭 [Setup] Set region to \(region.description, privacy: .public)")
		return true
	}
}
