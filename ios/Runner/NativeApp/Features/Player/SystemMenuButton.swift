//
//  SystemMenuButton.swift
//  Kazumi
//
//  播放状态每 250ms 会刷新 SwiftUI 视图。菜单交给 UIButton / UIMenu 持有，
//  避免 SwiftUI Menu 留在屏幕上的旧副本点了不执行。
//

import SwiftUI
import UIKit

struct SystemMenuButton: UIViewRepresentable {
    struct Selection {
        struct Option {
            var title: String
            var isSelected: Bool
            var action: () -> Void
        }

        var options: [Option]
    }

    struct Item {
        var title: String
        var symbol: String
        var symbolImage: UIImage? = nil
        var symbolPointSize: CGFloat? = nil
        var isDestructive: Bool = false
        var subtitle: String? = nil
        var isChecked: Bool = false
        var submenu: [Item]? = nil
        var selection: Selection? = nil
        var action: () -> Void
    }

    var items: [Item] = []
    var selection: Selection? = nil
    var title: String?
    var symbol: String
    var accessibilityLabel: String
    var tint: Color = .white
    var showsChevron: Bool = false
    var menuTint: Color = .primary
    var symbolSize: CGFloat = 18
    var symbolWeight: Font.Weight = .medium
    /// 实心块状符号在 UIKit 侧没法用 scaleEffect，按 0.9pt 轻微缩一档。
    var symbolOptical: PlayerIconOptical = .standard
    var onOpen: () -> Void = {}
    var capsule: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(
            title == nil ? .required : .defaultLow,
            for: .horizontal
        )
        button.addAction(
            UIAction { [weak coordinator = context.coordinator] _ in
                MainActor.assumeIsolated {
                    coordinator?.onOpen()
                }
            },
            for: .menuActionTriggered
        )
        apply(to: button, context: context)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        apply(to: button, context: context)
        button.setNeedsLayout()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UIButton,
        context: Context
    ) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        let minimum: CGFloat = title == nil ? 40 : 0
        guard intrinsic.width > 0 || minimum > 0,
              intrinsic.height > 0 || minimum > 0
        else { return nil }

        var width = max(minimum, intrinsic.width)
        var height = max(minimum, intrinsic.height)
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 {
            width = min(width, proposed)
        }
        if let proposed = proposal.height, proposed.isFinite, proposed > 0 {
            height = min(height, proposed)
        }
        return CGSize(width: width, height: height)
    }

    private var resolvedItems: [Item] {
        let roots: [Item]
        if let selection {
            roots = selection.options.map { option in
                Item(title: option.title, symbol: "", isChecked: option.isSelected) {
                    option.action()
                }
            }
        } else {
            roots = items
        }
        return roots.map(Self.resolve)
    }

    private static func resolve(_ item: Item) -> Item {
        var result = item
        if let selection = item.selection {
            result.submenu = selection.options.map { option in
                Item(title: option.title, symbol: "", isChecked: option.isSelected) {
                    option.action()
                }
            }
            result.selection = nil
        } else if let submenu = item.submenu {
            result.submenu = submenu.map(resolve)
        }
        return result
    }

    private func apply(to button: UIButton, context: Context) {
        let coordinator = context.coordinator
        let resolvedItems = resolvedItems
        coordinator.items = resolvedItems
        coordinator.flat = Coordinator.flatten(resolvedItems)
        coordinator.onOpen = onOpen

        let tintColor = Self.uiColor(tint)
        let effectiveSymbolSize = symbolSize - (symbolOptical == .solid ? 0.9 : 0)
        let appearanceSignature = [
            title ?? "",
            symbol,
            String(describing: effectiveSymbolSize),
            String(describing: symbolWeight),
            String(describing: symbolOptical),
            String(showsChevron),
            String(capsule),
            String(describing: tintColor),
        ].joined(separator: "|")

        if appearanceSignature != coordinator.appearanceSignature {
            coordinator.appearanceSignature = appearanceSignature
            if let title {
                var configuration = UIButton.Configuration.plain()
                configuration.title = title
                configuration.baseForegroundColor = tintColor
                configuration.contentInsets = capsule
                    // 胶囊上下各 7：原来上下 0 只有字高那么薄（约 18，LP 7364）；
                    // 先改 6 量出 30，比右边下载胶囊的 32 还差 2，再补到 7 对齐（LP 量高度）。
                    ? NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
                    : .zero
                if showsChevron {
                    configuration.image = UIImage(
                        systemName: "chevron.down",
                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
                    )
                    configuration.imagePlacement = .trailing
                    configuration.imagePadding = 6
                }
                if capsule {
                    configuration.background.backgroundColor = .secondarySystemBackground
                    configuration.cornerStyle = .capsule
                }
                configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                    var outgoing = incoming
                    outgoing.font = .preferredFont(forTextStyle: .subheadline)
                    return outgoing
                }
                button.configuration = configuration
            } else {
                button.configuration = nil
                button.setTitle(nil, for: .normal)
                button.setImage(
                    UIImage(
                        systemName: symbol,
                        withConfiguration: UIImage.SymbolConfiguration(
                            pointSize: effectiveSymbolSize,
                            weight: Self.uiWeight(symbolWeight)
                        )
                    ),
                    for: .normal
                )
            }
        }

        button.tintColor = tintColor
        button.accessibilityLabel = accessibilityLabel
        button.contentHorizontalAlignment = .center
        button.contentVerticalAlignment = .center

        let signature = Self.signature(resolvedItems)
        guard signature != coordinator.menuSignature else { return }
        coordinator.menuSignature = signature
        button.menu = UIMenu(children: coordinator.makeElements(resolvedItems))
    }

    private static func signature(_ items: [Item]) -> String {
        items.map { item in
            [
                item.title,
                item.symbol,
                item.symbolImage == nil ? "" : "image",
                String(item.isDestructive),
                item.subtitle ?? "",
                String(item.isChecked),
                item.submenu.map(signature) ?? "",
            ].joined(separator: "|")
        }.joined(separator: "#")
    }

    private static func menuImage(_ item: Item) -> UIImage? {
        if let image = item.symbolImage { return image }
        guard !item.symbol.isEmpty else { return nil }
        // 菜单里的图标统一 18pt Medium：同一张菜单里不再按 .fill 再缩，
        // 否则心形/星星会比旁边的线性符号小一档。
        return UIImage(
            systemName: item.symbol,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: item.symbolPointSize ?? 18,
                weight: .medium
            )
        )
    }

    private static func uiWeight(_ weight: Font.Weight) -> UIImage.SymbolWeight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }

    private static func uiColor(_ color: Color) -> UIColor {
        switch color {
        case .primary: .label
        case .secondary: .secondaryLabel
        case .white: .white
        case .black: .black
        default: UIColor(color)
        }
    }

    @MainActor
    final class Coordinator {
        var items: [Item] = []
        var flat: [Item] = []
        var onOpen: () -> Void = {}
        var appearanceSignature = ""
        var menuSignature = ""

        static func flatten(_ items: [Item]) -> [Item] {
            items.flatMap { item in
                if let submenu = item.submenu { return flatten(submenu) }
                return [item]
            }
        }

        func makeElements(_ items: [Item]) -> [UIMenuElement] {
            var leafIndex = 0
            func elements(_ list: [Item]) -> [UIMenuElement] {
                list.map { item in
                    if let submenu = item.submenu {
                        return UIMenu(
                            title: item.title,
                            subtitle: item.subtitle ?? "",
                            image: SystemMenuButton.menuImage(item),
                            children: elements(submenu)
                        )
                    }
                    let index = leafIndex
                    leafIndex += 1
                    let action = UIAction(
                        title: item.title,
                        image: SystemMenuButton.menuImage(item),
                        attributes: item.isDestructive ? .destructive : []
                    ) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.flat[safe: index]?.action()
                        }
                    }
                    action.state = item.isChecked ? .on : .off
                    return action
                }
            }
            return elements(items)
        }
    }
}

/// 竖屏选集 / 评论页用的原生 SwiftUI 菜单。
///
/// 播放器控制层仍走上面的 UIKit 菜单，避免播放中视图刷新导致菜单动作失效；
/// 这两个页面不属于控制层，恢复 SwiftUI `Menu` 后更贴近系统交互。
struct SwiftSelectionMenuButton: View {
    var selection: SystemMenuButton.Selection
    var title: String
    var accessibilityLabel: String
    var tint: Color = .accentColor
    var showsChevron = true
    var capsule = true

    var body: some View {
        Menu {
            ForEach(Array(selection.options.enumerated()), id: \.offset) { _, option in
                Button {
                    option.action()
                } label: {
                    if option.isSelected {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, capsule ? 12 : 0)
            .frame(height: capsule ? 32 : nil)
            .background {
                if capsule {
                    Capsule(style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                }
            }
            .frame(height: capsule ? 44 : nil)
            .contentShape(Rectangle())
        }
        .tint(tint)
        .accessibilityLabel(accessibilityLabel)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
