// Draws the disk image window background (640x400 points) at 1x and 2x.
// package.sh places the app icon at (160, 190) and Applications at (480, 190).
import SwiftUI

private func hex(_ v: UInt32) -> Color {
    Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

struct DMGBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [hex(0x1A2030), hex(0x0B0E14)], startPoint: .top, endPoint: .bottom)

            VStack(spacing: 6) {
                Text("Agent Usage")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [hex(0x3BE38B), hex(0x3D8BFF), hex(0xC24DFF), hex(0xFF2E7E)],
                                                    startPoint: .leading, endPoint: .trailing))
                Text("Drag the app onto Applications to install")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .position(x: 320, y: 58)

            // Arrow between the two icons (icon centres at x 160 and 480, y 190).
            HStack(spacing: 0) {
                Capsule()
                    .fill(LinearGradient(colors: [hex(0x3D8BFF), hex(0xFF2E7E)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 104, height: 8)
                Triangle()
                    .fill(hex(0xFF2E7E))
                    .frame(width: 22, height: 26)
                    .offset(x: -4)
            }
            .shadow(color: hex(0xFF2E7E).opacity(0.5), radius: 10)
            .position(x: 322, y: 190)

            Text("First launch: right-click the app and choose Open.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .position(x: 320, y: 368)
        }
        .frame(width: 640, height: 400)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

@main
enum DrawBackground {
    @MainActor static func main() {
        let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        for (scale, name) in [(1.0, "bg.png"), (2.0, "bg@2x.png")] {
            let r = ImageRenderer(content: DMGBackground())
            r.scale = scale
            guard let cg = r.cgImage else { fatalError("render failed") }
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: 640, height: 400) // 72 dpi at 1x, 144 dpi at 2x
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "/" + name))
        }
    }
}
