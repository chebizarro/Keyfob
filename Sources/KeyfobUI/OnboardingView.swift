//
//  OnboardingView.swift
//
//
//  Created for Keyfob – kf-9h2
//
//  First-run onboarding UI with feature cards, create key, and import key flows.
//  Inspired by Yeti's OnboardingView. Works on iOS 15+ and macOS 12+.
//

import SwiftUI
import KeyfobCore

// MARK: - OnboardingView

/// First-run onboarding screen shown when no identity exists.
///
/// Presents feature cards explaining what Keyfob does, then offers two paths:
/// 1. **Create New Key** — generates a keypair and offers backup
/// 2. **Import Existing Key** — accepts nsec, hex, or ncryptsec
///
/// ## Usage
///
/// ```swift
/// OnboardingView(service: onboardingService) { result in
///     // Onboarding complete — transition to main app
///     print("Created identity: \(result.npubTruncated)")
/// }
/// ```
public struct OnboardingView: View {

    private let service: OnboardingService
    private let onComplete: (OnboardingResult) -> Void

    @State private var selectedTab = 0
    @State private var showCreateFlow = false
    @State private var showImportFlow = false
    @State private var errorMessage: String?
    @State private var showError = false

    /// Create the onboarding view.
    ///
    /// - Parameters:
    ///   - service: The ``OnboardingService`` to handle key creation/import.
    ///   - onComplete: Called with the result when onboarding finishes successfully.
    public init(service: OnboardingService, onComplete: @escaping (OnboardingResult) -> Void) {
        self.service = service
        self.onComplete = onComplete
    }

