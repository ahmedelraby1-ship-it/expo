//  Copyright © 2019 650 Industries. All rights reserved.

// swiftlint:disable closure_body_length
// swiftlint:disable force_unwrapping

import Foundation

public typealias AppLauncherUpdateCompletionBlock = (_ error: UpdatesError?, _ update: Update?) -> Void

/**
 * Implementation of AppLauncher that uses the SQLite database and expo-updates file store
 * as the source of updates.
 *
 * Uses the SelectionPolicy to choose an update from SQLite to launch, then ensures that
 * the update is safe and ready to launch (i.e. all the assets that SQLite expects to be stored on
 * disk are actually there).
 *
 * This class also includes failsafe code to attempt to re-download any assets unexpectedly missing
 * from disk (since it isn't necessarily safe to just revert to an older update in this case).
 * Distinct from the AppLoader classes, though, this class does *not* make any major
 * modifications to the database; its role is mostly to read the database and ensure integrity with
 * the file system.
 *
 * It's important that the update to launch is selected *before* any other checks, e.g. the above
 * check for assets on disk. This is to preserve the invariant that no older update should ever be
 * launched after a newer one has been launched.
 */
@objc(EXUpdatesAppLauncherWithDatabase)
@objcMembers
public class AppLauncherWithDatabase: NSObject, AppLauncher {
  public var launchedUpdate: Update?
  public var launchAssetUrl: URL?
  public var assetFilesMap: [String: String]?

  private let launcherQueue: DispatchQueue
  private var completedAssets: Int
  private let config: UpdatesConfig
  private let database: UpdatesDatabase
  private let directory: URL
  private let logger: UpdatesLogger
  public private(set) var completionQueue: DispatchQueue
  public private(set) var completion: AppLauncherCompletionBlock?

  private var launchAssetError: UpdatesError?

  public required init(config: UpdatesConfig, database: UpdatesDatabase, directory: URL, completionQueue: DispatchQueue, logger: UpdatesLogger) {
    self.launcherQueue = DispatchQueue(label: "expo.launcher.LauncherQueue")
    self.completedAssets = 0
    self.config = config
    self.database = database
    self.directory = directory
    self.completionQueue = completionQueue
    self.logger = logger
  }

  public func isUsingEmbeddedAssets() -> Bool {
    return assetFilesMap == nil
  }

  public static func launchableUpdate(
    withConfig config: UpdatesConfig,
    database: UpdatesDatabase,
    selectionPolicy: SelectionPolicy,
    completionQueue: DispatchQueue,
    completion: @escaping AppLauncherUpdateCompletionBlock
  ) {
    NSLog("[ExpoUpdates] launchableUpdate: dispatching to databaseQueue...")
    database.databaseQueue.async {
      NSLog("[ExpoUpdates] launchableUpdate: on databaseQueue, querying launchable updates...")
      var launchableUpdates: [Update]?
      var launchableUpdatesError: UpdatesError?
      do {
        launchableUpdates = try database.launchableUpdates(withConfig: config)
        NSLog("[ExpoUpdates] launchableUpdate: found %d launchable updates", launchableUpdates?.count ?? 0)
      } catch {
        NSLog("[ExpoUpdates] launchableUpdate: error querying: %@", error.localizedDescription)
        launchableUpdatesError = UpdatesError.appLauncherWithDatabaseUnknownError(cause: error)
      }

      var manifestFilters: [String: Any]?
      var manifestFiltersError: UpdatesError?
      do {
        manifestFilters = try database.manifestFilters(withScopeKey: config.scopeKey)
      } catch {
        manifestFiltersError = UpdatesError.appLauncherWithDatabaseUnknownError(cause: error)
      }

      NSLog("[ExpoUpdates] launchableUpdate: dispatching back to completionQueue...")
      completionQueue.async {
        NSLog("[ExpoUpdates] launchableUpdate: on completionQueue, filtering updates...")
        guard let launchableUpdates = launchableUpdates else {
          NSLog("[ExpoUpdates] launchableUpdate: no launchable updates, returning error")
          completion(launchableUpdatesError!, nil)
          return
        }

        if let manifestFiltersError = manifestFiltersError {
          completion(manifestFiltersError, nil)
          return
        }

        let embeddedManifest = EmbeddedAppLoader.originalEmbeddedManifest(withConfig: config, database: database)
        NSLog("[ExpoUpdates] launchableUpdate: embeddedManifest id=%@, hasEmbeddedUpdate=%d",
              embeddedManifest?.updateId.uuidString ?? "nil", config.hasEmbeddedUpdate ? 1 : 0)
        var filteredLaunchableUpdates: [Update] = []
        for update in launchableUpdates {
          NSLog("[ExpoUpdates] launchableUpdate: checking update id=%@, status=%d",
                update.updateId.uuidString, update.status.rawValue)
          // We can only run an update marked as embedded if it's actually the update embedded in the
          // current binary. We might have an older update from a previous binary still listed in the
          // database with Embedded status so we need to filter that out here.
          if update.status == UpdateStatus.StatusEmbedded && update.updateId != embeddedManifest?.updateId {
            NSLog("[ExpoUpdates] launchableUpdate: filtering out stale embedded update")
            continue
          }

          // If embedded update is disabled, we should exclude embedded update from launchable updates
          if !config.hasEmbeddedUpdate && embeddedManifest?.updateId == update.updateId {
            NSLog("[ExpoUpdates] launchableUpdate: filtering out disabled embedded update")
            continue
          }

          filteredLaunchableUpdates.append(update)
        }

        let selected = selectionPolicy.launchableUpdate(fromUpdates: filteredLaunchableUpdates, filters: manifestFilters)
        NSLog("[ExpoUpdates] launchableUpdate: selected update=%@, filtered count=%d",
              selected?.updateId.uuidString ?? "nil", filteredLaunchableUpdates.count)
        completion(nil, selected)
      }
    }
  }

