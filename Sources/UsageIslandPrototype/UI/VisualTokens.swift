import SwiftUI

public enum UsageIslandTokens {
  public static let islandBackground = Color(nsColor: .black)
  public static let primaryText = Color.white.opacity(0.94)
  public static let secondaryText = Color.white.opacity(0.50)
  public static let divider = Color.white.opacity(0.12)
  public static let warning = Color(red: 0.96, green: 0.77, blue: 0.32)
  public static let critical = Color(red: 1.00, green: 0.40, blue: 0.40)
  public static let success = Color(red: 0.46, green: 0.84, blue: 0.60)

  public static let panelReveal = Animation.timingCurve(
    0.18,
    0.74,
    0.20,
    1.00,
    duration: 0.28
  )

  public static let contentReveal = Animation.timingCurve(
    0.20,
    0.80,
    0.22,
    1.00,
    duration: 0.16
  )

  public static let detailMotionDuration: TimeInterval = 0.20
  public static let bodyRevealDuration: TimeInterval = 0.22

  public static let detailMotion = Animation.timingCurve(
    0.24,
    0.80,
    0.28,
    1.00,
    duration: detailMotionDuration
  )

  public static func usageColor(for percent: Int) -> Color {
    if percent <= 10 { return critical }
    if percent <= 30 { return warning }
    return primaryText
  }
}
