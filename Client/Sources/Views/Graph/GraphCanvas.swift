import SwiftUI

/// Pannable, zoomable knowledge-graph canvas: bezier edges (thickness ∝ weight,
/// predicate labels at midpoints), entity node cards, and the search-trace
/// overlay (gold halos on matched entities, dashed highlights on expansion edges).
struct GraphCanvas: View {
    @ObservedObject var viewModel: GraphViewModel

    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @GestureState private var pinch: CGFloat = 1.0

    private var effectiveScale: CGFloat { max(0.25, min(2.5, scale * pinch)) }

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2 + offset.width,
                                 y: geometry.size.height / 2 + offset.height)
            ZStack {
                Color.sewnBG

                // Edges
                Canvas { context, _ in
                    for edge in viewModel.edges {
                        guard let from = viewModel.nodes.first(where: { $0.id == edge.relationship.subjectId }),
                              let to = viewModel.nodes.first(where: { $0.id == edge.relationship.objectId })
                        else { continue }

                        let start = transform(from.position, center: center)
                        let end = transform(to.position, center: center)
                        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                        let control = CGPoint(
                            x: mid.x + (end.y - start.y) * 0.12,
                            y: mid.y - (end.x - start.x) * 0.12
                        )

                        var path = Path()
                        path.move(to: start)
                        path.addQuadCurve(to: end, control: control)

                        let weight = CGFloat(edge.relationship.weight ?? 1)
                        let isTraced = viewModel.traceActive
                            && viewModel.traceExpansionEdgeIds.contains(edge.id)
                        let lineWidth = min(1 + weight * 0.6, 4) * effectiveScale
                        if isTraced {
                            context.stroke(path, with: .color(Color.sewnGold.opacity(0.9)),
                                           style: StrokeStyle(lineWidth: lineWidth + 1, dash: [6, 4]))
                        } else {
                            let dimmed = viewModel.traceActive
                            context.stroke(path, with: .color(Color.sewnInk.opacity(dimmed ? 0.12 : 0.25)),
                                           lineWidth: lineWidth)
                        }

                        // Predicate label at the curve midpoint (skip when zoomed way out).
                        if effectiveScale > 0.55 {
                            let labelPoint = CGPoint(
                                x: (start.x + 2 * control.x + end.x) / 4,
                                y: (start.y + 2 * control.y + end.y) / 4
                            )
                            context.draw(
                                Text(edge.relationship.predicate)
                                    .font(.system(size: 9 * effectiveScale, design: .monospaced))
                                    .foregroundColor(Color.sewnInk.opacity(0.45)),
                                at: labelPoint
                            )
                        }
                    }
                }

                // Nodes
                ForEach(viewModel.nodes) { node in
                    EntityNodeView(
                        node: node,
                        isSelected: viewModel.selectedEntityId == node.id,
                        isTraceMatched: viewModel.traceActive
                            && viewModel.traceMatchedIds.contains(node.id),
                        traceActive: viewModel.traceActive,
                        scale: effectiveScale
                    )
                    .position(transform(node.position, center: center))
                    .onTapGesture {
                        viewModel.selectedEntityId = node.id
                    }
                    .contextMenu { nodeMenu(node) }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(width: dragStart.width + value.translation.width,
                                        height: dragStart.height + value.translation.height)
                    }
                    .onEnded { _ in dragStart = offset }
            )
            .gesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in scale = max(0.25, min(2.5, scale * value.magnification)) }
            )
            .overlay(alignment: .bottomTrailing) { zoomControls }
        }
        .clipped()
    }

    private func transform(_ point: CGPoint, center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + point.x * effectiveScale,
                y: center.y + point.y * effectiveScale)
    }

    @ViewBuilder
    private func nodeMenu(_ node: GraphViewModel.Node) -> some View {
        Button("Rename…") {
            viewModel.selectedEntityId = node.id
            viewModel.renamingEntityId = node.id
        }
        Menu("Change kind") {
            ForEach(["person", "organization", "place", "event", "work", "concept", "other"], id: \.self) { kind in
                Button(kind) { viewModel.setKind(entityId: node.id, kind: kind) }
            }
        }
        Menu("Merge into…") {
            ForEach(viewModel.nodes.filter { $0.id != node.id }) { other in
                Button(other.entity.name) {
                    viewModel.merge(entityId: node.id, into: other.id)
                }
            }
        }
        Divider()
        Button("Delete entity", role: .destructive) {
            viewModel.delete(entityId: node.id)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button { scale = max(0.25, scale - 0.2) } label: { Image(systemName: "minus") }
            Text("\(Int(effectiveScale * 100))%")
                .font(.sewnMono(10))
                .frame(width: 42)
            Button { scale = min(2.5, scale + 0.2) } label: { Image(systemName: "plus") }
            Button {
                scale = 1; offset = .zero; dragStart = .zero
            } label: { Image(systemName: "scope") }
        }
        .buttonStyle(.sewnQuiet)
        .padding(10)
    }
}

/// A single entity node: kind → hue, mention count → size tier.
struct EntityNodeView: View {
    let node: GraphViewModel.Node
    let isSelected: Bool
    let isTraceMatched: Bool
    let traceActive: Bool
    let scale: CGFloat

    static func hue(for kind: String) -> Color {
        switch kind {
        case "person": return Color(red: 110/255, green: 140/255, blue: 180/255)
        case "organization": return Color(red: 140/255, green: 110/255, blue: 170/255)
        case "place": return Color(red: 100/255, green: 155/255, blue: 120/255)
        case "event": return Color(red: 190/255, green: 120/255, blue: 100/255)
        case "work": return Color(red: 170/255, green: 140/255, blue: 90/255)
        default: return .sewnGold
        }
    }

    private var sizeTier: CGFloat {
        let mentions = node.entity.mentionCount ?? 1
        return mentions >= 8 ? 1.35 : mentions >= 3 ? 1.15 : 1.0
    }

    var body: some View {
        let tint = Self.hue(for: node.entity.kind)
        VStack(spacing: 3 * scale) {
            Text(node.entity.name)
                .font(.sewnSans(11.5 * scale * sizeTier, weight: node.isSeed ? .semibold : .medium))
                .foregroundStyle(Color.sewnInk)
                .lineLimit(1)
            Text(node.entity.kind)
                .font(.sewnMono(8 * scale))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 11 * scale)
        .padding(.vertical, 7 * scale)
        .background(
            RoundedRectangle(cornerRadius: 11 * scale)
                .fill(Color.white.opacity(traceActive && !isTraceMatched ? 0.45 : 0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 11 * scale)
                        .strokeBorder(
                            isSelected ? Color.sewnInk :
                                isTraceMatched ? Color.sewnGold : tint.opacity(0.5),
                            lineWidth: isSelected || isTraceMatched ? 2 : 1)
                )
        )
        .shadow(color: isTraceMatched ? Color.sewnGold.opacity(0.5) : Color.sewnInk.opacity(0.08),
                radius: isTraceMatched ? 9 : 3, y: 1)
        .opacity(traceActive && !isTraceMatched ? 0.75 : 1)
    }
}
