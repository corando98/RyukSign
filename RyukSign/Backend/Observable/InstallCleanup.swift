//
//  InstallCleanup.swift
//  RyukSign
//
//  Created by Ryuk
//

import Foundation

@MainActor
enum InstallCleanup {
	/// What happens to a signed app in the library once it installs.
	enum AfterInstall: String, CaseIterable, LocalizedDescribable {
		case keepAll
		/// Keeps the copy just installed and drops older signed copies of the same app,
		/// so the library still has a version to check updates against.
		case keepLatest
		case delete

		var localizedDescription: String {
			switch self {
			case .keepAll: .localized("Keep All")
			case .keepLatest: .localized("Keep Latest Signed")
			case .delete: .localized("Delete")
			}
		}
	}

	static let afterInstallKey = "RyukSign.afterInstall"
	/// The on/off setting `afterInstallKey` replaced, read once to carry it over.
	static let deleteKey = "Feather.deleteAppAfterInstall"
	static let clearCacheKey = "Feather.clearCacheAfterInstall"
	private static let pendingKey = "Feather.installCleanupPending"

	/// Deleting now would pull the app out from under the card still showing it. On disk so a kill
	/// before `flush()` still cleans up.
	static func stage(_ app: AppInfoPresentable) {
		guard let uuid = app.uuid, !_pending.contains(uuid) else { return }
		_pending.append(uuid)
	}

	/// Only safe once the install UI is gone.
	static func flush() {
		let uuids = _pending
		guard !uuids.isEmpty else { return }
		_pending = []

		let defaults = UserDefaults.standard

		switch afterInstall {
		case .keepAll:
			break
		case .keepLatest:
			Storage.shared.deleteApps(_olderSignedCopies(than: uuids))
		case .delete:
			let apps = Storage.shared.getAllApps().filter { uuids.contains($0.uuid ?? "") }
			Storage.shared.deleteApps(apps)
		}

		if defaults.bool(forKey: clearCacheKey) {
			StorageManager.purgeCaches()
		}
	}

	static var afterInstall: AfterInstall {
		let defaults = UserDefaults.standard
		if let raw = defaults.string(forKey: afterInstallKey), let value = AfterInstall(rawValue: raw) {
			return value
		}
		return defaults.bool(forKey: deleteKey) ? .delete : .keepAll
	}

	/// Signed copies of the apps just installed that aren't newer than them. Matched on the
	/// original identifier, since signing may have changed the installed one.
	private static func _olderSignedCopies(than uuids: [String]) -> [AppInfoPresentable] {
		func key(_ app: AppInfoPresentable) -> String? {
			[app.originalIdentifier, app.identifier].compactMap { $0 }.first { !$0.isEmpty }
		}

		let signed = Storage.shared.getAllApps().filter(\.isSigned)
		var seen = Set<String>()
		var stale: [AppInfoPresentable] = []

		for installed in signed where uuids.contains(installed.uuid ?? "") {
			guard let identifier = key(installed) else { continue }

			for other in signed where key(other) == identifier {
				guard
					let uuid = other.uuid,
					!uuids.contains(uuid),
					!AppUpdateChecker.shared.hasUpdate(installedVersion: installed.version, sourceVersion: other.version),
					seen.insert(uuid).inserted
				else { continue }

				stale.append(other)
			}
		}

		return stale
	}

	private static var _pending: [String] {
		get { UserDefaults.standard.stringArray(forKey: pendingKey) ?? [] }
		set { UserDefaults.standard.set(newValue, forKey: pendingKey) }
	}
}
