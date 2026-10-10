//
//  MyCodeCard.swift
//  Pangea
//
//  "Your code is @4KQ2-F9MX" with share and QR. Shown in New Message and Settings.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct MyCode {
	let code: String
	let name: String
	let link: URL?

	@MainActor
	static func current(_ accessoryManager: AccessoryManager) -> MyCode? {
		guard let num = accessoryManager.activeDeviceNum,
			  let user = getNodeInfo(id: num, context: accessoryManager.context)?.user else { return nil }
		return MyCode(
			code: PangeaCode.code(for: num),
			name: user.longName ?? "",
			link: PangeaCode.link(nodeNum: num, user: user.toProto())
		)
	}

	var shareText: String {
		String(localized: "Message me on Pangea: \(code)")
	}
}

struct MyCodeCard: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@State private var showQR = false
	@State private var copied = false

	var body: some View {
		if let mine = MyCode.current(accessoryManager) {
			VStack(alignment: .leading, spacing: 12) {
				Text("Your code")
					.font(.subheadline)
					.foregroundStyle(.secondary)
				HStack {
					Text(mine.code)
						.font(.system(.title, design: .monospaced).weight(.semibold))
						.textSelection(.enabled)
						.minimumScaleFactor(0.7)
						.lineLimit(1)
					Spacer()
					Button {
						UIPasteboard.general.string = mine.code
						copied = true
						Task {
							try? await Task.sleep(for: .seconds(1.5))
							copied = false
						}
					} label: {
						Image(systemName: copied ? "checkmark" : "doc.on.doc")
							.contentTransition(.symbolEffect(.replace))
					}
					.accessibilityLabel("Copy code")
				}
				HStack(spacing: 12) {
					if let link = mine.link {
						ShareLink(item: link, message: Text(mine.shareText)) {
							Label("Share", systemImage: "square.and.arrow.up")
								.frame(maxWidth: .infinity)
						}
						.buttonStyle(.borderedProminent)
					}
					Button {
						showQR = true
					} label: {
						Label("Show QR", systemImage: "qrcode")
							.frame(maxWidth: .infinity)
					}
					.buttonStyle(.bordered)
				}
				.controlSize(.large)
				.buttonBorderShape(.capsule)
			}
			.padding()
			.background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
			.sheet(isPresented: $showQR) {
				MyQRCodeSheet(mine: mine)
					.presentationDetents([.medium, .large])
			}
		}
	}
}

struct MyQRCodeSheet: View {
	let mine: MyCode

	private var image: UIImage? {
		guard let link = mine.link else { return nil }
		let filter = CIFilter.qrCodeGenerator()
		filter.message = Data(link.absoluteString.utf8)
		filter.correctionLevel = "M"
		guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
			  let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
		return UIImage(cgImage: cgImage)
	}

	var body: some View {
		VStack(spacing: 16) {
			Text(mine.name)
				.font(.title2.bold())
				.padding(.top, 24)
			if let image {
				Image(uiImage: image)
					.interpolation(.none)
					.resizable()
					.scaledToFit()
					.frame(maxWidth: 260)
					.padding(12)
					.background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
			}
			Text(mine.code)
				.font(.system(.title3, design: .monospaced).weight(.semibold))
			Text("Have your friend scan this in Pangea to message you.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
			Spacer()
		}
		.padding()
	}
}
