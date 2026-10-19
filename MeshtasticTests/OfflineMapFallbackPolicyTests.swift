//
//  OfflineMapFallbackPolicyTests.swift
//  MeshtasticTests
//

import Testing

@testable import Meshtastic

@Suite("Offline map fallback policy")
struct OfflineMapFallbackPolicyTests {
	@Test func disabledPreferenceFallsBackWithoutNetworkWhenMapsExist() {
		#expect(OfflineMapFallbackPolicy.shouldRenderOfflineMaps(
			userEnabled: false,
			hasSavedMaps: true,
			networkAvailable: false
		))
	}

	@Test func disabledPreferenceDoesNotRenderWhileOnline() {
		#expect(!OfflineMapFallbackPolicy.shouldRenderOfflineMaps(
			userEnabled: false,
			hasSavedMaps: true,
			networkAvailable: true
		))
	}

	@Test func enabledPreferenceRendersWithoutSavedMaps() {
		#expect(OfflineMapFallbackPolicy.shouldRenderOfflineMaps(
			userEnabled: true,
			hasSavedMaps: false,
			networkAvailable: true
		))
	}

	@Test func noMapsDoesNotCreateAnOfflineFallback() {
		#expect(!OfflineMapFallbackPolicy.shouldRenderOfflineMaps(
			userEnabled: false,
			hasSavedMaps: false,
			networkAvailable: false
		))
	}

	@Test func expertModeAppliesTheSettingOnEveryStyle() {
		for layer in MapLayer.allCases {
			#expect(OfflineMapFallbackPolicy.userWantsOfflineTiles(enabled: true, expertMode: true, layer: layer))
			#expect(!OfflineMapFallbackPolicy.userWantsOfflineTiles(enabled: false, expertMode: true, layer: layer))
		}
	}

	@Test func standardModeAppliesTheSettingOnlyOnTheStandardStyle() {
		#expect(OfflineMapFallbackPolicy.userWantsOfflineTiles(enabled: true, expertMode: false, layer: .standard))
		// A legacy saved "offline" style draws as Standard, so it gets the tiles too.
		#expect(OfflineMapFallbackPolicy.userWantsOfflineTiles(enabled: true, expertMode: false, layer: .offline))
		#expect(!OfflineMapFallbackPolicy.userWantsOfflineTiles(enabled: true, expertMode: false, layer: .hybrid))
		#expect(!OfflineMapFallbackPolicy.userWantsOfflineTiles(enabled: true, expertMode: false, layer: .satellite))
		for layer in MapLayer.allCases {
			#expect(!OfflineMapFallbackPolicy.userWantsOfflineTiles(enabled: false, expertMode: false, layer: layer))
		}
	}
}
