// Renders the Usage Island app icon master (1024×1024 PNG).
// Usage: swift Scripts/render-app-icon.swift <output.png>
import AppKit
import SwiftUI

let canvas: CGFloat = 1024
let tileSize: CGFloat = 824   // macOS icon grid: 100 pt margin for the shadow
let tile = RoundedRectangle(cornerRadius: 185, style: .continuous)
let pillShape = UnevenRoundedRectangle(topLeadingRadius: 170, bottomLeadingRadius: 170, style: .continuous)

let mint = Color(red: 0.35, green: 0.85, blue: 0.62)
let teal = Color(red: 0.22, green: 0.72, blue: 0.88)

struct Icon: View {
    var body: some View {
        ZStack {
            // Wallpaper behind the glass.
            tile.fill(LinearGradient(colors: [Color(red: 0.24, green: 0.46, blue: 0.86), Color(red: 0.52, green: 0.28, blue: 0.66)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().fill(Color(red: 0.93, green: 0.52, blue: 0.4).opacity(0.85)).frame(width: 420).blur(radius: 70).offset(x: -210, y: 250)
            Circle().fill(Color(red: 0.4, green: 0.8, blue: 0.95).opacity(0.7)).frame(width: 360).blur(radius: 80).offset(x: 180, y: -260)
            tile.fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center))

            // The pill, attached to the right edge like in the app.
            pillShape
                .fill(.black.opacity(0.34))
                .overlay(pillShape.fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottom)))
                .overlay(pillShape.strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 5))
                .frame(width: 452, height: 600)
                .overlay {
                    VStack(spacing: 22) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.16), lineWidth: 40)
                            Circle().trim(from: 0, to: 0.71)
                                .stroke(AngularGradient(colors: [teal, mint], center: .center, startAngle: .degrees(0), endAngle: .degrees(256)),
                                        style: StrokeStyle(lineWidth: 40, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Circle().fill(.white.opacity(0.95)).frame(width: 46)
                        }
                        .frame(width: 244, height: 244)
                        Text("71%")
                            .font(.system(size: 118, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .offset(x: 14, y: 6)
                }
                .shadow(color: .black.opacity(0.28), radius: 30, x: -8, y: 16)
                .offset(x: 186)

            tile.strokeBorder(.white.opacity(0.16), lineWidth: 3)
        }
        .frame(width: tileSize, height: tileSize)
        .clipShape(tile)
        .shadow(color: .black.opacity(0.3), radius: 20, y: 12)
        .frame(width: canvas, height: canvas)
    }
}

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
// Scripts run their top-level code on the main thread.
let png: Data? = MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    return bitmap.representation(using: .png, properties: [:])
}
guard let png else {
    FileHandle.standardError.write(Data("Could not render the icon.\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
