//
//  PlayerIconButton.swift
//  Kazumi
//
//  播放器 HUD 的图标按钮统一口径：排版字号驱动视觉大小，40×40 热区，
//  再按符号的「视觉重量」做光学补偿。不要用 .resizable() + 固定 frame
//  去拉 SF Symbols——长宽比不同会被拉变形，ellipsis / play.fill 尤其明显。
//

import SwiftUI

/// 光学补偿分类。
/// - standard：线性 / 常规符号，18pt Medium 原样。
/// - solid：实心块状符号，视觉重心偏大，缩一档。
/// - detailed：细长、带角标或复合符号，视觉显小，微放一档。
enum PlayerIconOptical: Equatable, Hashable {
    case standard
    case solid
    case detailed
}

/// 所有 SwiftUI 里的 SF Symbol 都走这里：18pt Medium + imageScale(.medium) 是基准，
/// 再用 scaleEffect 做光学补偿，而不是改 frame 或 resizable。
struct PlayerIconModifier: ViewModifier {
    var pointSize: CGFloat = 18
    var weight: Font.Weight = .medium
    var optical: PlayerIconOptical = .standard

    private var scale: CGFloat {
        switch optical {
        case .standard: 1
        case .solid: 0.9
        case .detailed: 1.05
        }
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: pointSize, weight: weight))
            .imageScale(.medium)
            .scaleEffect(scale)
    }
}

extension View {
    func playerIcon(
        pointSize: CGFloat = 18,
        weight: Font.Weight = .medium,
        optical: PlayerIconOptical = .standard
    ) -> some View {
        modifier(PlayerIconModifier(pointSize: pointSize, weight: weight, optical: optical))
    }
}

/// 统一的播放器图标按钮容器。
///
/// - 有 action 时生成 SwiftUI Button，沿用 PlayerPressStyle 的按压反馈；
/// - 没有 action 时只当容器用，用来包 SystemMenuButton 这类 UIViewRepresentable；
/// - 两种情况下外层热区都严格 40×40，内容在容器内居中。
struct PlayerIconButton<Content: View>: View {
    private let content: Content
    private let action: (() -> Void)?

    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action
        self.content = content()
    }

    init(@ViewBuilder content: () -> Content) {
        self.action = nil
        self.content = content()
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(PlayerPressStyle())
            } else {
                content
            }
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
    }
}
