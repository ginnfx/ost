//
//  DebugSettingsView.swift
//  Lume
//
//  End-user diagnostics. A toggle starts a "Debug Logging" session; once on, the
//  user can reproduce a problem and then email the captured logs to support or
//  share them. The actual capture is the OS unified log (Lume already logs via
//  `Logger`); `DebugLogExporter` reads it back, scoped to the session, redacts
//  private values, and writes a text file.
//
//  iOS gets a native Mail composer (falling back to the share sheet when Mail
//  isn't set up); macOS uses ShareLink plus a mailto link. tvOS has no
//  diagnostics UI — it can neither attach a file nor compose mail, and the
//  captured logs add little value there.
//

import SwiftUI
#if os(iOS)
    import MessageUI
#endif

// MARK: - Settings entry points

extension SettingsView {
    #if !os(tvOS)
        /// iOS / macOS grouped-list section linking to the diagnostics screen.
        var diagnosticsSection: some View {
            Section {
                NavigationLink {
                    DebugSettingsView()
                } label: {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Turn on debug logging to help diagnose a problem, then send the logs to the developer.")
            }
        }
    #endif
}

#if !os(tvOS)

    // MARK: - iOS / macOS screen

    struct DebugSettingsView: View {
        @AppStorage(DebugLogSettings.enabledKey) private var loggingEnabled = false
        @State private var isPreparing = false
        @State private var errorMessage: String?
        @State private var shareItem: ExportedLog?
        #if os(iOS)
            @State private var mailItem: ExportedLog?
        #elseif os(macOS)
            @State private var preparedURL: URL?
        #endif

        var body: some View {
            List {
                Section {
                    Toggle("Debug Logging", isOn: $loggingEnabled)
                        .onChange(of: loggingEnabled) { _, isOn in
                            if isOn { DebugLogSettings.markEnabled(at: Date()) }
                        }
                } footer: {
                    Text("Records diagnostic logs as you use the app. Reproduce the problem, then send the logs below. They stay on your device until you send them, and personal details are hidden.")
                }

                if loggingEnabled {
                    submitSection
                    Section {
                        NavigationLink {
                            DebugLogViewerView()
                        } label: {
                            Label("View Logs", systemImage: "doc.text.magnifyingglass")
                        }
                    } footer: {
                        Text("Review exactly what will be sent before you share it.")
                    }
                }
            }
            .platformNavigationTitle("Diagnostics")
            .alert("Couldn't Prepare Logs", isPresented: errorAlertBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            #if os(iOS)
            .sheet(item: $mailItem) { item in
                MailComposeView(
                    recipient: SupportInfo.email,
                    subject: String(localized: "Lume Diagnostics — \(SupportInfo.appVersion)"),
                    body: String(localized: "Describe the problem here. The diagnostic log is attached.\n\n"),
                    attachmentURL: item.url
                )
                .ignoresSafeArea()
            }
            #endif
            .sheet(item: $shareItem) { item in
                shareSheet(for: item.url)
            }
        }

        private var submitSection: some View {
            Section {
                #if os(iOS)
                    Button {
                        Task { await prepareThenEmail() }
                    } label: {
                        actionLabel("Email Logs to Developer", systemImage: "envelope")
                    }
                    .disabled(isPreparing)

                    Button {
                        Task { await prepare { shareItem = $0 } }
                    } label: {
                        actionLabel("Share Logs…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isPreparing)
                #elseif os(macOS)
                    if let preparedURL {
                        ShareLink(item: preparedURL) {
                            Label("Share Logs…", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        Task { await prepare { preparedURL = $0.url } }
                    } label: {
                        actionLabel(preparedURL == nil ? "Prepare Logs" : "Refresh Logs", systemImage: "arrow.clockwise")
                    }
                    .disabled(isPreparing)

                    if let url = SupportInfo.emailURL {
                        Link(destination: url) {
                            Label("Email the Developer", systemImage: "envelope")
                        }
                    }
                #endif
            } footer: {
                Text("Logs are sent to \(SupportInfo.email).")
            }
        }

        private func actionLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
            HStack {
                Label(title, systemImage: systemImage)
                if isPreparing {
                    Spacer()
                    ProgressView()
                }
            }
        }

        private var errorAlertBinding: Binding<Bool> {
            Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        }

        // MARK: Preparation

        /// Writes the report off the main actor, then hands the URL to `assign`.
        private func prepare(_ assign: (ExportedLog) -> Void) async {
            isPreparing = true
            defer { isPreparing = false }
            let metadata = DebugLogExporter.currentMetadata()
            do {
                let url = try await DebugLogExporter(metadata: metadata).writeReport()
                assign(ExportedLog(url: url))
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        #if os(iOS)
            private func prepareThenEmail() async {
                guard MFMailComposeViewController.canSendMail() else {
                    // No Mail account — fall back to the share sheet.
                    await prepare { shareItem = $0 }
                    return
                }
                await prepare { mailItem = $0 }
            }
        #endif

        @ViewBuilder
        private func shareSheet(for url: URL) -> some View {
            #if os(iOS)
                ActivityView(items: [url]).ignoresSafeArea()
            #else
                EmptyView()
            #endif
        }
    }

    // MARK: - Log viewer

    /// A read-only, monospaced preview of the report the user is about to send,
    /// so they can see exactly what leaves the device.
    struct DebugLogViewerView: View {
        @State private var text = ""
        @State private var isLoading = true

        var body: some View {
            ScrollView {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    Text(text)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            .platformNavigationTitle("Logs")
            .task {
                let metadata = DebugLogExporter.currentMetadata()
                text = await (try? DebugLogExporter(metadata: metadata).makeReport())
                    ?? String(localized: "Couldn't read the logs.")
                isLoading = false
            }
        }
    }

    /// The exported file, wrapped so it can drive a `.sheet(item:)`.
    struct ExportedLog: Identifiable {
        let id = UUID()
        let url: URL
    }

#endif

// MARK: - iOS system-UI wrappers

#if os(iOS)

    /// Presents the system Mail composer pre-filled with the support address and
    /// the diagnostic log attached.
    struct MailComposeView: UIViewControllerRepresentable {
        let recipient: String
        let subject: String
        let body: String
        let attachmentURL: URL
        @Environment(\.dismiss) private var dismiss

        func makeUIViewController(context: Context) -> MFMailComposeViewController {
            let controller = MFMailComposeViewController()
            controller.mailComposeDelegate = context.coordinator
            controller.setToRecipients([recipient])
            controller.setSubject(subject)
            controller.setMessageBody(body, isHTML: false)
            if let data = try? Data(contentsOf: attachmentURL) {
                controller.addAttachmentData(data, mimeType: "text/plain", fileName: attachmentURL.lastPathComponent)
            }
            return controller
        }

        func updateUIViewController(_: MFMailComposeViewController, context _: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(dismiss: dismiss)
        }

        final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
            private let dismiss: DismissAction

            init(dismiss: DismissAction) {
                self.dismiss = dismiss
            }

            func mailComposeController(
                _: MFMailComposeViewController,
                didFinishWith _: MFMailComposeResult,
                error _: Error?
            ) {
                dismiss()
            }
        }
    }

    /// Thin wrapper over `UIActivityViewController` for the share-sheet fallback.
    struct ActivityView: UIViewControllerRepresentable {
        let items: [Any]

        func makeUIViewController(context _: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items, applicationActivities: nil)
        }

        func updateUIViewController(_: UIActivityViewController, context _: Context) {}
    }

#endif
