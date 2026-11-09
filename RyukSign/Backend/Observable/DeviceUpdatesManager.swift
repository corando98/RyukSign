//
//  DeviceUpdatesManager.swift
//  RyukSign
//
//  Created by Ryuk
//

import Foundation
import AltSourceKit
import IDeviceSwift

/// An app on this device, or signed in the library, with a newer version in a source.
struct DeviceAppUpdate: Identifiable {
	/// The installed bundle identifier, which signing may have changed, or the
	/// library app's original identifier when it isn't known to be installed.
	let id: String
	/// The newest version installed or signed.
	let installedVersion: String
	let isInstalled: Bool
	let source: ASRepository
	let app: ASRepository.App
}

/// Finds updates for the apps installed on this device and the apps signed in
/// the library. With a pairing connection the device's own app list is used,
/// and it also corrects the install history; without one, the install history
/// stands in for it.
@MainActor
final class DeviceUpdatesManager: ObservableObject {
	static let shared = DeviceUpdatesManager()

	enum Method: String {
		case history
		case pairing
	}

	@Published private(set) var updates: [DeviceAppUpdate] = []
	@Published private(set) var method: Method = .history

	private struct _InstalledApp {
		let identifier: String
		let version: String
	}

	private var _installed: [_InstalledApp] = []
	private var _isListing = false
	private var _lastSources: [AltSource: ASRepository] = [:]
	private var _lastSignedApps: [Signed] = []

	private init() {}

	/// Re-reads the installed apps, then matches them against `sources`.
	func refresh(
		sources: [AltSource: ASRepository],
		signedApps: [Signed]
	) async {
		guard !_isListing else { return }
		_isListing = true
		defer { _isListing = false }

		// An empty list means the read failed; it must not wipe the history.
		if let paired = await _readFromPairing(), !paired.isEmpty {
			// Apps deleted since RyukSign installed them shouldn't keep showing updates.
			let present = Set(paired.map(\.identifier))
			InstallHistory.remove(Set(InstallHistory.entries.map(\.identifier)).subtracting(present))

			_installed = paired
			method = .pairing
		} else {
			_installed = InstallHistory.entries.map {
				_InstalledApp(identifier: $0.identifier, version: $0.version)
			}
			method = .history
		}

		match(sources: sources, signedApps: signedApps)
	}

	/// Matches the last installed-app list against `sources` without reading
	/// the installed apps again, e.g. once sources finish loading.
	func match(
		sources: [AltSource: ASRepository],
		signedApps: [Signed]
	) {
		_lastSources = sources
		_lastSignedApps = signedApps

		// Signing can change the bundle identifier; the history and the library remember the original.
		var originals: [String: String] = [:]
		for app in signedApps {
			if let identifier = app.identifier, let original = app.originalIdentifier, !original.isEmpty {
				originals[identifier] = original
			}
		}
		for entry in InstallHistory.entries {
			if let original = entry.originalIdentifier, !original.isEmpty {
				originals[entry.identifier] = original
			}
		}

		var byIdentifier: [String: (ASRepository, ASRepository.App)] = [:]
		for repository in sources.values {
			for app in repository.apps {
				guard let identifier = app.id, !identifier.isEmpty else { continue }
				if let existing = byIdentifier[identifier],
				   !AppUpdateChecker.shared.hasUpdate(
					installedVersion: existing.1.currentVersion,
					sourceVersion: app.currentVersion
				   ) {
					continue
				}
				byIdentifier[identifier] = (repository, app)
			}
		}

		// The newest version of each app, installed or signed, keyed by original identifier.
		// An update already signed but not yet installed shouldn't be offered again.
		struct Known {
			var version: String
			var installedIdentifier: String?
		}
		var known: [String: Known] = [:]
		func note(_ key: String, version: String, installedIdentifier: String?) {
			var entry = known[key] ?? Known(version: version, installedIdentifier: nil)
			if AppUpdateChecker.shared.hasUpdate(installedVersion: entry.version, sourceVersion: version) {
				entry.version = version
			}
			entry.installedIdentifier = entry.installedIdentifier ?? installedIdentifier
			known[key] = entry
		}

		for installed in _installed {
			note(originals[installed.identifier] ?? installed.identifier, version: installed.version, installedIdentifier: installed.identifier)
		}
		for app in signedApps {
			guard
				let key = [app.originalIdentifier, app.identifier].compactMap({ $0 }).first(where: { !$0.isEmpty }),
				let version = app.version
			else { continue }
			note(key, version: version, installedIdentifier: nil)
		}

		let skipped = SkippedUpdatesManager.shared
		updates = known.compactMap { key, entry in
			guard
				let (repository, app) = byIdentifier[key] ?? entry.installedIdentifier.flatMap({ byIdentifier[$0] }),
				!skipped.isIgnored(app.id),
				AppUpdateChecker.shared.hasUpdate(installedVersion: entry.version, sourceVersion: app.currentVersion)
			else {
				return nil
			}

			return DeviceAppUpdate(
				id: entry.installedIdentifier ?? key,
				installedVersion: entry.version,
				isInstalled: entry.installedIdentifier != nil,
				source: repository,
				app: app
			)
		}
		.sorted { $0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending }
	}

	/// For an app deleted without a pairing connection to notice. A signed copy
	/// in the library can still keep it listed.
	func markNotInstalled(_ update: DeviceAppUpdate) {
		InstallHistory.remove([update.id])
		_installed.removeAll { $0.identifier == update.id }
		match(sources: _lastSources, signedApps: _lastSignedApps)
	}

	// MARK: - Pairing

	private func _readFromPairing() async -> [_InstalledApp]? {
		let collector = _Collector()
		let proxy = InstallationAppProxy()
		proxy.delegate = collector
		do {
			try await proxy.listApps()
		} catch {
			return nil
		}

		// User apps not from the App Store, which carry the buyer's DSID.
		return collector.apps.compactMap { app in
			guard
				app.ApplicationType == "User",
				app.ApplicationDSID == nil,
				let identifier = app.CFBundleIdentifier,
				let version = app.CFBundleShortVersionString ?? app.CFBundleVersion
			else {
				return nil
			}
			return _InstalledApp(identifier: identifier, version: version)
		}
	}

	private final class _Collector: InstallationProxyAppsDelegate {
		var apps: [AppInfo] = []

		func updateApplications(with apps: [AppInfo]) {
			self.apps = apps
		}
	}
}
