import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The root: Books' title alone while the store opens and under the first-launch level test, the launch failure screen, or the
/// navigation stack. Everything presented app-wide hangs here: the document camera, the Photos picker, the file picker, every alert,
/// and the undo toast (above pushed screens, below sheets).
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var pickedPhotos: [PhotosPickerItem] = []
    /// Where the picked photos go, kept from when the picker opens: closing the picker clears `app.photosTarget`.
    @State private var photosDestination: ImportTarget?
    /// The rename alert's text once edited; nil shows the current title.
    @State private var renameDraft: String?

    var body: some View {
        @Bindable var app = app
        content
            .fullScreenCover(item: $app.cover, onDismiss: app.coverDismissed) { cover in
                switch cover {
                case .levelTest:
                    LevelTestView()
                case .scanner(let target):
                    DocumentScanner { app.scannerFinished($0, target: target) }
                        .ignoresSafeArea()
                }
            }
            .photosPicker(isPresented: photosPresented, selection: $pickedPhotos, maxSelectionCount: 50,
                          selectionBehavior: .ordered, matching: .images)
            .onChange(of: app.photosTarget) { _, target in
                if let target { photosDestination = target }
            }
            .onChange(of: pickedPhotos) { _, photos in
                guard !photos.isEmpty, let destination = photosDestination else { return }
                pickedPhotos = []
                app.importPages(.photos(photos), into: destination)
            }
            // Out of process like the Photos picker: no permission prompt. Cancelling, or a pick the system could not hand over, does
            // nothing.
            .fileImporter(isPresented: $app.showsFileImporter, allowedContentTypes: [.epub, .plainText]) { result in
                if case .success(let url) = result { app.openFile(url) }
            }
            .alert(alertTitle, isPresented: alertPresented, presenting: app.alert, actions: alertActions, message: alertMessage)
            .overlay(alignment: .bottom) { Toast() }
            // A Reader that leaves the stack, however many screens were popped at once (a cancelled back swipe changes nothing)
            .onChange(of: app.path) { old, new in
                let kept = zip(old, new).prefix { $0 == $1 }.count
                for case .reader(let bookID, _) in old.dropFirst(kept) {
                    app.readerClosed(bookID: bookID)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch app.phase {
        case .opening, .ready:
            if app.phase == .ready, app.cover != .levelTest {
                NavigationStack(path: Bindable(app).path) {
                    ShelfView()
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .book(let id): BookView(bookID: id)
                            case .reader(let bookID, let pageID): ReaderView(bookID: bookID, pageID: pageID)
                            case .wordList: WordListView()
                            }
                        }
                }
            } else {
                // The title only: no grid and no empty state until the books are read, so `No Books Yet` never flashes, nor the shelf
                // before the level test's cover is up, however late the system presents it
                NavigationStack {
                    Color.clear.navigationTitle("Books")
                }
            }
        case .failed:
            ContentUnavailableView {
                Label("Can’t Open Your Books", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Free up some space on this iPhone or update ReadStair, then try again.")
            } actions: {
                Button { app.retryLaunch() } label: {
                    // The size goes on the label: a frame around the button would not widen what it answers to
                    Text("Try Again")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .accessibilityIdentifier("launchRetry")
            }
        }
    }

    private var photosPresented: Binding<Bool> {
        Binding { app.photosTarget != nil } set: { if !$0 { app.photosTarget = nil } }
    }

    // MARK: Alerts

    /// An alert waits while a word card (the Reader and the Word List close theirs) or a full-screen cover is on screen: presented over
    /// either, it could be dropped.
    private var alertPresented: Binding<Bool> {
        Binding { app.alert != nil && !app.cardOnScreen && !app.coverOnScreen } set: {
            guard !$0 else { return }
            app.alert = nil
            renameDraft = nil
        }
    }

    private var alertTitle: Text {
        switch app.alert {
        case .cameraAccessOff: Text("Camera Access Is Off")
        case .storageFull: Text("iPhone Storage Is Full")
        case .photosUnreadable: Text("Couldn’t Add These Photos")
        case .bookUnopenable: Text("Couldn’t Open This Book")
        case .somethingWentWrong: Text("Something Went Wrong")
        case .rename: Text("Rename Book")
        case nil: Text(verbatim: "")
        }
    }

    @ViewBuilder
    private func alertActions(_ alert: AppAlert) -> some View {
        switch alert {
        case .cameraAccessOff:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        case .storageFull, .photosUnreadable, .bookUnopenable, .somethingWentWrong:
            Button("OK") {}
        case .rename(let bookID):
            TextField("Title", text: Binding { renameText(bookID) } set: { renameDraft = String($0.prefix(AppModel.maxTitleLength)) })
            Button("Cancel", role: .cancel) {}
            // Reads the title when tapped: the presented alert can keep the action it was given several keystrokes earlier
            Button("Save") { app.rename(bookID, to: renameText(bookID)) }
                .disabled(renameText(bookID).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// The rename alert's title: the draft once edited, else the book's current title.
    private func renameText(_ bookID: UUID) -> String {
        renameDraft ?? app.book(bookID)?.title ?? ""
    }

    @ViewBuilder
    private func alertMessage(_ alert: AppAlert) -> some View {
        switch alert {
        case .cameraAccessOff: Text("To scan pages, allow camera access for ReadStair in Settings.")
        case .storageFull: Text("Free up some space on this iPhone, then try again.")
        case .photosUnreadable: Text("Choose photos of printed pages that are saved on this iPhone.")
        case .bookUnopenable: Text("Choose an English book in EPUB format without copy protection, or a plain text file.")
        case .somethingWentWrong: Text("Please try again.")
        case .rename: EmptyView()
        }
    }
}

/// The undo toast. Timed by the undo slot; announced to VoiceOver with its own text when it appears.
private struct Toast: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            if let change = app.pendingChange {
                BottomCapsule(Text(change.toastText)) {
                    Button { app.undo() } label: {
                        // The size goes on the label: a frame around the button would not widen what it answers to
                        Text("Undo")
                            .bold()
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityIdentifier("undo")
                }
                .accessibilityIdentifier("toast")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.pendingChange)
        .onChange(of: app.pendingChange) { _, change in
            guard let change else { return }
            // High priority: the toast appears as the card or the menu closes, and VoiceOver's focus moving must not cut it off
            var announcement = AttributedString(change.toastText)
            announcement.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(announcement).post()
        }
    }
}
