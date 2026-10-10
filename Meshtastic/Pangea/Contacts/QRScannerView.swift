//
//  QRScannerView.swift
//  Pangea
//
//  In-app QR scanning so people never have to leave for the Camera app.
//

import SwiftUI
import VisionKit
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
	var onScan: (String) -> Void

	static var isAvailable: Bool {
		DataScannerViewController.isSupported && DataScannerViewController.isAvailable
	}

	func makeUIViewController(context: Context) -> DataScannerViewController {
		let scanner = DataScannerViewController(
			recognizedDataTypes: [.barcode(symbologies: [.qr])],
			qualityLevel: .balanced,
			isHighlightingEnabled: true
		)
		scanner.delegate = context.coordinator
		try? scanner.startScanning()
		return scanner
	}

	func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

	static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
		controller.stopScanning()
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(onScan: onScan)
	}

	final class Coordinator: NSObject, DataScannerViewControllerDelegate {
		let onScan: (String) -> Void
		private var didScan = false

		init(onScan: @escaping (String) -> Void) {
			self.onScan = onScan
		}

		func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
			guard !didScan else { return }
			for item in addedItems {
				if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
					didScan = true
					UINotificationFeedbackGenerator().notificationOccurred(.success)
					onScan(value)
					return
				}
			}
		}
	}
}

/// Full-screen scanner with a cancel button and a hint.
struct QRScannerSheet: View {
	@Environment(\.dismiss) private var dismiss
	@State private var cameraAllowed: Bool?
	var onScan: (String) -> Void

	var body: some View {
		NavigationStack {
			Group {
				if cameraAllowed == nil {
					ProgressView()
				} else if cameraAllowed == true && QRScannerView.isAvailable {
					QRScannerView { value in
						onScan(value)
						dismiss()
					}
					.ignoresSafeArea()
				} else {
					ContentUnavailableView(
						"Camera Not Available",
						systemImage: "camera.fill",
						description: Text("Allow camera access for Pangea in the Settings app to scan codes.")
					)
				}
			}
			.safeAreaInset(edge: .bottom) {
				Text("Point your camera at a Pangea code")
					.font(.callout.weight(.medium))
					.padding(.horizontal, 16)
					.padding(.vertical, 10)
					.background(.regularMaterial, in: Capsule())
					.padding(.bottom)
			}
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }
				}
			}
			.task {
				cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
			}
		}
	}
}
