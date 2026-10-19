//
//  StandardMapTests.swift
//  MeshtasticTests
//

import CoreLocation
import Foundation
import Testing
@testable import Meshtastic

/// Standard mode's tabs and its plain map: which tabs show and in what order, where a route
/// to a hidden tab lands, which radios a tap on the map opens, and the profile sheet it opens.
@Suite("Standard mode map")
@MainActor
struct StandardMapTests {

	private func node(_ num: Int64) -> MeshMapItem {
		.node(MeshMapPositionSnapshot(
			id: num,
			coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.33),
			latitudeI: 476_000_000,
			longitudeI: -1_223_300_000,
			precisionBits: 32,
			nodeNum: num,
			longName: "Node \(num)",
			shortName: "\(num)",
			isOnline: true,
			viaMqtt: false,
			calculatedDelay: 0
		))
	}

	// MARK: Tabs

	@Test func standardModeLeadsWithTheMap() {
		#expect(PangeaTabs.order(expertMode: false) == [.map, .messages, .settings])
		#expect(PangeaTabs.order(expertMode: true) == [.messages, .nodes, .map, .settings, .connect])
	}

	@Test func legacyTabsFollowTheSameOrder() {
		for expert in [false, true] {
			let legacy = ContentView.LegacyTab.tabs(expertMode: expert).map(\.value)
			#expect(legacy == PangeaTabs.order(expertMode: expert))
		}
	}

	@Test func hiddenTabsLandOnChats() {
		#expect(PangeaTabs.visibleSelection(.map, expertMode: false) == .map)
		#expect(PangeaTabs.visibleSelection(.settings, expertMode: false) == .settings)
		#expect(PangeaTabs.visibleSelection(.nodes, expertMode: false) == .messages)
		#expect(PangeaTabs.visibleSelection(.connect, expertMode: false) == .messages)
		// Expert Mode shows every tab.
		#expect(PangeaTabs.visibleSelection(.connect, expertMode: true) == .connect)
		#expect(PangeaTabs.visibleSelection(.nodes, expertMode: true) == .nodes)
	}

	// MARK: Your own radio

	@Test func myRadioOpensNothingWhileItsAway() {
		// Disconnected: no active radio, so the last one still counts as mine.
		let myNum = ChatsView.myNum(activeDeviceNum: nil, preferred: 1)
		#expect(!MeshMapMK.opensProfile(for: 1, myNum: myNum))
		#expect(MeshMapMK.opensProfile(for: 2, myNum: myNum))
		// Never paired: everyone opens.
		#expect(MeshMapMK.opensProfile(for: 1, myNum: ChatsView.myNum(activeDeviceNum: nil, preferred: 0)))
	}

	@Test func pickerLeavesOutMyRadio() {
		let items = [node(1), node(2), node(3)]
		let rows = MeshMapMK.standardPickerItems(items, myNum: 2)
		#expect(rows.map(\.id) == [node(1), node(3)].map(\.id))
		#expect(MeshMapMK.standardPickerItems(items, myNum: nil).count == 3)
	}

	// MARK: VoiceOver

	@Test func clusterLabelCountsWhatsInIt() {
		let waypoint = MeshMapItem.waypoint(MeshMapWaypointSnapshot(
			id: 99,
			coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.33),
			name: "Camp",
			icon: "⛺️"
		))
		let radios = MeshMapMK.clusterAccessibility(for: [node(1), node(2), node(3)])
		#expect(radios.label == "3 radios here")
		#expect(radios.isButton)
		// The action is a hint, not part of the label.
		#expect(radios.hint?.isEmpty == false)
		#expect(!radios.label.localizedCaseInsensitiveContains("double-tap"))
		// Expert Mode clusters waypoints with radios; they aren't counted as radios.
		#expect(MeshMapMK.clusterAccessibility(for: [node(1), node(2), waypoint]).label == "3 radios and waypoints here")
		#expect(MeshMapMK.clusterAccessibility(for: [waypoint, waypoint]).label == "2 waypoints here")
	}

	/// An Expert Mode pin never reads as a bare "Button": a blank long name falls back to the
	/// short name, then to the node id.
	@Test func expertPinNameFallsBack() {
		#expect(MeshMapMK.expertPinName(longName: " Base Camp ", shortName: "BC", nodeNum: 1) == "Base Camp")
		#expect(MeshMapMK.expertPinName(longName: "  ", shortName: "BC", nodeNum: 1) == "BC")
		#expect(MeshMapMK.expertPinName(longName: "?", shortName: nil, nodeNum: 0xA1B2C3D4) == "!a1b2c3d4")
		#expect(MeshMapMK.expertPinName(longName: "", shortName: " ", nodeNum: 255) == "!000000ff")
		// A Hangul filler (U+3164) draws nothing, so it counts as blank too.
		#expect(MeshMapMK.expertPinName(longName: "\u{3164}", shortName: "BC", nodeNum: 1) == "BC")
		#expect(MeshMapMK.expertPinName(longName: "\u{3164}", shortName: "\u{3164}", nodeNum: 255) == "!000000ff")
	}

	// MARK: Send Message from the map window

	// MainScene.dispatchIncomingURL is a private method on the window's view, so these walk its
	// checks in the same order: PangeaInbox first, then file, contact and channel links, then
	// meshtastic:/// routes. Each earlier step must pass on the link for the later one to get it.

	@Test func chatLinkOpensTheirMessages() throws {
		let url = try #require(ContactProfileSheet.chatURL(num: 0x1234_5678, hasKey: true))
		// Not a pangea:// link, so the inbox passes it on without touching its state.
		#expect(!PangeaInbox.shared.handle(url: url))
		#expect(!url.isFileURL)
		#expect(!ContactURLHandler.canHandle(url))
		#expect(!MeshtasticChannelURL.canHandle(url))
		#expect(url.absoluteString.lowercased().contains("meshtastic:///"))
		let router = Router()
		router.route(url: url)
		#expect(router.selectedTab == .messages)
		#expect(router.messagesState == .directMessages(userNum: 0x1234_5678))
	}

	@Test func chatLinkWithoutKeysOpensNewMessage() throws {
		let url = try #require(ContactProfileSheet.chatURL(num: 0x1234_5678, hasKey: false))
		let inbox = PangeaInbox.shared
		defer {
			inbox.pendingInvite = nil
			inbox.isComposing = false
			inbox.joinRequest = nil
			inbox.joinRequestSource = nil
		}
		#expect(inbox.handle(url: url))
		#expect(inbox.pendingInvite?.nodeNum == 0x1234_5678)
		#expect(inbox.isComposing)
		// Taken as a person's code, not a group invite.
		#expect(inbox.joinRequest == nil)
	}

	// MARK: Nickname on a profile

	@Test func openingAProfileSavesNoNickname() {
		#expect(ContactProfileSheet.nicknameEdit(typed: "", loaded: "", stored: nil) == nil)
		#expect(ContactProfileSheet.nicknameEdit(typed: "Sam", loaded: "Sam", stored: "Sam") == nil)
		// Only spaces added: the same nickname.
		#expect(ContactProfileSheet.nicknameEdit(typed: " Sam ", loaded: "Sam", stored: "Sam") == nil)
	}

	@Test func typedNicknameIsSaved() {
		#expect(ContactProfileSheet.nicknameEdit(typed: " Sam ", loaded: "", stored: nil) == "Sam")
		#expect(ContactProfileSheet.nicknameEdit(typed: "Sammy", loaded: "Sam", stored: "Sam") == "Sammy")
		// Cleared: saved as no nickname.
		#expect(ContactProfileSheet.nicknameEdit(typed: "  ", loaded: "Sam", stored: "Sam") == "")
	}

	@Test func untouchedFieldKeepsAChangeFromElsewhere() {
		// Another window renamed them while this sheet was open and untouched.
		#expect(ContactProfileSheet.nicknameEdit(typed: "Sam", loaded: "Sam", stored: "Samuel") == nil)
		// The store already has what was typed here.
		#expect(ContactProfileSheet.nicknameEdit(typed: "Samuel", loaded: "Sam", stored: "Samuel") == nil)
	}
}