  public func launchableUpdate(
    selectionPolicy: SelectionPolicy,
    completion: @escaping AppLauncherUpdateCompletionBlock
  ) {
    AppLauncherWithDatabase.launchableUpdate(
      withConfig: config,
      database: database,
      selectionPolicy: selectionPolicy,
      completionQueue: completionQueue,
      completion: completion
    )
  }

  public func launchUpdate(
    withSelectionPolicy selectionPolicy: SelectionPolicy,
    completion: @escaping AppLauncherCompletionBlock
  ) {
    precondition(self.completion == nil, "AppLauncher:launchUpdateWithSelectionPolicy:completion should not be called twice on the same instance")
    self.completion = completion

    NSLog("[ExpoUpdates] launchUpdate: launchedUpdate=%@", launchedUpdate?.updateId.uuidString ?? "nil")
    if launchedUpdate == nil {
      launchableUpdate(selectionPolicy: selectionPolicy) { error, launchableUpdate in
        NSLog("[ExpoUpdates] launchUpdate callback: error=%@, update=%@",
              error?.localizedDescription ?? "nil", launchableUpdate?.updateId.uuidString ?? "nil")
        if error != nil || launchableUpdate == nil {
          if let completionInner = self.completion {
            self.completionQueue.async {
              let cause = UpdatesError.appLauncherNoLaunchableUpdates(cause: error)
              completionInner(cause, false)
            }
          }
        } else {
          self.launchedUpdate = launchableUpdate
          self.finishLaunch()
        }
      }
    } else {
      finishLaunch()
    }
  }

  private func finishLaunch() {
    markUpdateAccessed()
    ensureAllAssetsExist()
  }

  private func markUpdateAccessed() {
    guard launchedUpdate != nil else {
      preconditionFailure("launchedUpdate should be nonnull before calling markUpdateAccessed")
    }
    database.databaseQueue.async {
      do {
        try self.database.markUpdateAccessed(self.launchedUpdate!)
      } catch {
        self.logger.warn(message: "Failed to mark update as recently accessed: \(error.localizedDescription)")
      }
    }
  }

