import SwiftUI

// Traditional looks for the talking pill bear (head grid: centre (16, 18.5), radius 11.5).
// Only `drawTalkingBear` passes a `SpokenLook`, so moments and voice tricks never wear these.
extension TeddyPalette {
    static let shemagh = Color(red: 0.80, green: 0.10, blue: 0.15)
    static let shemaghCheck = Color(red: 0.99, green: 0.97, blue: 0.95)
    static let igal = Color(red: 0.07, green: 0.06, blue: 0.07)
    static let igalShine = Color(red: 0.40, green: 0.39, blue: 0.42)
    static let thobe = Color(red: 0.97, green: 0.97, blue: 0.96)
    static let thobeShade = Color(red: 0.83, green: 0.84, blue: 0.86)

    static let safa = Color(red: 0.97, green: 0.55, blue: 0.11)
    static let safaFold = Color(red: 0.82, green: 0.36, blue: 0.05)
    static let safaShine = Color(red: 1.0, green: 0.74, blue: 0.32)
    static let ruby = Color(red: 0.78, green: 0.08, blue: 0.20)
    static let plume = Color(red: 0.99, green: 0.96, blue: 0.88)
    static let kurta = Color(red: 0.97, green: 0.92, blue: 0.80)
    static let kurtaShade = Color(red: 0.84, green: 0.76, blue: 0.60)
}

extension TeddyArt {
    /// Sleeve and cuff colours of the paw holding the mic or pencil.
    static func sleeveColors(outfit: TeddyOutfit, look: SpokenLook) -> (sleeve: Color, cuff: Color) {
        switch look {
        case .shemagh: return (TeddyPalette.thobe, TeddyPalette.thobeShade)
        case .turban: return (TeddyPalette.kurta, TeddyPalette.kurtaShade)
        case .none:
            return outfit == .suit
                ? (TeddyPalette.suit, TeddyPalette.shirt)
                : (TeddyPalette.hoodie, TeddyPalette.hoodieDark)
        }
    }

    /// The pill bear's head and neckline in a traditional look. `.none` draws nothing.
    static func drawSpokenLookHead(in graphics: inout GraphicsContext, face: TeddyFace, look: SpokenLook) {
        switch look {
        case .none:
            return
        case .shemagh:
            drawShemaghHead(in: &graphics, face: face)
        case .turban:
            drawTurbanHead(in: &graphics, face: face)
        }
    }

    // MARK: Shemagh and igal

    private static func drawShemaghHead(in graphics: inout GraphicsContext, face: TeddyFace) {
        drawNecklineShoulders(in: &graphics, color: TeddyPalette.thobe)
        // The cloth behind the head, hanging down over both shoulders.
        let drape = shemaghDrapePath()
        fill(&graphics, drape, TeddyPalette.shemagh)
        drawShemaghChecks(in: &graphics, clip: drape)
        graphics.stroke(drape, with: .color(TeddyPalette.ink), style: StrokeStyle(lineWidth: outline, lineJoin: .round))

        drawFurDisc(in: &graphics)
        drawFace(in: &graphics, face)

        // The cloth wrapped round the face: the head disc with an oval opening for the face.
        let opening = Path(ellipseIn: CGRect(x: 6.1, y: 10.0, width: 19.8, height: 20.6))
        var frame = circle(headCenter, 11.5 + outline)
        frame.addPath(opening)
        let evenOdd = FillStyle(eoFill: true)
        graphics.fill(frame, with: .color(TeddyPalette.shemagh), style: evenOdd)
        var framed = graphics
        framed.clip(to: frame, style: evenOdd)
        drawShemaghChecks(in: &framed, clip: circle(headCenter, 11.5 + outline))
        graphics.stroke(opening, with: .color(TeddyPalette.shemaghCheck), lineWidth: 0.55)
        graphics.stroke(
            Path(ellipseIn: CGRect(x: 6.4, y: 10.3, width: 19.2, height: 20.0)),
            with: .color(TeddyPalette.ink), lineWidth: 0.8
        )

        drawIgal(in: &graphics)
        drawThobeCollar(in: &graphics)
    }

