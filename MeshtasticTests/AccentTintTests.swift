//
//  AccentTintTests.swift
//  MeshtasticTests
//
//  Copyright(c) Garth Vander Houwen 9/8/26.
//

import Testing
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@testable import Meshtastic

/// The app carries two accents: `accentColor` to draw text and glyphs on a surface, and
/// `accentFill` to fill a shape under white text. In Pangea the fill is Ember, and the text
/// accent is Ember in light mode and Fossil Light in dark mode.
@Suite("Accent tint")
struct AccentTintTests {

	#if canImport(UIKit)
	/// The text accent by asset name rather than through `Color.accentColor`. The brand extension
	/// shadows SwiftUI's `accentColor`, which resolves inside the app but is ambiguous from here,
	/// where both declarations are visible. `accentFill` has no such clash and is read directly.
	private static let textAccentAsset = "AccentColor"

	private func traits(dark: Bool, highContrast: Bool = false) -> UITraitCollection {
		UITraitCollection(userInterfaceStyle: dark ? .dark : .light).modifyingTraits {
			$0.accessibilityContrast = highContrast ? .high : .normal
		}
	}

	private func resolved(_ color: Color, dark: Bool, highContrast: Bool = false) -> UIColor {
		UIColor(color).resolvedColor(with: traits(dark: dark, highContrast: highContrast))
	}

	private func resolved(asset: String, dark: Bool, highContrast: Bool = false) -> UIColor? {
		UIColor(named: asset)?.resolvedColor(with: traits(dark: dark, highContrast: highContrast))
	}

	/// True when every sRGB component of `a` is within 1/255 of `b`. Luminance alone lets two
	/// different hues of similar brightness pass as the same colour.
	private func sameRGB(_ a: UIColor, _ b: UIColor) -> Bool {
		var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
		var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
		a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
		b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
		let tolerance: CGFloat = 1.0 / 255 + 0.0001
		return abs(ar - br) <= tolerance && abs(ag - bg) <= tolerance && abs(ab - bb) <= tolerance
	}

	private func hex(_ color: UIColor) -> String {
		var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
		color.getRed(&r, green: &g, blue: &b, alpha: &a)
		return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
	}