    public var body: some View {
        VStack(spacing: 24) {
            // Logo and Title
            VStack(spacing: 12) {
                Image(systemName: "key.shield.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)

                Text(L("onboarding.title"))
                    .font(.largeTitle)
                    .bold()

                Text(L("onboarding.subtitle"))
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)

            // Feature Cards
            TabView(selection: $selectedTab) {
                FeatureCardView(
                    icon: "lock.shield.fill",
                    title: L("onboarding.feature1_title"),
                    description: L("onboarding.feature1_desc")
                ).tag(0)

                FeatureCardView(
                    icon: "signature",
                    title: L("onboarding.feature2_title"),
                    description: L("onboarding.feature2_desc")
                ).tag(1)

                FeatureCardView(
                    icon: "person.2.fill",
                    title: L("onboarding.feature3_title"),
                    description: L("onboarding.feature3_desc")
                ).tag(2)
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .always))
            #endif
            .frame(height: 180)

            #if os(macOS)
            // Manual page control on macOS (no page tab view style)
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { page in
                    Circle()
                        .fill(page == selectedTab ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            #endif

            Spacer()

            // Action Buttons
            VStack(spacing: 14) {
                Button(action: { showCreateFlow = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text(L("onboarding.create_btn"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: { showImportFlow = true }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down.fill")
                        Text(L("onboarding.import_btn"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .sheet(isPresented: $showCreateFlow) {
            CreateKeySheet(service: service) { result in
                showCreateFlow = false
                onComplete(result)
            }
        }
        .sheet(isPresented: $showImportFlow) {
            ImportKeySheet(service: service) { result in
                showImportFlow = false
                onComplete(result)
            }
        }
        .alert(L("onboarding.error_title"), isPresented: $showError) {
            Button(L("onboarding.ok")) { }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

// MARK: - Feature Card

struct FeatureCardView: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(.accentColor)

            Text(title)
                .font(.title3)
                .bold()
                .multilineTextAlignment(.center)

            Text(description)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Create Key Sheet

struct CreateKeySheet: View {
    let service: OnboardingService
    let onComplete: (OnboardingResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var result: OnboardingResult?
    @State private var isGenerating = false
    @State private var showBackup = false
    @State private var errorMessage: String?
    @State private var label: String = ""

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.accentColor)

                Text(L("create.title"))
                    .font(.title2)
                    .bold()

                Text(L("create.subtitle"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)

            // Label input
            VStack(alignment: .leading, spacing: 6) {
                Text(L("create.label_header"))
                    .font(.headline)
                TextField(L("create.label_placeholder"), text: $label)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    #endif
            }
            .padding(.horizontal, 24)

            // Info rows
            VStack(alignment: .leading, spacing: 14) {
                InfoRowView(icon: "lock.fill", text: L("create.info_secure"))
                InfoRowView(icon: "iphone", text: L("create.info_local"))
                InfoRowView(icon: "arrow.counterclockwise", text: L("create.info_backup"))
            }
            .padding(.horizontal, 24)

            Spacer()

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 24)
            }

            // Actions
            VStack(spacing: 12) {
                Button(action: generateKey) {
                    if isGenerating {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Text(L("create.generate_btn"))
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isGenerating)

                Button(L("create.cancel")) { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .sheet(isPresented: $showBackup) {
            if let result = result {
                BackupKeySheet(result: result) {
                    showBackup = false
                    onComplete(result)
                }
            }
        }
    }

    private func generateKey() {
        isGenerating = true
        errorMessage = nil

        // Run synchronously (key generation is fast)
        do {
            let r = try service.createNewIdentity(label: label.isEmpty ? nil : label)
            result = r
            isGenerating = false
            showBackup = true
        } catch {
            isGenerating = false
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Backup Key Sheet

struct BackupKeySheet: View {
    let result: OnboardingResult
    let onDismiss: () -> Void

    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 44))
                .foregroundColor(.orange)

            Text(L("backup.title"))
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 10) {
                BulletPointView(text: L("backup.bullet1"))
                BulletPointView(text: L("backup.bullet2"))
                BulletPointView(text: L("backup.bullet3"))
            }
            .padding(.horizontal, 24)

            // Your npub
            VStack(spacing: 4) {
                Text(L("backup.your_npub"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(result.npubTruncated)
                    .font(.system(.body, design: .monospaced))
            }
            .padding()

            // Secret key display
            if let nsec = result.nsecForBackup {
                VStack(spacing: 10) {
                    if isRevealed {
                        Text(nsec)
                            .font(.system(.caption, design: .monospaced))
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.1))
                            )
                            .textSelection(.enabled)
                    } else {
                        Text("••••••••••••••••••••••••")
                            .font(.system(.body, design: .monospaced))
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.secondary.opacity(0.1))
                            )
                    }

                    HStack(spacing: 12) {
                        Button(action: { isRevealed.toggle() }) {
                            Label(
                                isRevealed ? L("backup.hide") : L("backup.reveal"),
                                systemImage: isRevealed ? "eye.slash.fill" : "eye.fill"
                            )
                        }
                        .buttonStyle(.bordered)

                        if isRevealed {
                            Button(action: { copyToClipboard(nsec) }) {
                                Label(L("backup.copy"), systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }

            Spacer()

            Button(action: onDismiss) {
                Text(L("backup.done"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .padding(.top, 20)
    }
}

// MARK: - Import Key Sheet

struct ImportKeySheet: View {
    let service: OnboardingService
    let onComplete: (OnboardingResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keyInput: String = ""
    @State private var password: String = ""
    @State private var label: String = ""
    @State private var detectedFormat: InputFormat = .unknown
    @State private var errorMessage: String?
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.accentColor)

                Text(L("import.title"))
                    .font(.title2)
                    .bold()

                Text(L("import.subtitle"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)

            // Key input
            VStack(alignment: .leading, spacing: 6) {
                Text(L("import.key_header"))
                    .font(.headline)

                SecureInputField(
                    placeholder: L("import.key_placeholder"),
                    text: $keyInput
                )
                .onChange(of: keyInput) { newValue in
                    detectedFormat = service.detectInputFormat(newValue)
                    errorMessage = nil
                }

                // Format indicator
                if !keyInput.isEmpty {
                    formatIndicator
                }
            }
            .padding(.horizontal, 24)

            // Password field (for ncryptsec)
            if detectedFormat == .ncryptsec {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("import.password_header"))
                        .font(.headline)
                    SecureField(L("import.password_placeholder"), text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(.horizontal, 24)
            }

            // Label
            VStack(alignment: .leading, spacing: 6) {
                Text(L("import.label_header"))
                    .font(.headline)
                TextField(L("import.label_placeholder"), text: $label)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    #endif
            }
            .padding(.horizontal, 24)

            Spacer()

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 24)
            }

            // Actions
            VStack(spacing: 12) {
                Button(action: importKey) {
                    if isImporting {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Text(L("import.import_btn"))
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canImport || isImporting)

                Button(L("import.cancel")) { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    private var canImport: Bool {
        switch detectedFormat {
        case .nsec, .hex:
            return true
        case .ncryptsec:
            return !password.isEmpty
        case .npub, .unknown:
            return false
        }
    }

    @ViewBuilder
    private var formatIndicator: some View {
        HStack(spacing: 4) {
            switch detectedFormat {
            case .nsec:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text(L("import.format_nsec")).font(.caption).foregroundColor(.green)
            case .hex:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text(L("import.format_hex")).font(.caption).foregroundColor(.green)
            case .ncryptsec:
                Image(systemName: "lock.circle.fill").foregroundColor(.orange)
                Text(L("import.format_ncryptsec")).font(.caption).foregroundColor(.orange)
            case .npub:
                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                Text(L("import.format_npub")).font(.caption).foregroundColor(.red)
            case .unknown:
                if keyInput.count > 3 {
                    Image(systemName: "questionmark.circle.fill").foregroundColor(.secondary)
                    Text(L("import.format_unknown")).font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func importKey() {
        isImporting = true
        errorMessage = nil

        do {
            let result: OnboardingResult
            let labelValue = label.isEmpty ? nil : label

            switch detectedFormat {
            case .ncryptsec:
                result = try service.importNCryptsec(keyInput, password: password, label: labelValue)
            case .nsec, .hex:
                result = try service.importKey(keyInput, label: labelValue)
            case .npub:
                errorMessage = L("import.error_npub")
                isImporting = false
                return
            case .unknown:
                errorMessage = L("import.error_unknown")
                isImporting = false
                return
            }

            isImporting = false
            onComplete(result)
        } catch {
            isImporting = false
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Secure Input Field

/// A text field that hides its content (like SecureField but with paste support).
struct SecureInputField: View {
    let placeholder: String
    @Binding var text: String
    @State private var isSecure = true

    var body: some View {
        HStack {
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            #if os(iOS)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            #endif

            Button(action: { isSecure.toggle() }) {
                Image(systemName: isSecure ? "eye.fill" : "eye.slash.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Info Row

struct InfoRowView: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - Bullet Point

struct BulletPointView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.headline)
                .foregroundColor(.secondary)
            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - Clipboard

private func copyToClipboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
}

// MARK: - Localization

private func L(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .module, value: key, comment: "")
}
