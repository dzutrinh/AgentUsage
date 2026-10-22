// Draws the app icon ("Dark glass": four tinted glass bars in the agents' colours
// on a softly lit dark slab, Liquid Glass style) as a 1024x1024 PNG.
// Run through Design/make_icon.sh, which builds AppIcon.icns.
import SwiftUI

private func hex(_ v: UInt32, _ a: Double = 1) -> Color {
    Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255,
          blue: Double(v & 0xFF) / 255).opacity(a)
}

// Same stops as Agent.gradientColors in Sources/Model.swift: (start, end, height).
private let bars: [(UInt32, UInt32, CGFloat)] = [
    (0x3BE38B, 0x00B3C7, 0.38), // Codex
    (0x3D8BFF, 0x8A4DFF, 0.58), // Gemini
    (0xC24DFF, 0xFF4FD8, 0.46), // Copilot
    (0xFF7A3D, 0xFF2E7E, 0.86), // Claude
]

private func squircle() -> RoundedRectangle { RoundedRectangle(cornerRadius: 185, style: .continuous) }

/// One glass bar: tinted body, inner glow, rim light and a specular streak.
private struct GlassBar: View {
    let a: UInt32, b: UInt32, h: CGFloat
    let w: CGFloat = 104

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: w / 2.4, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [hex(b, 0.55), hex(a, 0.80)], startPoint: .top, endPoint: .bottom))
            shape.fill(RadialGradient(colors: [hex(a, 0.9), .clear], center: .bottom, startRadius: 0, endRadius: h * 0.7))
                .blendMode(.screen)
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.1), .white.opacity(0.55)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 4)
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: w * 0.22, height: max(40, h * 0.45))
                .offset(x: -w * 0.22, y: -h * 0.22)
                .blur(radius: 2)
        }
        .frame(width: w, height: h)
        .shadow(color: hex(b, 0.55), radius: 28, y: 16)
    }
}

/// macOS icon grid: an 824-point body centred in a 1024 canvas.
struct AppIcon: View {
    var body: some View {
        ZStack {
            // Slab with soft coloured light behind the glass.
            ZStack {
                LinearGradient(colors: [hex(0x1C2244), hex(0x0A0D1A)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(hex(0x3D8BFF, 0.55)).frame(width: 520).offset(x: -230, y: -240).blur(radius: 110)
                Circle().fill(hex(0xFF2E7E, 0.45)).frame(width: 480).offset(x: 260, y: 220).blur(radius: 120)
                Circle().fill(hex(0x3BE38B, 0.35)).frame(width: 380).offset(x: -260, y: 300).blur(radius: 110)
            }
            .clipShape(squircle())

            HStack(alignment: .bottom, spacing: 40) {
                ForEach(bars.indices, id: \.self) { i in GlassBar(a: bars[i].0, b: bars[i].1, h: 520 * bars[i].2) }
            }
            .frame(height: 520, alignment: .bottom)
            .offset(y: 20)

            // Top sheen and rim of the glass slab.
            squircle().fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center))
            squircle().strokeBorder(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.15), .white.opacity(0.5)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 5)
            squircle().inset(by: 5).strokeBorder(Color.black.opacity(0.35), lineWidth: 2)
        }
        .frame(width: 824, height: 824)
        .compositingGroup()
        .shadow(color: .black.opacity(0.30), radius: 24, y: 14)
        .frame(width: 1024, height: 1024)
    }
}

@main
enum DrawIcon {
    @MainActor static func main() {
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
        let r = ImageRenderer(content: AppIcon())
        r.scale = 1
        guard let cg = r.cgImage else { fatalError("render failed") }
        let rep = NSBitmapImageRep(cgImage: cg)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("Wrote \(out) (\(cg.width)x\(cg.height))")
    }
}
