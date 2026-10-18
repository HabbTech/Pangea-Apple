import OSLog
import SwiftData
import SwiftUI
import TipKit

/// One main window. Owns that window's navigation. The database, the radio,
/// and the badge stay on `AppState` and are shared with every other window.
struct MainScene: View {
	let persistenceController: PersistenceController
	@StateObject private var router = Router()
	@StateObject private var nodeFilters = NodeFilterParameters()
	@StateObject private var pairRadio = PairRadioPresenter()
	@ObservedObject private var legacyImport = LegacyStoreImport.shared
	@EnvironmentObject private var appState: AppState
	@EnvironmentObject private var accessoryManager: AccessoryManager
	@Environment(\.scenePhase) private var scenePhase
	@State private var saveChannelLink: SaveChannelLinkData?
	@State private var pendingContact: PendingContact?
	@State private var routerToken: UUID?

	/// TipKit configuration must run once per process. This view stays mounted
	/// across node switches; the flag is a backstop if a window is recreated.
	private static var hasConfiguredTips = false

	var body: some View {
		sceneContent
			// Pangea: above the reset gate below, so clearing the old radio's chats while pairing
			// a different one (which unmounts the store-bound tree) doesn't close the sheet before
			// its name/region step. Nothing in it reads the store through SwiftUI, so it needs no
			// .modelContainer; it gets its own copy of what it reads from the environment.
			.sheet(isPresented: $pairRadio.isPresented) {
				PairRadioSheet()
					.environmentObject(accessoryManager)
					.environmentObject(appState)
					.tint(Color.pangeaPrimary)
			}
			.environmentObject(router)
			.environmentObject(nodeFilters)
			.environmentObject(pairRadio)
			.onAppear {
				if routerToken == nil {
					routerToken = appState.sceneRouters.register(router)
					if let launch = appState.takeLaunchNavigation() {
						router.navigationState = launch
					}
				}
				// A notification can arrive before this window exists. `onChange`
				// does not replay the value it already holds.
				claimPendingRoute()
			}
			.onDisappear {
				guard let routerToken else { return }
				appState.sceneRouters.unregister(routerToken)
				self.routerToken = nil
			}
			.onOpenURL { url in
				Logger.mesh.debug("URL received")
				dispatchIncomingURL(url, fromActivity: false)
			}
			.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
				Logger.mesh.debug("Browsing web user activity received")
				saveChannelLink = nil
				if let url = userActivity.webpageURL {
					dispatchIncomingURL(url, fromActivity: true)
				}
			}
			// Pangea: an open main window takes every link, so one opened from the map window
			// (Send Message on a profile) lands here instead of in a new main window.
			.handlesExternalEvents(preferring: ["*"], allowing: ["*"])
			.onChange(of: appState.pendingRoute?.id) { _, _ in
				claimPendingRoute()
			}
			.onChange(of: scenePhase) { _, phase in
				if phase == .active {
					claimPendingRoute()
				}
			}
			.task {
				// Pangea: placeholders saved by an earlier version as "Pangea 1a2b" go back to the
				// firmware default name. Its own context, so nothing on screen sees a half-done pass.
				// After the old store's import, which owns the store until it has saved.
				if legacyImport.holdsStore {
					await legacyImport.waitUntilFinished()
				}
				if !legacyImport.needsFreeSpace {
					renameOldPlaceholderNames(context: ModelContext(persistenceController.container))
				}
				// Skip TipKit during marketing screenshot capture so tip popovers never
				// appear in the shots (unconfigured TipKit displays nothing).
				if !Self.hasConfiguredTips, !CommandLine.arguments.contains("--marketing-capture") {
					Self.hasConfiguredTips = true
					try? Tips.configure(
						[
							.datastoreLocation(.applicationDefault),
							.displayFrequency(.immediate)
						]
					)
				}
			}
	}

	@ViewBuilder
	private var sceneContent: some View {
		if legacyImport.holdsStore {
			// Pangea: the old chats are still being imported (or the import ran out of space and
			// the store waits for the app to be reopened); nothing may read the store yet.
			LegacyImportPlaceholder(needsFreeSpace: legacyImport.needsFreeSpace)
				.onDisappear {
					appState.refreshBadgeCount(context: persistenceController.container.mainContext)
				}
		} else if appState.isDatabaseResetting {
			// Unmount the SwiftData-bound tree — including `.modelContainer` —
			// while a node switch clears the store. The modifier's bridge
			// observes save notifications process-wide and never rebinds; a
			// stale bridge traps on the next save. The
			// router stays on this view, above the gate, so the window keeps
			// its tab.
			DatabaseResettingPlaceholder(isErasingAppData: appState.isErasingAppData)
		} else {
			loadedContent
		}
	}

	private var loadedContent: some View {
		EventFirmwareTintScope {
			ContentView(
				appState: appState,
				router: router
			)
			.id(appState.databaseResetID)
			// The AccentColor asset alone doesn't reach every SwiftUI surface, so
			// tint the scene explicitly to keep the Fossil primary consistent.
			.tint(Color.pangeaPrimary)
			.sheet(item: $saveChannelLink) { link in
				SaveChannelQRCode(
					channelSetLink: link.data,
					addChannels: link.add,
					accessoryManager: accessoryManager
				)
				.presentationDetents([.large])
				#if !targetEnvironment(macCatalyst)
				.presentationDragIndicator(.visible)
				#endif
			}
			.contactImportSheet($pendingContact, accessoryManager: accessoryManager)
			// Badge refresh reads the store, so it has to unmount with the
			// container during a node switch. Message lists, Siri, and CarPlay
			// all post this.
			.onReceive(
				NotificationCenter.default.publisher(for: .meshMessagesDidChange)
					.debounce(for: .seconds(1), scheduler: DispatchQueue.main)
			) { _ in
				appState.refreshBadgeCount(context: persistenceController.container.mainContext)
			}
		}
		.modelContainer(persistenceController.container)
		.environmentObject(appState)
		.environmentObject(accessoryManager)
		.environmentObject(router)
		.environmentObject(nodeFilters)
		.environmentObject(MeshtasticAPI.shared)
	}

	/// Notification taps land on `AppState` because the app delegate has no
	/// window. This window takes the route only while it is active, and clears
	/// it so another window does not navigate too.
	private func claimPendingRoute() {
		guard scenePhase == .active else { return }
		guard let url = appState.claimPendingRoute() else { return }
		dispatchIncomingURL(url, fromActivity: false)
	}

	private func dispatchIncomingURL(_ url: URL, fromActivity: Bool) {
		// Pangea: group invites, @codes and profile links first.
		if PangeaInbox.shared.handle(url: url) {
			return
		}
		if url.isFileURL {
			router.importMapFile(url: url)
		} else if ContactURLHandler.canHandle(url) {
			// Pangea: a contact link from a Pangea user opens as a chat invite.
			if let invite = PangeaCode.invite(from: url) {
				PangeaInbox.shared.open(invite)
			} else if let pending = ContactURLHandler.makePendingContact(from: url, accessoryManager: accessoryManager) {
				pendingContact = pending
			}
		} else if MeshtasticChannelURL.canHandle(url) {
			handleChannelLinkURL(url, fromActivity: fromActivity)
		} else if url.absoluteString.lowercased().contains("meshtastic:///") {
			router.route(url: url)
		}
	}

	@discardableResult
	private func handleChannelLinkURL(_ url: URL, fromActivity: Bool) -> Bool {
		saveChannelLink = nil

		guard MeshtasticChannelURL.canHandle(url) else {
			return false
		}

		let channelLink: MeshtasticChannelURL
		do {
			channelLink = try MeshtasticChannelURL.parse(url.absoluteString)
		} catch {
			Logger.mesh.error("Could not parse channel URL: \(error.localizedDescription, privacy: .public)")
			return false
		}

		saveChannelLink = SaveChannelLinkData(data: channelLink.payload, add: channelLink.addChannels)
		Logger.services.debug("Add Channel \(channelLink.addChannels, privacy: .public)")

		let source = fromActivity ? "User Activity" : "Open URL"
		Logger.mesh.debug("User wants to open a Channel Settings URL (\(source, privacy: .public))")
		return true
	}
}
