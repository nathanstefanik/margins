import SwiftUI
import MarginsModel

/// The sidebar width the window opens with. The system default is
/// narrower, which leaves the reading surface lopsided against the
/// library; 320 keeps the two sides balanced at the reader's default
/// measure and the user can still drag within the bounds.
private let sidebarWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (260, 320, 440)

/// Exposes the split view's column visibility to the menu commands so
/// ⌘B can toggle the sidebar (the system's default sidebar shortcut is
/// replaced in `MarginsCommands`).
struct SidebarVisibilityKey: FocusedValueKey {
    typealias Value = Binding<NavigationSplitViewVisibility>
}

extension FocusedValues {
    var sidebarVisibility: SidebarVisibilityKey.Value? {
        get { self[SidebarVisibilityKey.self] }
        set { self[SidebarVisibilityKey.self] = newValue }
    }
}

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ClubModel.self) private var clubs
    @Environment(ReaderModel.self) private var reader
    @State private var keyboardController: ShellKeyboardController?
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var clubs = clubs
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: sidebarWidth.min,
                    ideal: sidebarWidth.ideal,
                    max: sidebarWidth.max
                )
        } detail: {
            DetailArea()
        }
        .focusedSceneValue(\.sidebarVisibility, $sidebarVisibility)
        // While the notes editor is open the detail area needs the reader's
        // 400-point minimum plus the editor's 320-point minimum; the
        // library sidebar takes the rest, so the window minimum grows with
        // the pane instead of clipping it.
        .frame(minWidth: reader.isOpen && reader.notesVisible ? 1040 : 720, minHeight: 440)
        .overlay(alignment: .bottom) {
            errorBanner
        }
        .overlay {
            if model.searchOpen {
                SearchOverlay()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay {
            if model.helpOpen {
                HelpOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .overlay {
            if model.bookmarksOpen {
                BookmarksOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.searchOpen)
        .animation(.easeOut(duration: 0.15), value: model.helpOpen)
        .animation(.easeOut(duration: 0.15), value: model.bookmarksOpen)
        .onChange(of: reader.isOpen) {
            if !reader.isOpen {
                model.requestBookmarksDismissal()
            }
        }
        .sheet(isPresented: $clubs.createSheetPresented) {
            CreateClubSheet()
                .environment(model)
                .environment(clubs)
        }
        .sheet(isPresented: $clubs.joinSheetPresented) {
            JoinClubSheet()
                .environment(model)
                .environment(clubs)
        }
        .task {
            await model.activate()
            if let store = model.coreStore {
                await clubs.activate(store: store)
            }
            model.onBookNotesChanged = { bookId in
                await clubs.schedulePublish(bookId: bookId)
            }
        }
        .onAppear {
            if keyboardController == nil {
                let controller = ShellKeyboardController(model: model, reader: reader)
                controller.start()
                keyboardController = controller
            }
        }
    }

    /// Non-fatal errors surface as a transient banner instead of a modal:
    /// the message explains itself and drifts away; a click dismisses.
    @ViewBuilder
    private var errorBanner: some View {
        if let message = clubs.errorMessage ?? model.errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.callout)
                    .lineLimit(3)
                Spacer(minLength: 8)
                Button("Dismiss") {
                    clubs.errorMessage = nil
                    model.clearError()
                }
                .buttonStyle(.borderless)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task {
                try? await Task.sleep(for: .seconds(8))
                withAnimation {
                    clubs.errorMessage = nil
                    model.clearError()
                }
            }
        }
    }
}