	private func luminance(_ color: UIColor) -> CGFloat {
		var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
		color.getRed(&r, green: &g, blue: &b, alpha: &a)
		func lin(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
		return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
	}

	private func ratio(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
		(max(a, b) + 0.05) / (min(a, b) + 0.05)
	}

	private static let ember = UIColor(red: 0xC2 / 255, green: 0x41 / 255, blue: 0x0C / 255, alpha: 1)
	private static let fossilLight = UIColor(red: 0xF2 / 255, green: 0x6A / 255, blue: 0x2E / 255, alpha: 1)
	/// Increase Contrast: the light text accent darkens and the dark one lightens.
	private static let emberHigh = UIColor(red: 0xA8 / 255, green: 0x38 / 255, blue: 0x0A / 255, alpha: 1)
	private static let fossilLightHigh = UIColor(red: 0xF5 / 255, green: 0x8A / 255, blue: 0x5C / 255, alpha: 1)
	/// The grouped card in a dark sheet (the elevated level), the darkest-case lighter surface.
	private static let elevatedDarkCard = UIColor(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1)
	/// The same card with Increase Contrast on, lighter still.
	private static let elevatedDarkCardHigh = UIColor(red: 0x36 / 255, green: 0x36 / 255, blue: 0x38 / 255, alpha: 1)
	/// The light grouped background with Increase Contrast on.
	private static let lightGroupedHigh = UIColor(red: 0xEB / 255, green: 0xEB / 255, blue: 0xF0 / 255, alpha: 1)

	/// Pangea: the fill under white text (the user's own bubbles, prominent buttons, badges) is
	/// Ember #C2410C in both appearances. White on Fossil itself is only 3.5:1.
	@Test("the fill accent is Ember in both appearances")
	func fillAccentIsEmberInBothAppearances() {
		// Reads Color.accentFill itself. Increase Contrast keeps Ember too.
		for dark in [false, true] {
			for high in [false, true] {
				let fill = resolved(.accentFill, dark: dark, highContrast: high)
				#expect(sameRGB(fill, Self.ember), "accentFill is \(hex(fill)) (dark: \(dark), high: \(high))")
			}
		}
	}

	/// White text and links on the fill (own bubbles: links there are white, underlined) meet
	/// WCAG AA for body text, 4.5:1. A palette change that lightens the fill past that fails here.
	@Test("white on the fill accent meets 4.5:1")
	func whiteOnFillAccentKeepsContrast() {
		for dark in [false, true] {
			for high in [false, true] {
				let contrast = ratio(1.0, luminance(resolved(.accentFill, dark: dark, highContrast: high)))
				#expect(contrast >= 4.5, "white on accentFill is \(contrast):1 (dark: \(dark), high: \(high))")
			}
		}
	}

	/// Pangea: the text accent is Ember in light mode and Fossil Light in dark mode, so orange
	/// text reads at 4.5:1 or better on white, and on dark cards both in a screen and in a sheet.
	/// Sheets sit at the elevated level, where grouped cards are #2C2C2E rather than #1C1C1E.
	@Test("the text accent is Ember in light mode and Fossil Light in dark mode")
	func textAccentMeetsContrastInBothAppearances() {
		guard let light = resolved(asset: Self.textAccentAsset, dark: false),
			  let dark = resolved(asset: Self.textAccentAsset, dark: true) else {
			Issue.record("\(Self.textAccentAsset) missing"); return
		}
		#expect(sameRGB(light, Self.ember), "light text accent is \(hex(light))")
		#expect(sameRGB(dark, Self.fossilLight), "dark text accent is \(hex(dark))")
		#expect(ratio(luminance(light), luminance(.white)) >= 4.5)

		let base = UITraitCollection(userInterfaceStyle: .dark)
		let elevated = base.modifyingTraits { $0.userInterfaceLevel = .elevated }
		let darkSurfaces: [(String, UIColor)] = [
			("#2C2C2E", Self.elevatedDarkCard),
			("base grouped card", UIColor.secondarySystemGroupedBackground.resolvedColor(with: base)),
			("elevated grouped card", UIColor.secondarySystemGroupedBackground.resolvedColor(with: elevated))
		]
		for (name, surface) in darkSurfaces {
			let contrast = ratio(luminance(dark), luminance(surface))
			#expect(contrast >= 4.5, "text accent on \(name) is \(contrast):1")
		}
	}

	/// With Increase Contrast on, grouped surfaces shift (dark cards lighten to #363638 in a sheet,
	/// the light grouped background darkens to #EBEBF0), and the text accent shifts with them so
	/// it still reads at 4.5:1 or better.
	@Test("the text accent keeps 4.5:1 with Increase Contrast")
	func textAccentMeetsContrastWithIncreaseContrast() {
		guard let light = resolved(asset: Self.textAccentAsset, dark: false, highContrast: true),
			  let dark = resolved(asset: Self.textAccentAsset, dark: true, highContrast: true) else {
			Issue.record("\(Self.textAccentAsset) missing"); return
		}
		#expect(sameRGB(light, Self.emberHigh), "light high-contrast text accent is \(hex(light))")
		#expect(sameRGB(dark, Self.fossilLightHigh), "dark high-contrast text accent is \(hex(dark))")

		let lightHigh = traits(dark: false, highContrast: true)
		let lightSurfaces: [(String, UIColor)] = [
			("white", .white),
			("#EBEBF0", Self.lightGroupedHigh),
			("high-contrast grouped background", UIColor.systemGroupedBackground.resolvedColor(with: lightHigh))
		]
		for (name, surface) in lightSurfaces {
			let contrast = ratio(luminance(light), luminance(surface))
			#expect(contrast >= 4.5, "high-contrast text accent on \(name) is \(contrast):1")
		}

		let darkHigh = traits(dark: true, highContrast: true)
		let darkHighElevated = darkHigh.modifyingTraits { $0.userInterfaceLevel = .elevated }
		let darkSurfaces: [(String, UIColor)] = [
			("#363638", Self.elevatedDarkCardHigh),
			("high-contrast base grouped card", UIColor.secondarySystemGroupedBackground.resolvedColor(with: darkHigh)),
			("high-contrast elevated grouped card", UIColor.secondarySystemGroupedBackground.resolvedColor(with: darkHighElevated))
		]
		for (name, surface) in darkSurfaces {
			let contrast = ratio(luminance(dark), luminance(surface))
			#expect(contrast >= 4.5, "high-contrast text accent on \(name) is \(contrast):1")
		}
	}

	/// The tint the app sets on its windows matches the text accent, in both appearances and
	/// with Increase Contrast on or off.
	@Test("the app tint matches the text accent")
	func appTintMatchesTextAccent() {
		for dark in [false, true] {
			for high in [false, true] {
				guard let asset = resolved(asset: Self.textAccentAsset, dark: dark, highContrast: high) else {
					Issue.record("\(Self.textAccentAsset) missing"); return
				}
				let tint = resolved(.pangeaPrimary, dark: dark, highContrast: high)
				#expect(sameRGB(tint, asset), "tint \(hex(tint)) vs asset \(hex(asset)) (dark: \(dark), high: \(high))")
			}
		}
	}
	#endif
}