  public func ensureAllAssetsExist() {
    guard let launchedUpdate = launchedUpdate else {
      preconditionFailure("launchedUpdate should be nonnull before calling markUpdateAccessed")
    }

    if launchedUpdate.status == UpdateStatus.StatusEmbedded {
      precondition(assetFilesMap == nil, "assetFilesMap should be null for embedded updates")
      let mainBundleUrl = Bundle.main.url(
        forResource: EmbeddedAppLoader.EXUpdatesBareEmbeddedBundleFilename,
        withExtension: EmbeddedAppLoader.EXUpdatesBareEmbeddedBundleFileType
      )
      let frameworkBundleUrl = Bundle(for: AppLauncherWithDatabase.self).url(
        forResource: EmbeddedAppLoader.EXUpdatesBareEmbeddedBundleFilename,
        withExtension: EmbeddedAppLoader.EXUpdatesBareEmbeddedBundleFileType
      )
      NSLog("[ExpoUpdates] AppLauncherWithDatabase embedded - mainBundle url: %@, frameworkBundle url: %@",
            mainBundleUrl?.absoluteString ?? "nil", frameworkBundleUrl?.absoluteString ?? "nil")
      launchAssetUrl = mainBundleUrl ?? frameworkBundleUrl

      completionQueue.async {
        self.completion!(self.launchAssetError, self.launchAssetUrl != nil)
        self.completion = nil
      }
      return
    }

    if launchedUpdate.status == UpdateStatus.StatusDevelopment {
      completionQueue.async {
        self.completion!(nil, true)
        self.completion = nil
      }
      return
    }

    // Initialize asset map with the embedded assets that may not be part of this update
    self.assetFilesMap = UpdatesUtils.embeddedAssetsMap(withConfig: config, database: database, logger: logger)

    let assets = launchedUpdate.assets()!
    let totalAssetCount = assets.count
    NSLog("[ExpoUpdates] ensureAllAssetsExist: status=%d, totalAssets=%d, directory=%@",
          launchedUpdate.status.rawValue, totalAssetCount, directory.path)

    if totalAssetCount == 0 {
      completionQueue.async {
        self.completion!(nil, true)
        self.completion = nil
      }
      return
    }

    for asset in assets {
      let assetLocalUrl = directory.appendingPathComponent(asset.filename)
      NSLog("[ExpoUpdates] ensureAssetExists: key=%@, filename=%@, isLaunchAsset=%d",
            asset.key ?? "nil", asset.filename, asset.isLaunchAsset ? 1 : 0)
      ensureAssetExists(asset: asset, withLocalUrl: assetLocalUrl) { exists in
        dispatchPrecondition(condition: .onQueue(self.launcherQueue))
        self.completedAssets += 1
        NSLog("[ExpoUpdates] asset checked: key=%@, exists=%d, completed=%d/%d",
              asset.key ?? "nil", exists ? 1 : 0, self.completedAssets, totalAssetCount)

        if exists {
          if asset.isLaunchAsset {
            self.launchAssetUrl = assetLocalUrl
          } else {
            if let assetKey = asset.key {
              self.assetFilesMap![assetKey] = assetLocalUrl.absoluteString
            }
          }
        }

        if self.completedAssets == totalAssetCount {
          NSLog("[ExpoUpdates] all assets checked, launchAssetUrl=%@",
                self.launchAssetUrl?.absoluteString ?? "nil")
          self.completionQueue.async {
            self.completion!(self.launchAssetError, self.launchAssetUrl != nil)
            self.completion = nil
          }
        }
      }
    }
  }

