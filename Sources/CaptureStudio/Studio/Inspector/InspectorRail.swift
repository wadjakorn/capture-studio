import SwiftUI

/// Vertical 7-icon rail (one per `RailTab`) plus the routed inspector panel
/// for the current `InspectorContext`. Not yet wired into `StudioView` —
/// Task 5 swaps the layout to use this.
struct InspectorRail: View {
    @Binding var active: RailTab
    let context: InspectorContext
    @ObservedObject var model: StudioModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(RailTab.allCases, id: \.self) { tab in
                    Button { active = tab } label: {
                        Image(systemName: tab.symbol)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .background(railHighlight(tab), in: RoundedRectangle(cornerRadius: 8))
                    .help(tab.title)
                }
                Spacer()
            }
            .frame(width: 46)
            .padding(.vertical, 10)

            Divider()

            ScrollView { panel.padding(14) }
                .frame(width: 300)
        }
    }

    private func railHighlight(_ tab: RailTab) -> Color {
        if case .tab(let t) = context, t == tab { return .secondary.opacity(0.2) }
        return .clear
    }

    @ViewBuilder private var panel: some View {
        switch context {
        case .shape: ShapeInspector(model: model)
        case .zoom:  ZoomInspector(model: model)
        case .tab(let t):
            switch t {
            case .frame:     FrameInspector(model: model)
            case .cursor:    CursorInspector(model: model)
            case .camera:    CameraInspector(model: model)
            case .captions:
                CaptionsInspector.CaptionsPanel(model: model)
            case .audio:     AudioInspector(model: model)
            case .shortcuts: ShortcutsInspector()
            case .share:     ShareInspector(model: model)
            }
        }
    }
}
