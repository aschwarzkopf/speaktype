import Foundation
import Combine
import WhisperKit

class ModelDownloadService: ObservableObject {
    static let shared = ModelDownloadService()

    /// Upper bound on download attempts per variant (initial + retries).
    /// Retries only apply to recoverable errors like "Multiple models found"
    /// cache collisions where a cleanup pass between attempts can help.
    static let maxDownloadAttempts = 2

    @Published var downloadProgress: [String: Double] = [:] // Map Model Variant (String) to progress
    @Published var downloadError: [String: String] = [:] // Debugging: track errors
    @Published var isDownloading: [String: Bool] = [:]

    private var activeTasks: [String: Task<Void, Never>] = [:] // Track running download tasks
    
    private init() {
        // Force a custom cache directory to avoid "Multiple models found" conflicts
        setupCustomCache()
        
        // Check for already-downloaded models on launch
        Task { @MainActor in
            await refreshDownloadedModels()
            // Don't auto-select - let user explicitly pick a model which will load it
        }
    }
    
    private func setupCustomCache() {
        // Use the standard Documents/huggingface location that WhisperKit expects
        guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        
        let huggingfaceCache = documentsDir.appendingPathComponent("huggingface")
        
        do {
            try FileManager.default.createDirectory(at: huggingfaceCache, withIntermediateDirectories: true)
            print("✅ Using standard HuggingFace cache at: \(huggingfaceCache.path)")
        } catch {
            print("⚠️ Failed to create huggingface directory: \(error)")
        }
        
        // Don't override HF_HUB_CACHE - let WhisperKit use its default behavior
        // This ensures compatibility with the standard HuggingFace cache structure
    }
    