  private func ensureAssetExists(asset: UpdateAsset, withLocalUrl assetLocalUrl: URL, completion: @escaping (Bool) -> Void) {
    checkExistence(ofAsset: asset, withLocalUrl: assetLocalUrl) { exists in
      if exists {
        completion(true)
        return
      }

      self.maybeCopyAssetFromMainBundle(asset, withLocalUrl: assetLocalUrl) { success, error in
        if success {
          completion(true)
          return
        }

        if let error = error {
          self.logger.warn(message: "AppLauncherWithDatabase: Error copying embedded asset \(asset.key ?? ""): \(error.localizedDescription)")
        }

        self.downloadAsset(asset, withLocalUrl: assetLocalUrl) { downloadAssetError, downloadAssetAsset, _ in
          if let downloadAssetError = downloadAssetError {
            if downloadAssetAsset.isLaunchAsset {
              // save the error -- since this is the launch asset, the launcher will fail
              // so we want to propagate this error
              self.launchAssetError = downloadAssetError
            }
            self.logger.warn(message: "AppLauncherWithDatabase: Failed to load missing asset \(downloadAssetAsset.key ?? ""): \(downloadAssetError.localizedDescription)")
            completion(false)
          } else {
            // attempt to update the database record to match the newly downloaded asset
            // but don't block launching on this
            self.database.databaseQueue.async {
              do {
                try self.database.updateAsset(downloadAssetAsset)
              } catch {
                self.logger.warn(message: "AppLauncherWithDatabase: Could not write data for downloaded asset to database: \(error.localizedDescription)")
              }
            }
            completion(true)
          }
        }
      }
    }
  }

  private func checkExistence(ofAsset asset: UpdateAsset, withLocalUrl assetLocalUrl: URL, completion: @escaping (Bool) -> Void) {
    FileDownloader.assetFilesQueue.async {
      let exists = FileManager.default.fileExists(atPath: assetLocalUrl.path)
      self.launcherQueue.async {
        completion(exists)
      }
    }
  }

  private func maybeCopyAssetFromMainBundle(
    _ asset: UpdateAsset,
    withLocalUrl assetLocalUrl: URL,
    completion: @escaping (Bool, UpdatesError?) -> Void
  ) {
    guard let embeddedManifest = EmbeddedAppLoader.embeddedManifest(withConfig: config, database: database) else {
      completion(false, nil)
      return
    }

    let matchingAsset = embeddedManifest.assets()!.first { embeddedAsset in
      return embeddedAsset.key != nil && embeddedAsset.key == asset.key
    }

    if let matchingAsset = matchingAsset, matchingAsset.mainBundleFilename != nil {
      FileDownloader.assetFilesQueue.async {
        guard let bundlePath = UpdatesUtils.path(forBundledAsset: matchingAsset) else {
          self.launcherQueue.async {
            completion(
              false,
              UpdatesError.appLauncherWithDatabaseAssetBundlePathNil
            )
          }
          return
        }

        do {
          try FileManager.default.copyItem(atPath: bundlePath, toPath: assetLocalUrl.path)
          self.launcherQueue.async {
            completion(true, nil)
          }
        } catch {
          self.launcherQueue.async {
            completion(
              false,
              UpdatesError.appLauncherWithDatabaseAssetCopyFailed
            )
          }
        }
      }
      return
    }
    self.launcherQueue.async {
      completion(false, nil)
    }
  }

  private func downloadAsset(_ asset: UpdateAsset, withLocalUrl assetLocalUrl: URL, completion: @escaping (UpdatesError?, UpdateAsset, URL) -> Void) {
    guard let assetUrl = asset.url else {
      completion(
        UpdatesError.appLauncherWithDatabaseAssetMissingUrl,
        asset,
        assetLocalUrl
      )
      return
    }

    FileDownloader.assetFilesQueue.async {
      self.downloader.downloadAsset(
        asset: asset,
        fromURL: assetUrl,
        verifyingHash: asset.expectedHash,
        toPath: assetLocalUrl.path,
        extraHeaders: asset.extraRequestHeaders ?? [:],
        allowPatch: false,
        launchedUpdate: self.launchedUpdate
      ) { _, response, base64URLEncodedSHA256Hash in
        self.launcherQueue.async {
          if let response = response as? HTTPURLResponse {
            asset.headers = response.allHeaderFields as? [String: Any]
          }
          asset.contentHash = base64URLEncodedSHA256Hash
          asset.downloadTime = Date()
          completion(nil, asset, assetLocalUrl)
        }
      } errorBlock: { error in
        self.launcherQueue.async {
          completion(error, asset, assetLocalUrl)
        }
      }
    }
  }

  private lazy var downloader: FileDownloader = {
    FileDownloader(
      config: config,
      logger: self.logger,
      updatesDirectory: self.directory,
      database: self.database
    )
  }()
}
// swiftlint:enable closure_body_length
// swiftlint:enable force_unwrapping
