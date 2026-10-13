import Foundation
import Combine
import SwiftUI
import SwiftProtobuf
import MapKit
import OSLog
import SwiftData

struct AppSettings: View {
	private var idiom: UIUserInterfaceIdiom { UIDevice.current.userInterfaceIdiom }
	@EnvironmentObject var accessoryManager: AccessoryManager
	@State var totalDownloadedTileSize = ""
	@State private var isPresentingCoreDataResetConfirm = false
	@State private var isPresentingEraseFailed = false
	@State private var isPresentingDeleteMapTilesConfirm = false
	@State private var purgeStaleNodes: Bool = false
	@State private var showAutoConnect: Bool = false
	@AppStorage("purgeStaleNodeDays") private var  purgeStaleNodeDays: Double = 0
	@AppStorage("environmentEnableWeatherKit") private var  environmentEnableWeatherKit: Bool = true
	@AppStorage("enableAdministration") private var  enableAdministration: Bool = false
	@AppStorage("expertModeEnabled") private var expertModeEnabled: Bool = false

	@StateObject private var powerManager = PowerManager.shared

	private var powerModeBinding: Binding<PowerMode> {
		Binding(
			get: { powerManager.selectedMode },
			set: { powerManager.setSelectedMode($0) }
		)
	}
	// Node Layout Preferences
	@AppStorage("nodeListDensity") private var nodeListDensity: NodeListDensity = .standard
	@AppStorage(NodeListPreferences.shouldShowLocation.rawValue) private var shouldShowLocation = true
	@AppStorage(NodeListPreferences.shouldShowPower.rawValue) private var shouldShowPower = true
	@AppStorage(NodeListPreferences.shouldShowTelemetry.rawValue) private var shouldShowTelemetry = true
	@AppStorage(NodeListPreferences.shouldShowLastHeard.rawValue) private var shouldShowLastHeard = true
	@AppStorage(NodeListPreferences.lastHeardIsRelative.rawValue) private var lastHeardIsRelative = false
	@AppStorage(NodeListPreferences.shouldShowRole.rawValue) private var shouldShowRole = true
	@AppStorage(NodeListPreferences.shouldShowChannel.rawValue) private var shouldShowChannel = true
	@AppStorage(NodeListPreferences.shouldShowHops.rawValue) private var shouldShowHops = true
	@AppStorage(NodeListPreferences.shouldShowSignal.rawValue) private var shouldShowSignal = true
	// Pangea: off unless turned on, since it sends the translated pages to an outside service.
	@AppStorage("participateInDistributedTranslations") private var participateInDistributedTranslations = false

