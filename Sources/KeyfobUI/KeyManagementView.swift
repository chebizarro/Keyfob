//
//  KeyManagementView.swift
//
//
//  Created for Keyfob – kf-tiu
//
//  Key management UI: identity list, rename, activate, copy/share, delete.
//  Cross-platform iOS 15+ / macOS 12+.
//

import SwiftUI
import KeyfobCore

// MARK: - KeyManagementView

/// The main key management screen showing all identities with management actions.
///
/// Supports:
/// - Identity list with npub display and active indicator
/// - Rename identity (label editing)
/// - Set active identity (tap to switch)
/// - Copy/share public key (npub or hex)
/// - Delete identity (with confirmation, prevents deleting last)
///
/// ## Usage
///
/// ```swift
/// KeyManagementView(service: keyManagementService)
/// ```
public struct KeyManagementView: View {

    private let service: KeyManagementService

    @State private var identities: [IdentityViewModel] = []
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var identityToDelete: IdentityViewModel?
    @State private var showDeleteConfirmation = false
    @State private var identityToRename: IdentityViewModel?
    @State private var renameText: String = ""
    @State private var showRenameSheet = false

    public init(service: KeyManagementService) {
        self.service = service
    }

    public var body: some View {
        List {
            if identities.isEmpty {
                Section {
                    Text(L("keys.empty"))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                ForEach(identities) { identity in
                    IdentityRow(
                        identity: identity,
                        onActivate: { activateIdentity(identity) },
                        onRename: { beginRename(identity) },
                        onCopy: { copyNpub(identity) },
                        onCopyHex: { copyHex(identity) },
                        onDelete: { confirmDelete(identity) }
                    )
                }
            }
        }
        .navigationTitle(L("keys.title"))
        .onAppear { loadIdentities() }
        .alert(L("keys.error_title"), isPresented: $showError) {
            Button(L("keys.ok")) { }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L("keys.delete_title"), isPresented: $showDeleteConfirmation) {
            Button(L("keys.delete_confirm"), role: .destructive) {
                if let identity = identityToDelete {
                    deleteIdentity(identity)
                }
            }
            Button(L("keys.cancel"), role: .cancel) { }
        } message: {
            if let identity = identityToDelete {
                Text(String(format: L("keys.delete_message"), identity.displayName))
            }
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameSheet(
                currentLabel: identityToRename?.label ?? "",
                text: $renameText,
                onSave: {
                    if let identity = identityToRename {
                        renameIdentity(identity, newLabel: renameText)
                    }
                    showRenameSheet = false
                },
                onCancel: { showRenameSheet = false }
            )
        }
    }

    // MARK: - Actions

    private func loadIdentities() {
        do {
            identities = try service.listIdentities()
        } catch {
            showErrorMessage(error.localizedDescription)
        }
    }

    private func activateIdentity(_ identity: IdentityViewModel) {
        do {
            try service.setActiveIdentity(id: identity.id)
            loadIdentities() // Refresh to update active state
        } catch {
            showErrorMessage(error.localizedDescription)
        }
    }

    private func beginRename(_ identity: IdentityViewModel) {
        identityToRename = identity
        renameText = identity.label ?? ""
        showRenameSheet = true
    }

    private func renameIdentity(_ identity: IdentityViewModel, newLabel: String) {
        do {
            try service.renameIdentity(id: identity.id, newLabel: newLabel)
            loadIdentities()
        } catch {
            showErrorMessage(error.localizedDescription)
        }
    }

    private func copyNpub(_ identity: IdentityViewModel) {
        copyToClipboard(identity.npubFull)
    }

    private func copyHex(_ identity: IdentityViewModel) {
        copyToClipboard(identity.pubkeyHex)
    }

    private func confirmDelete(_ identity: IdentityViewModel) {
        identityToDelete = identity
        showDeleteConfirmation = true
    }

    private func deleteIdentity(_ identity: IdentityViewModel) {
        do {
            try service.deleteIdentity(id: identity.id)
            loadIdentities()
        } catch {
            showErrorMessage(error.localizedDescription)
        }
    }

    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}

// MARK: - Identity Row

struct IdentityRow: View {
    let identity: IdentityViewModel
    let onActivate: () -> Void
    let onRename: () -> Void
    let onCopy: () -> Void
    let onCopyHex: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top line: display name + active badge
            HStack {
                Text(identity.displayName)
                    .font(.headline)

                if identity.isActive {
                    Text(L("keys.active_badge"))
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                }

                Spacer()

                sourceIcon
            }

            // npub display
            Text(identity.npubTruncated)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)

            // Date
            Text(String(format: L("keys.created_fmt"), formattedDate))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            if !identity.isActive {
                Button(action: onActivate) {
                    Label(L("keys.set_active"), systemImage: "checkmark.circle")
                }
            }

            Button(action: onRename) {
                Label(L("keys.rename"), systemImage: "pencil")
            }

            Button(action: onCopy) {
                Label(L("keys.copy_npub"), systemImage: "doc.on.doc")
            }

            Button(action: onCopyHex) {
                Label(L("keys.copy_hex"), systemImage: "number")
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label(L("keys.delete"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onDelete) {
                Label(L("keys.delete"), systemImage: "trash")
            }

            if !identity.isActive {
                Button(action: onActivate) {
                    Label(L("keys.set_active"), systemImage: "checkmark.circle")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(action: onCopy) {
                Label(L("keys.copy_npub"), systemImage: "doc.on.doc")
            }
            .tint(.indigo)
        }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        switch identity.source {
        case "generated":
            Image(systemName: "sparkle")
                .foregroundColor(.blue)
                .help(L("keys.source_generated"))
        case "imported":
            Image(systemName: "square.and.arrow.down")
                .foregroundColor(.orange)
                .help(L("keys.source_imported"))
        case "nip49":
            Image(systemName: "lock.fill")
                .foregroundColor(.purple)
                .help(L("keys.source_nip49"))
        default:
            Image(systemName: "key.fill")
                .foregroundColor(.secondary)
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: identity.createdAt)
    }
}

// MARK: - Rename Sheet

struct RenameSheet: View {
    let currentLabel: String
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text(L("keys.rename_title"))
                .font(.title3)
                .bold()

            TextField(L("keys.rename_placeholder"), text: $text)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .autocorrectionDisabled()
                #endif

            HStack(spacing: 16) {
                Button(L("keys.cancel"), action: onCancel)
                    .buttonStyle(.bordered)

                Button(L("keys.rename_save"), action: onSave)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .onAppear { text = currentLabel }
    }
}

// MARK: - Helpers

private func copyToClipboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    #endif
}

private func L(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .module, value: key, comment: "")
}
