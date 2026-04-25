import SwiftUI

/// Settings tab for transcript cleanup. Three modes:
///
///   - Off:    raw Whisper output, no post-processing
///   - Local:  on-device cleanup via Apple Intelligence (macOS 26+)
///   - Cloud:  Anthropic Claude API (Phase 3, currently disabled)
///
/// Routing logic lives in PolisherFactory. This view just drives the
/// `cleanupMode` AppStorage key; restart-on-change isn't required —
/// MiniRecorderView re-reads the value on every transcription.
struct CleanupSettingsTab: View {
    @AppStorage("cleanupMode") private var cleanupModeRaw: String = CleanupMode.off.rawValue

    private var cleanupMode: CleanupMode {
        CleanupMode(rawValue: cleanupModeRaw) ?? .off
    }

    private var isLocalAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return FoundationModelsPolisher.isAvailable
        }
        #endif
        return false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                SettingsSection {
                    SettingsSectionHeader(
                        icon: "wand.and.stars",
                        title: "Transcript Cleanup",
                        subtitle: "Remove filler words, fix punctuation, polish output"
                    )

                    VStack(spacing: 12) {
                        CleanupModeRow(
                            title: "Off",
                            subtitle: "Use raw transcripts as-is",
                            badge: nil,
                            isSelected: cleanupMode == .off,
                            isEnabled: true,
                            statusNote: nil
                        ) {
                            cleanupModeRaw = CleanupMode.off.rawValue
                        }

                        CleanupModeRow(
                            title: "Local",
                            subtitle: "On-device, private, no internet",
                            badge: "Apple Intelligence",
                            isSelected: cleanupMode == .local && isLocalAvailable,
                            isEnabled: isLocalAvailable,
                            statusNote: isLocalAvailable
                                ? nil
                                : "Requires macOS 26 with Apple Intelligence enabled"
                        ) {
                            guard isLocalAvailable else { return }
                            cleanupModeRaw = CleanupMode.local.rawValue
                        }

                        CleanupModeRow(
                            title: "Cloud",
                            subtitle: "Anthropic Claude — highest quality cleanup",
                            badge: "Coming soon",
                            isSelected: false,
                            isEnabled: false,
                            statusNote: "Bring-your-own API key support arrives in the next update"
                        ) {
                            // Phase 3 will wire this up.
                        }
                    }
                }

                SettingsSection {
                    SettingsSectionHeader(
                        icon: "info.circle",
                        title: "How it works",
                        subtitle: "Cleanup runs after Whisper, before paste"
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cleanup runs after Whisper transcribes your audio, before the text is pasted. If cleanup fails for any reason, the raw transcript is used so dictation never gets blocked.")
                            .font(Typography.bodySmall)
                            .foregroundStyle(Color.textSecondary)

                        Text("Local cleanup uses Apple's on-device language model — your transcripts never leave your Mac. The first cleanup after launch may take an extra second while the model loads.")
                            .font(Typography.bodySmall)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color.clear)
    }
}

/// Single row in the cleanup-mode picker. Mirrors the look of
/// DeviceRow in AudioInputView for visual consistency: rounded card,
/// radio indicator, optional badge in the trailing area, optional
/// status note as a secondary line.
private struct CleanupModeRow: View {
    let title: String
    let subtitle: String
    let badge: String?
    let isSelected: Bool
    let isEnabled: Bool
    let statusNote: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                // Radio indicator
                ZStack {
                    Circle()
                        .strokeBorder(
                            radioStrokeColor,
                            lineWidth: 1.5
                        )
                        .frame(width: 18, height: 18)
                    if isSelected {
                        Circle()
                            .fill(Color.accentPrimary)
                            .frame(width: 10, height: 10)
                    }
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(Typography.bodyMedium)
                            .foregroundStyle(titleColor)
                        if let badge {
                            Text(badge)
                                .font(Typography.labelSmall)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(badgeBackgroundColor)
                                .foregroundStyle(badgeForegroundColor)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    Text(subtitle)
                        .font(Typography.bodySmall)
                        .foregroundStyle(Color.textSecondary)
                    if let statusNote {
                        Text(statusNote)
                            .font(Typography.labelSmall)
                            .foregroundStyle(Color.textMuted)
                            .padding(.top, 2)
                    }
                }

                Spacer()
            }
            .padding(16)
            .background(isSelected ? Color.bgSelected : Color.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.bgSelected : Color.border, lineWidth: 1)
            )
            .opacity(isEnabled ? 1.0 : 0.6)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var radioStrokeColor: Color {
        if !isEnabled { return Color.textMuted }
        return isSelected ? Color.accentPrimary : Color.textMuted
    }

    private var titleColor: Color {
        isEnabled ? Color.textPrimary : Color.textMuted
    }

    private var badgeBackgroundColor: Color {
        isEnabled ? Color.accentPrimary.opacity(0.15) : Color.textMuted.opacity(0.15)
    }

    private var badgeForegroundColor: Color {
        isEnabled ? Color.accentPrimary : Color.textMuted
    }
}