	let autoconnectBinding = Binding<Bool>(get: {
		return UserDefaults.autoconnectOnDiscovery
	}, set: { newValue in
		UserDefaults.autoconnectOnDiscovery = newValue
	})
	var body: some View {
		VStack {
			Form {
				Section(header: Text("App Settings")) {
					Button("Open Settings", systemImage: "gear") {
						// Get the settings URL and open it
						if let url = URL(string: UIApplication.openSettingsURLString) {
							UIApplication.shared.open(url)
						}
					}
					Toggle(isOn: $enableAdministration) {
						Label("Administration", systemImage: "gearshape.2")
					}
					Text("PKI based node administration, requires firmware version 2.5+")
						.foregroundStyle(.secondary)
						.font(.caption)
					Toggle(isOn: $expertModeEnabled) {
						Label("Expert Mode", systemImage: "wand.and.stars")
					}
					.tint(.accentColor)
					Text("Reveal advanced radio, device, and module configuration. Only enable if you understand the underlying settings.")
						.foregroundStyle(.secondary)
						.font(.caption)
					if showAutoConnect {
						Toggle(isOn: autoconnectBinding) {
							Label("Automatically Connect", systemImage: "app.connected.to.app.below.fill")
						}
					}
				}
				Section(header: Text("Battery")) {
					Picker(selection: powerModeBinding) {
						ForEach(PowerMode.allCases) { mode in
							Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
						}
					} label: {
						Label("Power Mode", systemImage: "battery.100")
					}
					Text(powerManager.selectedMode.summary)
						.font(.caption)
						.foregroundStyle(.secondary)
					if powerManager.systemLowPowerMode {
						Label {
							Text("iOS Low Power Mode is active — bumped to Expedition until it turns off.")
								.font(.caption)
								.foregroundStyle(.orange)
						} icon: {
							Image(systemName: "battery.25percent")
								.foregroundColor(.orange)
						}
					}
				}
				// Pangea: the node list is an Expert Mode tab, so its layout is too.
				if expertModeEnabled {
				Section(header: Text("Node Layout")) {
					List {
						Picker("Node List Density", selection: $nodeListDensity.animation()) {
							ForEach(NodeListDensity.allCases) { item in
								Text(item.description).tag(item)
							}
						}
						.pickerStyle(.segmented)
						if nodeListDensity == .compact {
							Toggle(isOn: $shouldShowPower) {
								Text("Power")
							}
							Toggle(isOn: $shouldShowLastHeard.animation()) {
								Text("Last Heard Time")
							}
							Toggle(isOn: $lastHeardIsRelative) {
								Text("Relative Last Heard Time")
							}
							.disabled(!shouldShowLastHeard)
							Toggle(isOn: $shouldShowLocation) {
								Text("Distance and Bearing")
							}
							Toggle(isOn: $shouldShowHops) {
								Text("Hops Away")
							}
							Toggle(isOn: $shouldShowSignal) {
								Text("Signal (Direct Only)")
							}
							Toggle(isOn: $shouldShowChannel) {
								Text("Channel")
							}
							Toggle(isOn: $shouldShowRole) {
								Text("Device Role")
							}
							Toggle(isOn: $shouldShowTelemetry) {
								Text("Log Icons")
							}
						}
						if nodeListDensity == .standard {
							Text("The Complete layout displays all available node data. Fields with no data are automatically hidden.")
								.font(.footnote)
								.foregroundStyle(.secondary)
						}
						BuildTestNode(nodeListDensity: $nodeListDensity)
					}
				}
				}
				Section(header: Text("Environment")) {
					VStack(alignment: .leading) {
						Toggle(isOn: $environmentEnableWeatherKit) {
							Label("Weather Conditions", systemImage: "cloud.sun")
						}
					}
				}
				Section(header: Text("App Data")) {
					Toggle(isOn: $purgeStaleNodes ) {
						Label {
							Text("Clear Stale Nodes")
						} icon: {
							Image(systemName: "list.bullet.circle")
						}
					}
					.onFirstAppear {
						purgeStaleNodes = purgeStaleNodeDays > 0
						Logger.services.info("ℹ️ Purge Stale Nodes toggle initialized to \(purgeStaleNodes)")
#if DEBUG
						showAutoConnect = true
#else
						if Bundle.main.isTestFlight {
							showAutoConnect = true
						}
#endif
					}
					.onChange(of: purgeStaleNodes) { _, newValue in
						purgeStaleNodeDays = purgeStaleNodeDays > 0 ? purgeStaleNodeDays : 7
						purgeStaleNodeDays = newValue ? purgeStaleNodeDays : 0
						Logger.services.info("ℹ️ Purge Stale Nodes changed to \(purgeStaleNodeDays)")
					}

					.listRowSeparator(purgeStaleNodes ? .hidden : .visible)
					if purgeStaleNodes {
						VStack(alignment: .leading) {
							Text(String(localized: "After \(Int(purgeStaleNodeDays)) Days"))
							Slider(value: $purgeStaleNodeDays, in: 1...180, step: 1) {
							} minimumValueLabel: {
								Text("1")
							} maximumValueLabel: {
								Text("180")
							}
							.accessibilityLabel(String(localized: "Days before purging stale nodes", comment: "VoiceOver label for the purge stale nodes days slider"))
							.accessibilityValue(String(localized: "\(Int(purgeStaleNodeDays)) days", comment: "VoiceOver value announcing the number of days before purging stale nodes"))
						}
						Text("Favorited and ignored nodes are always retained. Other nodes are cleared from the app database on the schedule set by the user. (Nodes with PKC keys are always retained for at least 7 days.) This feature only purges nodes from the app that are not stored in the device node database.")
							.foregroundStyle(.secondary)
							.font(idiom == .phone ? .caption : .callout)
					}
					Button {
						isPresentingCoreDataResetConfirm = true
					} label: {
						Label("Clear App Data", systemImage: "trash")
							.foregroundColor(.red)
					}
					.confirmationDialog(
						"Are you sure?",
						isPresented: $isPresentingCoreDataResetConfirm,
						titleVisibility: .visible
					) {
						Button("Erase all app data?", role: .destructive) {
							Task {
								// Pangea: cleared in place on the one container, with the store-bound
								// views unmounted, instead of replacing the container under this
								// screen (see RadioPairing.eraseAppData). That also takes the
								// profile, contacts, notifications, invites and the paired radio,
								// and setup starts again. A radio that won't disconnect stops it.
								guard await RadioPairing.eraseAppData(disconnect: { try await accessoryManager.disconnect() }) else {
									isPresentingEraseFailed = true
									return
								}
								// Repopulate device catalog immediately — no reconnect happens after a full reset.
								try? await MeshtasticAPI.shared.refreshBundledDevicesData()
								// Images and msh.to links are network-backed, so they run in their own task
								// rather than blocking the reset from completing. `Task` rather than
								// `Task.detached` per the repo concurrency guideline; the pass handles its
								// own cancellation.
								Task(priority: .utility) {
									await MeshtasticAPI.shared.refreshDevicesPreferringAPI()
								}
							}
						}
					} message: {
						Text("This erases every chat, your profile and photo, your contacts and their photos, and forgets your radio. Pangea then starts over, like a new install.")
					}
					.alert("Couldn't erase. Try again.", isPresented: $isPresentingEraseFailed) {
						Button("OK", role: .cancel) {}
					}
					Button {
						UserDefaults.standard.reset()
					} label: {
						Label("Reset App Settings", systemImage: "arrow.counterclockwise.circle")
							.foregroundColor(.red)
					}
				}
				// Pangea: the bundled documentation is an Expert Mode screen, so this is too.
				if expertModeEnabled {
				Section(header: Text("Documentation Translations")) {
					Toggle(isOn: $participateInDistributedTranslations) {
						Label("Participate in Distributed Translations", systemImage: "globe")
					}
					Text("Upload on-device translated documentation to help improve translations for the community. Translated docs are shared anonymously so other users get instant translations without needing on-device models.")
						.foregroundStyle(.secondary)
						.font(idiom == .phone ? .caption : .callout)
				}
				}
			}
		}
		.navigationTitle("App Settings")
		.toolbar {
			ConnectedDeviceItem(device: ConnectedDevice(deviceConnected: accessoryManager.isConnected, name: accessoryManager.activeConnection?.device.shortName ?? "?"))
		}
	}
}

