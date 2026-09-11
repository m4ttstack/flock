import SwiftUI

struct DropPoint: Codable {
    let x: Double
    let y: Double
    let timestamp: Double
}

/// Mirrors the real app's approach (spec: "custom in-window DragGesture
/// state machine"), not SwiftUI's system onDrag/NSItemProvider path -- so
/// this spike validates the same drag mechanism Tasks 9+ will build.
struct ContentView: View {
    @State private var dragOffset: CGSize = .zero
    @State private var targetFrame: CGRect = .zero

    var body: some View {
        HStack(spacing: 80) {
            Rectangle()
                .fill(Color.blue)
                .frame(width: 80, height: 80)
                .offset(dragOffset)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("spike.drag.source")
                .accessibilityLabel("drag source")
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            dragOffset = value.translation
                        }
                        .onEnded { value in
                            dragOffset = .zero
                            handleDrop(at: value.location)
                        }
                )

            Rectangle()
                .strokeBorder(Color.green, lineWidth: 4)
                .frame(width: 160, height: 160)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { targetFrame = proxy.frame(in: .global) }
                            .onChange(of: proxy.frame(in: .global)) { _, newFrame in
                                targetFrame = newFrame
                            }
                    }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("spike.drag.target")
                .accessibilityLabel("drop target")
        }
        .padding(60)
        .frame(width: 500, height: 300)
    }

    /// Only counts as a landed drop when the drag actually ended inside the
    /// target's frame -- writing the file unconditionally would make the
    /// 20/20 pass criterion meaningless (it would pass even if the gesture
    /// or the coordinate math were wrong).
    private func handleDrop(at point: CGPoint) {
        guard targetFrame.insetBy(dx: -4, dy: -4).contains(point) else { return }

        let payload = DropPoint(x: point.x, y: point.y, timestamp: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/spike-drop.json"))
        }
        HerdrBridge.notifyDropIfConfigured()
    }
}
