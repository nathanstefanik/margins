import SwiftUI
import MarginsModel

struct ContentView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(ClubModel.self) private var clubs
    @Environment(ReaderModel.self) private var reader
    @State private var keyboardController: ShellKeyboardController?

    var body: some View {
        @Bindable var clubs = clubs
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailArea()
        }
        .frame(minWidth: 720, minHeight: 440)
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
        .animation(.easeOut(duration: 0.15), value: model.searchOpen)
        .animation(.easeOut(duration: 0.15), value: model.helpOpen)
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
        if let message = model.errorMessage {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.callout)
                    .lineLimit(3)
                Spacer(minLength: 8)
                Button("Dismiss") {
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
                withAnimation { model.clearError() }
            }
        }
    }
}