struct BuildTestNode: View {
	@Environment(\.modelContext) private var context
	@Binding var nodeListDensity: NodeListDensity
	@State private var previewNode: BuildTestNodeSnapshot?
	
	init(nodeListDensity: Binding<NodeListDensity>) {
		self._nodeListDensity = nodeListDensity
	}

	var body: some View {
		VStack {
			if let previewNode {
				switch nodeListDensity {
				case .standard:
					BuildTestNodeStandardRow(node: previewNode)
				case .compact:
					BuildTestNodeCompactRow(node: previewNode)
				}
			}
		}
		.task {
			loadPreviewNode()
		}
	}

	@MainActor
	private func loadPreviewNode() {
		var descriptor = FetchDescriptor<NodeInfoEntity>(
			sortBy: [SortDescriptor(\NodeInfoEntity.lastHeard, order: .reverse)]
		)
		descriptor.fetchLimit = 1
		guard let exampleNode = try? context.fetch(descriptor).first else {
			previewNode = nil
			return
		}
		previewNode = BuildTestNodeSnapshot(node: exampleNode)
	}
}

private struct BuildTestNodeSnapshot {
	let shortName: String
	let longName: String
	let isFavorite: Bool
	let isOnline: Bool
	let lastHeardText: String
	let roleName: String
	let roleSystemName: String
	let isUnmonitored: Bool
	let isStoreForwardRouter: Bool
	let viaMqtt: Bool
	let channel: Int
	let hopsAway: Int
	let snr: Float
	let keyStatusImage: String
	let keyStatusColor: Color

	init(node: NodeInfoEntity) {
		let role = DeviceRoles(rawValue: Int(node.user?.role ?? 0))
		shortName = node.user?.shortName ?? "?"
		longName = node.user?.longName?.addingVariationSelectors ?? "Unknown".localized
		isFavorite = node.favorite
		isOnline = node.isOnline
		lastHeardText = node.lastHeard?.formatted(date: .numeric, time: .shortened) ?? "Unknown Age".localized
		roleName = role?.name ?? "Unknown".localized
		roleSystemName = role?.systemName ?? "figure"
		isUnmonitored = node.user?.unmessagable ?? false
		isStoreForwardRouter = node.storeForwardConfig?.isRouter ?? false
		viaMqtt = node.viaMqtt
		channel = Int(node.channel)
		hopsAway = Int(node.hopsAway)
		snr = node.snr

		let indicator = NodeSecurityIndicator.status(
			firmwareVersion: node.metadata?.firmwareVersion,
			pkiEncrypted: node.user?.pkiEncrypted ?? false,
			keyMatch: node.user?.keyMatch ?? false,
			signed: node.hasXeddsaSigned,
			verified: node.isKeyManuallyVerified
		)
		keyStatusImage = indicator.glyph.image
		keyStatusColor = indicator.glyph.color
	}
}