    // Check which models are already downloaded and update progress dictionary
    func refreshDownloadedModels() async {
        print("🔍 Checking for already-downloaded models...")
        
        var foundModels = Set<String>()
        
        // NOTE: WhisperKit.fetchAvailableModels() returns ALL remote models, not local ones
        // We ONLY rely on disk-based verification to check what's actually downloaded
        
        // Verify models actually exist on disk with proper size validation
        let fileManager = FileManager.default
        if let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let whisperKitPath = documentsDir.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
            
            if fileManager.fileExists(atPath: whisperKitPath.path) {
                if let contents = try? fileManager.contentsOfDirectory(at: whisperKitPath, includingPropertiesForKeys: [.isDirectoryKey]) {
                    print("📁 Found \(contents.count) items in WhisperKit cache at \(whisperKitPath.path)")
                    
                    for item in contents {
                        let modelName = item.lastPathComponent
                        
                        // Skip non-model directories
                        if modelName == "config.json" || modelName == ".DS_Store" {
                            continue
                        }
                        
                        // Verify this directory has actual model files (not just empty directory)
                        if let subContents = try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: [.fileSizeKey]),
                           !subContents.isEmpty {
                            
                            // Check if it has the essential files for a model (must have config.json)
                            let hasConfigJson = subContents.contains(where: { $0.lastPathComponent == "config.json" })
                            let hasModelFiles = subContents.contains(where: { $0.lastPathComponent.hasSuffix(".mlmodelc") })
                            
                            if hasConfigJson && hasModelFiles {
                                // Calculate total directory size
                                let directorySize = Self.calculateDirectorySize(at: item)
                                let expectedSize = AIModel.expectedSize(for: modelName)
                                
                                // Model is complete if it's at least 80% of expected size
                                let minAcceptableSize = Int64(Double(expectedSize) * 0.8)
                                
                                if directorySize >= minAcceptableSize {
                                    print("✅ Model \(modelName) verified: \(Self.formatBytes(directorySize)) (expected ~\(Self.formatBytes(expectedSize)))")
                                    foundModels.insert(modelName)
                                } else {
                                    print("⚠️ Model \(modelName) is INCOMPLETE: \(Self.formatBytes(directorySize)) < \(Self.formatBytes(minAcceptableSize)) minimum")
                                }
                            } else {
                                print("⚠️ Model \(modelName) is incomplete (missing config.json or .mlmodelc files)")
                            }
                        }
                    }
                }
            } else {
                print("ℹ️ WhisperKit cache directory doesn't exist yet: \(whisperKitPath.path)")
                print("   Models will be downloaded on first use.")
            }
        }
        
        await MainActor.run {
            // Clear all previous progress
            self.downloadProgress.removeAll()
            
            // Only mark models that actually exist
            for variant in foundModels {
                self.downloadProgress[variant] = 1.0
                print("✅ Marked as downloaded: \(variant)")
            }
            
            if foundModels.isEmpty {
                print("❌ No models found - all will show as 'Download' buttons")
            } else {
                print("✅ Found \(foundModels.count) usable model(s)")
            }
        }
    }
    
    // Asynchronous download using WhisperKit
    func downloadModel(variant: String) {
        guard isDownloading[variant] != true else { return }
        
        isDownloading[variant] = true
        downloadProgress[variant] = 0.0
        downloadError[variant] = nil
        print("Starting WhisperKit download for: \(variant)")
        
        let task = Task {
            // Exactly-once cleanup of the task handle regardless of which
            // code path (success, retry-success, retry-fail, cancellation)
            // we exit through. Replaces the scattered manual nils that
            // previously made it easy to leak entries on error.
            defer {
                DispatchQueue.main.async {
                    self.activeTasks[variant] = nil
                }
            }

            do {
                // Determine model variant enum/string
                // Note: WhisperKit.download(variant:from:) is the likely API.
                // We use the "variant" string to fetch.
                // Assuming `WhisperKit.download(variant: variant)` acts as the fetcher.
                // Progress callback mock (since we might not have exact API signature yet):
                
                // Actual API (hypothetical based on search):
                // let model = try await WhisperKit(model: variant) 
                // OR
                // try await WhisperKit.download(variant: variant) { progress in ... }
                
                // likely: download(variant:progressCallback:) - 'from' usually has a default
                let _ = try await WhisperKit.download(variant: variant, progressCallback: { progress in
                    DispatchQueue.main.async {
                        self.downloadProgress[variant] = progress.fractionCompleted
                    }
                })
                
                // Check if task was cancelled before declaring success
                if Task.isCancelled { return }
                
                print("Model downloaded successfully")
                
                DispatchQueue.main.async {
                    self.isDownloading[variant] = false
                    self.downloadProgress[variant] = 1.0
                    self.activeTasks[variant] = nil // Cleanup task
                }
            } catch {
                if Task.isCancelled {
                   print("Download cancelled for \(variant)")
                   return
                }
                
                print("WhisperKit download error: \(error)")
                
                // Auto-Repair: If duplicate models found, delete and retry ONCE
                if error.localizedDescription.contains("Multiple models found") {
                     print("⚠️ Multiple models detected. Cleaning cache and retrying...")
                     
                     await MainActor.run {
                         self.downloadError[variant] = "Cleaning duplicates..."
                     }
                     
                     let log = await self.deleteModel(variant: variant)
                     print("🧹 Cleanup result: \(log)")
                     
                     // Give filesystem time to settle
                     try? await Task.sleep(nanoseconds: 2_000_000_000)
                     if Task.isCancelled { return }
                     
                     await MainActor.run {
                         self.downloadError[variant] = "Retrying download..."
                     }
                     
                     // Retry download once
                     do {
                         let _ = try await WhisperKit.download(variant: variant, progressCallback: { progress in
                             DispatchQueue.main.async {
                                 self.downloadProgress[variant] = progress.fractionCompleted
                             }
                         })
                         
                         if Task.isCancelled { return }
                         
                         print("✅ Model downloaded successfully after cleanup")
                         
                         DispatchQueue.main.async {
                             self.isDownloading[variant] = false
                             self.downloadProgress[variant] = 1.0
                             self.downloadError[variant] = nil
                             self.activeTasks[variant] = nil
                         }
                     } catch {
                         if Task.isCancelled { return }
                         print("❌ Retry failed: \(error)")
                         DispatchQueue.main.async {
                             self.isDownloading[variant] = false
                             self.downloadProgress[variant] = 0.0
                             self.downloadError[variant] = "Error: \(error.localizedDescription)\n\nTry clicking the trash icon to manually clean cache."
                             self.activeTasks[variant] = nil
                         }
                     }
                     return
                }

                DispatchQueue.main.async {
                    self.isDownloading[variant] = false
                    self.downloadProgress[variant] = 0.0
                    self.downloadError[variant] = error.localizedDescription + "\n\n(Try Trash icon to clean cache)"
                    self.activeTasks[variant] = nil
                }
            }
        }
        
        activeTasks[variant] = task
    }
    
    /// Pure, testable predicate for whether a file/dir at `fileName` should
    /// be deleted as part of a variant cleanup. Uses **exact** last-path-
    /// component equality (optionally with the `/`→`--` HuggingFace alias)
    /// so unrelated files with overlapping substrings (e.g. "my-whisper-
    /// notes.md") are not accidentally swept up.
    static func shouldDelete(fileName: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            if fileName == pattern { return true }
            let hfAlias = pattern.replacingOccurrences(of: "/", with: "--")
            if fileName == hfAlias { return true }
        }
        return false
    }

    /// Deletes cached files for a given model variant. Only touches paths
    /// this app manages — Application Support, Caches, and the standard
    /// Documents/huggingface tree WhisperKit uses. /tmp and ~/.cache are
    /// no longer scanned: a sandboxed app can't meaningfully clean them,
    /// and they belong to other processes.
    func deleteModel(variant: String) async -> String {
        let fileManager = FileManager.default
        let searchDirs: [FileManager.SearchPathDirectory] = [
            .documentDirectory, .applicationSupportDirectory, .cachesDirectory,
        ]

        // Parse variant: "openai/whisper-medium" or "openai_whisper-medium"
        let variantParts = variant.split(separator: "/")
        let modelName = String(variantParts.last ?? Substring(variant))
        let underscoreVariant = variant.replacingOccurrences(of: "/", with: "_")
        let patterns = [modelName, underscoreVariant]

        var deletedCount = 0
        var checkedPaths: [String] = []

        print("🗑️ Searching for model caches matching exactly: \(patterns)")

        for searchDir in searchDirs {
            guard let baseDir = fileManager.urls(for: searchDir, in: .userDomainMask).first
            else { continue }

            let candidates = [
                baseDir.appendingPathComponent("huggingface/models"),
                baseDir.appendingPathComponent("huggingface/hub"),
                baseDir.appendingPathComponent(
                    "huggingface/models/argmaxinc/whisperkit-coreml"),
                baseDir,
            ]
            for candidate in candidates {
                checkedPaths.append(candidate.path)
                deletedCount += cleanupDirectory(candidate, patterns: patterns)
            }
        }

        print(
            "🗑️ Cleanup complete. Deleted \(deletedCount) items from \(checkedPaths.count) locations"
        )

        await MainActor.run {
            self.downloadProgress[variant] = 0.0
            self.isDownloading[variant] = false
        }

        if deletedCount > 0 {
            return "Deleted \(deletedCount) items"
        }
        return "No match for '\(modelName)' in \(checkedPaths.count) app-scoped locations"
    }

    private func cleanupDirectory(_ dir: URL, patterns: [String]) -> Int {
        let fileManager = FileManager.default
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            )
        else { return 0 }

        var count = 0
        for url in contents {
            guard Self.shouldDelete(fileName: url.lastPathComponent, patterns: patterns) else {
                continue
            }
            do {
                try fileManager.removeItem(at: url)
                print("✅ Deleted cache: \(url.lastPathComponent)")
                count += 1
            } catch {
                print("❌ Failed to delete \(url.lastPathComponent): \(error)")
            }
        }
        return count
    }
    func cancelDownload(for variant: String) {
        if let task = activeTasks[variant] {
            task.cancel()
            activeTasks[variant] = nil
            print("Cancelled download task for \(variant)")
        }
        
        isDownloading[variant] = false
        downloadProgress[variant] = 0.0
        downloadError[variant] = nil
        
        // Delete any partial download
        Task {
            let result = await deleteModel(variant: variant)
            print("🗑️ Cleaned up partial download: \(result)")
        }
    }
    
    // MARK: - Helper Functions
    
    /// Calculate total size of a directory recursively
    static func calculateDirectorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if resourceValues.isRegularFile == true {
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                }
            } catch {
                continue
            }
        }
        
        return totalSize
    }
    
    /// Format bytes into human-readable string
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
