import UIKit
import MobileCoreServices
import UniformTypeIdentifiers
import KeyfobCore
import KeyfobCrypto
import KeyfobPolicy

/// iOS Action Extension that appears in the Share Sheet.
///
/// Accepts text input containing a Nostr event JSON, signs it via the
/// Orchestrator (which enforces consent and policy), and returns the
/// signed result as output.
///
/// Input: text/plain or public.json containing a JSON-encoded NostrEvent
/// Output: JSON string with {id, sig, pubkey} appended to the input item
final class ActionExtension: UIViewController {

    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        processInput()
    }

    // MARK: - UI

    private func setupUI() {
        navigationItem.title = NSLocalizedString("action.title", comment: "Action extension title")

        // Cancel button
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = NSLocalizedString("action.signing", comment: "Signing in progress")
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
        spinner.startAnimating()
    }

    // MARK: - Input Processing

    private func processInput() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish(error: "No input items")
            return
        }

        // Find the first text attachment
        var found = false
        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    found = true
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] data, error in
                        DispatchQueue.main.async {
                            if let error = error {
                                self?.finish(error: error.localizedDescription)
                                return
                            }
                            let text: String
                            if let s = data as? String {
                                text = s
                            } else if let d = data as? Data, let s = String(data: d, encoding: .utf8) {
                                text = s
                            } else {
                                self?.finish(error: NSLocalizedString("action.err_no_text", comment: "Could not read text"))
                                return
                            }
                            self?.signEvent(json: text)
                        }
                    }
                    break
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                    found = true
                    provider.loadItem(forTypeIdentifier: UTType.json.identifier, options: nil) { [weak self] data, error in
                        DispatchQueue.main.async {
                            if let error = error {
                                self?.finish(error: error.localizedDescription)
                                return
                            }
                            let text: String
                            if let d = data as? Data, let s = String(data: d, encoding: .utf8) {
                                text = s
                            } else if let s = data as? String {
                                text = s
                            } else {
                                self?.finish(error: NSLocalizedString("action.err_no_text", comment: "Could not read text"))
                                return
                            }
                            self?.signEvent(json: text)
                        }
                    }
                    break
                }
            }
            if found { break }
        }

        if !found {
            finish(error: NSLocalizedString("action.err_no_event", comment: "No event JSON found in shared content"))
        }
    }

    // MARK: - Signing

    private func signEvent(json: String) {
        // Parse the Nostr event
        guard let data = json.data(using: .utf8) else {
            finish(error: NSLocalizedString("action.err_invalid_json", comment: "Invalid JSON"))
            return
        }

        let event: NostrEvent
        do {
            event = try JSONDecoder().decode(NostrEvent.self, from: data)
        } catch {
            finish(error: String(format: NSLocalizedString("action.err_parse_fmt", comment: "Parse error"), error.localizedDescription))
            return
        }

        // Perform signing on background thread (Orchestrator may block for consent)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let orchestrator = SignOrchestrator()
                let resp = try orchestrator.prepareAndSign(
                    event: event,
                    origin: "action.extension",
                    mode: .perRequest
                )

                // Build output: original event + signature fields
                let output: [String: Any] = [
                    "id": resp.id,
                    "sig": resp.sig,
                    "pubkey": resp.pubkey,
                    "kind": event.kind,
                    "created_at": event.created_at,
                    "tags": event.tags,
                    "content": event.content
                ]
                let outputData = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
                let outputJSON = String(data: outputData, encoding: .utf8) ?? "{}"

                DispatchQueue.main.async {
                    self?.finishSuccess(outputJSON: outputJSON)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finish(error: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Completion

    private func finishSuccess(outputJSON: String) {
        spinner.stopAnimating()
        statusLabel.text = NSLocalizedString("action.success", comment: "Signed successfully")
        statusLabel.textColor = .systemGreen

        let outputItem = NSExtensionItem()
        outputItem.attributedContentText = NSAttributedString(string: outputJSON)
        extensionContext?.completeRequest(returningItems: [outputItem], completionHandler: nil)
    }

    private func finish(error message: String) {
        spinner.stopAnimating()
        statusLabel.text = message
        statusLabel.textColor = .systemRed

        let err = NSError(
            domain: "KeyfobActionExt",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        extensionContext?.cancelRequest(withError: err)
    }

    @objc private func cancelTapped() {
        let err = NSError(
            domain: "KeyfobActionExt",
            code: NSUserCancelledError,
            userInfo: nil
        )
        extensionContext?.cancelRequest(withError: err)
    }
}