private struct BuildTestNodeStandardRow: View {
	let node: BuildTestNodeSnapshot
	private var modemPreset: ModemPresets { ModemPresets(rawValue: UserDefaults.modemPreset) ?? .longFast }

	var body: some View {
		// Plain VStack, not LazyVStack: a LazyVStack inside a List cell returns inconsistent
		// self-sized heights and trips the recursive layout-loop trap on iOS 18+/26.
		VStack(alignment: .leading) {
			HStack {
				VStack(alignment: .center) {
					CircleText(text: node.shortName, color: Color(UIColor(hex: 0x76A5AF)), circleSize: 70)
						.padding(.trailing, 5)
				}
				VStack(alignment: .leading) {
					HStack {
						IconAndText(systemName: node.keyStatusImage,
									imageColor: node.keyStatusColor,
									text: node.longName,
									textColor: .primary)
						if node.isFavorite {
							Spacer()
							Image(systemName: "star.fill")
								.symbolRenderingMode(.multicolor)
						}
					}
					IconAndText(systemName: "antenna.radiowaves.left.and.right.circle.fill",
								imageColor: .green,
								text: "Connected".localized)
					IconAndText(systemName: node.isOnline ? "checkmark.circle.fill" : "moon.circle.fill",
								imageColor: node.isOnline ? .green : .orange,
								text: node.lastHeardText)
					IconAndText(systemName: node.roleSystemName,
								text: "Role: \(node.roleName)")
					if node.isUnmonitored {
						IconAndText(systemName: "iphone.slash",
									renderingMode: .multicolor,
									text: "Unmonitored")
					}
					if node.isStoreForwardRouter {
						IconAndText(systemName: "envelope.arrow.triangle.branch",
									renderingMode: .multicolor,
									text: "Store & Forward".localized)
					}
					HStack {
						if node.channel > 0 {
							IconAndText(systemName: "\(node.channel).circle.fill", text: "Channel")
						}
						if node.viaMqtt {
							IconAndText(systemName: "dot.radiowaves.up.forward",
										renderingMode: .multicolor,
										text: "MQTT")
						}
					}
					if node.hopsAway > 0 {
						HStack {
							IconAndText(systemName: "hare", text: "Hops Away:")
							Image(systemName: "\(node.hopsAway).square")
								.font(.title2)
						}
					} else if node.snr != 0 && !node.viaMqtt {
						LoRaSignalStrengthMeter(snr: node.snr, rssi: 0, preset: modemPreset, compact: true)
							.padding(.top, 15)
					}
				}
			}
		}
	}
}

private struct BuildTestNodeCompactRow: View {
	let node: BuildTestNodeSnapshot

	var body: some View {
		// Plain VStack, not LazyVStack: a LazyVStack inside a List cell returns inconsistent
		// self-sized heights and trips the recursive layout-loop trap on iOS 18+/26.
		VStack(alignment: .leading) {
			HStack {
				VStack(alignment: .center) {
					CircleText(text: node.shortName, color: Color(UIColor(hex: 0x76A5AF)), circleSize: 42)
						.padding(.trailing, 5)
				}
				VStack(alignment: .leading, spacing: 2) {
					HStack(alignment: .firstTextBaseline) {
						IconAndText(systemName: node.keyStatusImage,
									imageColor: node.keyStatusColor,
									text: node.longName,
									textColor: .primary)
						if node.isFavorite {
							Spacer()
							Image(systemName: "star.fill")
								.symbolRenderingMode(.multicolor)
						}
					}
					IconAndText(systemName: node.isOnline ? "checkmark.circle.fill" : "moon.circle.fill",
								imageColor: node.isOnline ? .green : .orange,
								text: node.lastHeardText)
					HStack(alignment: .center, spacing: 6) {
						if node.hopsAway > 0 {
							DefaultIconCompact(systemName: "\(node.hopsAway).square")
						} else if node.snr != 0 && !node.viaMqtt {
							DefaultIconCompact(systemName: "dot.radiowaves.left.and.right")
						}
						if node.channel > 0 {
							Divider().frame(height: 15)
							DefaultIconCompact(systemName: "\(node.channel).circle.fill")
						}
						Divider().frame(height: 15)
						DefaultIconCompact(systemName: node.roleSystemName)
						if node.isUnmonitored {
							DefaultIconCompact(systemName: "iphone.slash")
						}
						if node.isStoreForwardRouter {
							DefaultIconCompact(systemName: "envelope.arrow.triangle.branch")
						}
						if node.viaMqtt {
							DefaultIconCompact(systemName: "dot.radiowaves.up.forward")
						}
					}
					.padding(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 0))
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
		.padding(.top, 2)
		.padding(.bottom, 2)
	}
}