    /// Crown over the head plus two panels falling to the shoulders, one outline.
    private static func shemaghDrapePath() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 16, y: 2.4))
        path.addCurve(to: CGPoint(x: 29.4, y: 16.5), control1: CGPoint(x: 24.6, y: 2.4), control2: CGPoint(x: 29.4, y: 8.4))
        path.addLine(to: CGPoint(x: 30.0, y: 33.8))
        path.addLine(to: CGPoint(x: 22.4, y: 33.8))
        path.addLine(to: CGPoint(x: 21.6, y: 28.2))
        path.addQuadCurve(to: CGPoint(x: 10.4, y: 28.2), control: CGPoint(x: 16, y: 31.4))
        path.addLine(to: CGPoint(x: 9.6, y: 33.8))
        path.addLine(to: CGPoint(x: 2.0, y: 33.8))
        path.addLine(to: CGPoint(x: 2.6, y: 16.5))
        path.addCurve(to: CGPoint(x: 16, y: 2.4), control1: CGPoint(x: 2.6, y: 8.4), control2: CGPoint(x: 7.4, y: 2.4))
        path.closeSubpath()
        return path
    }

    /// The red-and-white weave: small white diamonds on a staggered grid.
    private static func drawShemaghChecks(in graphics: inout GraphicsContext, clip: Path) {
        var checks = graphics
        checks.clip(to: clip)
        let step: CGFloat = 2.5
        let half: CGFloat = 0.62
        var diamonds = Path()
        for row in 0..<15 {
            for column in 0..<14 {
                let x = 1.0 + CGFloat(column) * step + (row % 2 == 0 ? 0 : step / 2)
                let y = 1.0 + CGFloat(row) * step * 0.9
                diamonds.move(to: CGPoint(x: x, y: y - half))
                diamonds.addLine(to: CGPoint(x: x + half, y: y))
                diamonds.addLine(to: CGPoint(x: x, y: y + half))
                diamonds.addLine(to: CGPoint(x: x - half, y: y))
                diamonds.closeSubpath()
            }
        }
        checks.fill(diamonds, with: .color(TeddyPalette.shemaghCheck.opacity(0.9)))
    }

    /// The black igal: two thick cord rings resting on the crown, each with a soft shine.
    private static func drawIgal(in graphics: inout GraphicsContext) {
        for top in [2.9, 4.6] as [CGFloat] {
            let ring = Path(ellipseIn: CGRect(x: 6.6, y: top, width: 18.8, height: 4.4))
            graphics.stroke(ring, with: .color(TeddyPalette.ink), lineWidth: 2.2)
            graphics.stroke(ring, with: .color(TeddyPalette.igal), lineWidth: 1.5)
            graphics.stroke(
                ring.trimmedPath(from: 0.58, to: 0.7),
                with: .color(TeddyPalette.igalShine),
                style: StrokeStyle(lineWidth: 0.5, lineCap: .round)
            )
        }
    }

    /// A white band collar with the placket and one button, under the chin.
    private static func drawThobeCollar(in graphics: inout GraphicsContext) {
        let collar = Path(roundedRect: CGRect(x: 12.4, y: 28.9, width: 7.2, height: 2.2), cornerRadius: 1.0)
        sticker(&graphics, collar, TeddyPalette.thobe, rim: 0.7)
        var placket = Path()
        placket.move(to: CGPoint(x: 16, y: 31.3))
        placket.addLine(to: CGPoint(x: 16, y: 33.8))
        stroke(&graphics, placket, TeddyPalette.thobeShade, width: 0.7)
        sticker(&graphics, circle(CGPoint(x: 16, y: 32.4), 0.45), TeddyPalette.thobeShade, rim: 0.3)
    }

    // MARK: Safa turban

    private static func drawTurbanHead(in graphics: inout GraphicsContext, face: TeddyFace) {
        drawNecklineShoulders(in: &graphics, color: TeddyPalette.kurta)
        drawFurDisc(in: &graphics)
        drawFace(in: &graphics, face)

        let turban = turbanPath()
        fill(&graphics, turban, TeddyPalette.safa)
        // Wrapped folds running diagonally across the turban, each with a lit edge.
        var folds = graphics
        folds.clip(to: turban)
        var lit = folds
        lit.translateBy(x: 1.3, y: 0)
        for index in 0..<5 {
            let offset = CGFloat(index) * 5.2
            var fold = Path()
            fold.move(to: CGPoint(x: -1.6 + offset, y: 14.4))
            fold.addQuadCurve(to: CGPoint(x: 8.8 + offset, y: -0.4), control: CGPoint(x: 1.4 + offset, y: 5.2))
            stroke(&folds, fold, TeddyPalette.safaFold, width: 1.1)
            stroke(&lit, fold, TeddyPalette.safaShine.opacity(0.7), width: 0.6)
        }
        graphics.stroke(turban, with: .color(TeddyPalette.ink), style: StrokeStyle(lineWidth: outline, lineJoin: .round))

        drawPlume(in: &graphics)
        // Brooch: a gold setting with a ruby, where the folds meet at the front.
        sticker(&graphics, circle(CGPoint(x: 16, y: 7.6), 1.35), TeddyPalette.gold, rim: 0.55)
        fill(&graphics, circle(CGPoint(x: 16, y: 7.6), 0.6), TeddyPalette.ruby)
        drawKurtaCollar(in: &graphics)
    }

    /// A puffy turban wider than the head, sitting low with a soft point over the forehead.
    private static func turbanPath() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 3.6, y: 13.6))
        path.addCurve(to: CGPoint(x: 16, y: 1.6), control1: CGPoint(x: 2.0, y: 6.4), control2: CGPoint(x: 8.0, y: 1.6))
        path.addCurve(to: CGPoint(x: 28.4, y: 13.6), control1: CGPoint(x: 24.0, y: 1.6), control2: CGPoint(x: 30.0, y: 6.4))
        path.addQuadCurve(to: CGPoint(x: 16, y: 10.4), control: CGPoint(x: 22.6, y: 10.4))
        path.addQuadCurve(to: CGPoint(x: 3.6, y: 13.6), control: CGPoint(x: 9.4, y: 10.4))
        path.closeSubpath()
        return path
    }

    /// The kalgi: a small cream plume rising from the brooch.
    private static func drawPlume(in graphics: inout GraphicsContext) {
        var plume = Path()
        plume.move(to: CGPoint(x: 16.2, y: 6.8))
        plume.addQuadCurve(to: CGPoint(x: 19.2, y: 1.4), control: CGPoint(x: 15.6, y: 3.0))
        plume.addQuadCurve(to: CGPoint(x: 16.2, y: 6.8), control: CGPoint(x: 19.4, y: 4.6))
        plume.closeSubpath()
        sticker(&graphics, plume, TeddyPalette.plume, rim: 0.6)
    }

    /// A cream kurta's mandarin collar with a placket and two gold buttons.
    private static func drawKurtaCollar(in graphics: inout GraphicsContext) {
        for originX in [12.2, 16.1] as [CGFloat] {
            let band = Path(roundedRect: CGRect(x: originX, y: 28.8, width: 3.7, height: 2.0), cornerRadius: 0.9)
            sticker(&graphics, band, TeddyPalette.kurta, rim: 0.65)
        }
        var placket = Path()
        placket.move(to: CGPoint(x: 16, y: 30.8))
        placket.addLine(to: CGPoint(x: 16, y: 33.8))
        stroke(&graphics, placket, TeddyPalette.kurtaShade, width: 0.8)
        for y in [31.7, 33.2] as [CGFloat] {
            sticker(&graphics, circle(CGPoint(x: 16, y: y), 0.42), TeddyPalette.gold, rim: 0.3)
        }
    }

    // MARK: Shared

    /// Shoulders behind the chin, the same cut as the suit jacket's.
    private static func drawNecklineShoulders(in graphics: inout GraphicsContext, color: Color) {
        var shoulders = Path()
        shoulders.move(to: CGPoint(x: 3.6, y: 33))
        shoulders.addQuadCurve(to: CGPoint(x: 9.6, y: 28.6), control: CGPoint(x: 4.8, y: 29.4))
        shoulders.addLine(to: CGPoint(x: 22.4, y: 28.6))
        shoulders.addQuadCurve(to: CGPoint(x: 28.4, y: 33), control: CGPoint(x: 27.2, y: 29.4))
        shoulders.closeSubpath()
        sticker(&graphics, shoulders, color)
    }
}
