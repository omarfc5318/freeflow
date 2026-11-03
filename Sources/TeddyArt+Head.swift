import SwiftUI

/// Everything about the face that can change from pose to pose.
struct TeddyFace: Equatable {
    enum Eyes: Equatable {
        case normal
        case wide
        case happy
    }

    enum Mouth: Equatable {
        case natural
        case grin
        case oh
        case flat
    }

    var mouthOpen: CGFloat = 0
    var isBlinking = false
    var isThinking = false
    /// Closes the viewer's-left eye.
    var winks = false
    var eyes: Eyes = .normal
    var mouth: Mouth = .natural
    var raisedBrows = false
    /// Small round glasses (edit mode).
    var glasses = false
    /// Both eyes shut in a gentle curve (asleep).
    var eyesClosed = false
    /// Lifts both ears (positive is up, in grid points): ears pricked.
    var earLift: CGFloat = 0
    /// Angry brows and a frown.
    var grumpy = false
}

extension TeddyFace.Eyes {
    init(_ style: TeddyBodyPose.Face.Eyes) {
        switch style {
        case .normal: self = .normal
        case .wide: self = .wide
        case .happy: self = .happy
        }
    }
}

extension TeddyFace.Mouth {
    init(_ style: TeddyBodyPose.Face.Mouth) {
        switch style {
        case .natural: self = .natural
        case .grin: self = .grin
        case .oh: self = .oh
        case .flat: self = .flat
        }
    }
}

// The head is shared by the pill bear and the full-body teddy, so the face matches everywhere.
extension TeddyArt {
    static let headCenter = CGPoint(x: 16, y: 18.5)
    static let earCenters = [CGPoint(x: 7.5, y: 8), CGPoint(x: 24.5, y: 8)]
    static let eyeXs: [CGFloat] = [11.8, 20.2]

    /// Drawn on a grid where the head's centre is (16, 18.5) and the ears reach y = 3.
    /// `neckwear` adds the part of the outfit under the chin (drawstrings, collar and tie),
    /// which the pill bear needs and the full-body teddy draws on its own torso instead.
    static func drawHead(
        in graphics: inout GraphicsContext,
        face: TeddyFace,
        outfit: TeddyOutfit,
        partyHat: Bool = false,
        neckwear: Bool = false,
        faceShift: CGFloat = 0,
        look: SpokenLook = .none
    ) {
        if look != .none {
            drawSpokenLookHead(in: &graphics, face: face, look: look)
            return
        }
        if neckwear && outfit == .suit { drawJacketShoulders(in: &graphics) }
        switch outfit {
        case .hoodie:
            sticker(&graphics, Path(ellipseIn: CGRect(x: 2.9, y: 5.5, width: 26.2, height: 25.5)), TeddyPalette.hoodie, rim: 1.2)
            drawFurDisc(in: &graphics)
            drawEars(in: &graphics, innerEars: true, clipsInsideHood: true, lift: face.earLift)
        case .suit:
            drawEars(in: &graphics, innerEars: true, clipsInsideHood: false, lift: face.earLift)
            drawFurDisc(in: &graphics)
        }
        if faceShift == 0 {
            drawFace(in: &graphics, face)
        } else {
            // Head turn: the features slide sideways and squash a touch, like looking round.
            var features = graphics
            features.translateBy(x: headCenter.x + faceShift, y: 0)
            features.scaleBy(x: 1 - abs(faceShift) * 0.03, y: 1)
            features.translateBy(x: -headCenter.x, y: 0)
            drawFace(in: &features, face)
        }
        switch outfit {
        case .hoodie:
            drawHoodLip(in: &graphics)
            if neckwear { drawDrawstrings(in: &graphics) }
        case .suit:
            if !partyHat { drawFlatCap(in: &graphics) }
        }
        if partyHat { drawPartyHat(in: &graphics) }
        if neckwear && outfit == .suit { drawCollarAndTie(in: &graphics) }
    }

    /// The back of the head: hood up, or the back of the flat cap.
    static func drawHeadBack(in graphics: inout GraphicsContext, outfit: TeddyOutfit) {
        switch outfit {
        case .hoodie:
            drawEars(in: &graphics, innerEars: false, clipsInsideHood: false)
            let hood = Path(ellipseIn: CGRect(x: 3.0, y: 6.4, width: 26, height: 25.2))
            sticker(&graphics, hood, TeddyPalette.hoodie, rim: 1.2)
            var fold = graphics
            fold.clip(to: hood)
            fold.fill(Path(ellipseIn: CGRect(x: 5, y: 26.2, width: 22, height: 8)), with: .color(TeddyPalette.hoodieDark))
            graphics.stroke(hood, with: .color(TeddyPalette.ink), lineWidth: 1.2)
            var seam = Path()
            seam.move(to: CGPoint(x: 16, y: 8.2))
            seam.addQuadCurve(to: CGPoint(x: 16, y: 29.6), control: CGPoint(x: 17.4, y: 19))
            graphics.stroke(seam, with: .color(TeddyPalette.hoodieDark), style: StrokeStyle(lineWidth: 0.8, lineCap: .round, dash: [1.4, 1.2]))
        case .suit:
            drawEars(in: &graphics, innerEars: false, clipsInsideHood: false)
            drawFurDisc(in: &graphics)
            var cap = graphics
            cap.translateBy(x: 0, y: 3.6)
            var dome = Path()
            dome.move(to: CGPoint(x: 5.6, y: 12.6))
            dome.addCurve(to: CGPoint(x: 26.4, y: 12.6), control1: CGPoint(x: 4.6, y: 1.8), control2: CGPoint(x: 27.4, y: 1.8))
            dome.addQuadCurve(to: CGPoint(x: 5.6, y: 12.6), control: CGPoint(x: 16, y: 15.4))
            dome.closeSubpath()
            sticker(&cap, dome, TeddyPalette.tweed)
            drawTweedFlecks(in: &cap, clip: dome)
            var band = Path()
            band.move(to: CGPoint(x: 5.9, y: 11.4))
            band.addQuadCurve(to: CGPoint(x: 26.1, y: 11.4), control: CGPoint(x: 16, y: 14.2))
            cap.stroke(band, with: .color(TeddyPalette.tweedDark), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            sticker(&cap, circle(CGPoint(x: 16, y: 4.2), 0.9), TeddyPalette.tweedDark, rim: 0.7)
        }
    }

    // MARK: Fur

    static func drawFurDisc(in graphics: inout GraphicsContext) {
        fill(&graphics, circle(headCenter, 11.5 + outline), TeddyPalette.ink)
        fill(&graphics, circle(headCenter, 11.5), TeddyPalette.fur)
    }

    /// Ears behind the head. With the hood up they are clipped to the part outside the hood
    /// opening, so they poke out around it.
    static func drawEars(in graphics: inout GraphicsContext, innerEars: Bool, clipsInsideHood: Bool, lift: CGFloat = 0) {
        var ears = graphics
        if clipsInsideHood {
            var mask = Path(CGRect(x: -20, y: -20, width: 90, height: 90))
            mask.addPath(circle(headCenter, 11.7))
            ears.clip(to: mask, style: FillStyle(eoFill: true))
        }
        for base in earCenters {
            let center = CGPoint(x: base.x + (base.x < 16 ? -lift * 0.25 : lift * 0.25), y: base.y - lift)
            fill(&ears, circle(center, 5 + outline), TeddyPalette.ink)
            fill(&ears, circle(center, 5), TeddyPalette.fur)
            if innerEars {
                let inner = CGPoint(x: center.x + (center.x < 16 ? 0.8 : -0.8), y: center.y + 0.8)
                fill(&ears, circle(inner, 2.4), TeddyPalette.tan)
            }
        }
    }

    // MARK: Face

    static func drawFace(in graphics: inout GraphicsContext, _ face: TeddyFace) {
        let gaze = face.isThinking ? CGSize(width: 0.9, height: -1.5) : .zero

        for x in [8.6, 23.4] as [CGFloat] {
            fill(&graphics, Path(ellipseIn: CGRect(x: x - 1.7, y: 20.4, width: 3.4, height: 2.2)), TeddyPalette.blush.opacity(0.65))
        }
        fill(&graphics, Path(ellipseIn: CGRect(x: 10.8, y: 18.6, width: 10.4, height: 7.8)), TeddyPalette.tan)

        for x in eyeXs { drawEye(in: &graphics, x: x, face: face, gaze: gaze) }
        if face.raisedBrows { drawBrows(in: &graphics) }
        if face.grumpy { drawGrumpyBrows(in: &graphics) }

        // Nose, with a little shine.
        fill(&graphics, Path(ellipseIn: CGRect(x: 13.9, y: 19.3, width: 4.2, height: 2.8)), TeddyPalette.ink)
        fill(&graphics, Path(ellipseIn: CGRect(x: 14.9, y: 19.7, width: 1.3, height: 0.7)), TeddyPalette.tan.opacity(0.8))
        drawMouth(in: &graphics, face)
        if face.glasses { drawGlasses(in: &graphics) }
    }

    private static func drawEye(in graphics: inout GraphicsContext, x: CGFloat, face: TeddyFace, gaze: CGSize) {
        let ink = TeddyPalette.ink
        if face.eyesClosed {
            // Asleep: a soft downward curve with a tiny lash tick.
            var lid = Path()
            lid.move(to: CGPoint(x: x - 1.9, y: 14.8))
            lid.addQuadCurve(to: CGPoint(x: x + 1.9, y: 14.8), control: CGPoint(x: x, y: 17.0))
            stroke(&graphics, lid, ink, width: 1.2)
            return
        }
        switch face.eyes {
        case .happy:
            var arc = Path()
            arc.move(to: CGPoint(x: x - 1.9, y: 16))
            arc.addQuadCurve(to: CGPoint(x: x + 1.9, y: 16), control: CGPoint(x: x, y: 12.8))
            stroke(&graphics, arc, ink, width: 1.2)
        case .wide:
            let center = CGPoint(x: x, y: 15)
            sticker(&graphics, circle(center, 2.5), .white, rim: 0.6)
            let pupil = CGPoint(x: x + gaze.width * 0.5, y: 15.2 + gaze.height * 0.4)
            fill(&graphics, circle(pupil, 1.25), ink)
            fill(&graphics, circle(CGPoint(x: pupil.x + 0.4, y: pupil.y - 0.4), 0.38), .white)
        case .normal:
            if face.winks && x < 16 {
                var lid = Path()
                lid.move(to: CGPoint(x: x - 1.8, y: 15.4))
                lid.addQuadCurve(to: CGPoint(x: x + 1.8, y: 15.4), control: CGPoint(x: x, y: 13.6))
                stroke(&graphics, lid, ink, width: 1.2)
                return
            }
            let height: CGFloat = face.isBlinking ? 0.5 : (face.grumpy ? 2.2 : 3.3)
            let eye = CGRect(x: x - 1.65 + gaze.width, y: 15 - height / 2 + gaze.height, width: 3.3, height: height)
            fill(&graphics, Path(ellipseIn: eye), ink)
            if !face.isBlinking {
                fill(&graphics, circle(CGPoint(x: x + 0.55 + gaze.width, y: 14.3 + gaze.height), 0.52), .white)
            }
        }
    }

    private static func drawBrows(in graphics: inout GraphicsContext) {
        for x in eyeXs {
            var brow = Path()
            brow.move(to: CGPoint(x: x - 1.6, y: 11.9))
            brow.addQuadCurve(to: CGPoint(x: x + 1.6, y: 11.9), control: CGPoint(x: x, y: 10.3))
            stroke(&graphics, brow, TeddyPalette.ink, width: 1.0)
        }
    }

    /// Slanted brows, inner ends low, over narrowed eyes.
    private static func drawGrumpyBrows(in graphics: inout GraphicsContext) {
        for (x, inward) in [(eyeXs[0], 1.0), (eyeXs[1], -1.0)] as [(CGFloat, CGFloat)] {
            var brow = Path()
            brow.move(to: CGPoint(x: x - inward * 2.2, y: 11.4))
            brow.addLine(to: CGPoint(x: x + inward * 2.0, y: 13.3))
            stroke(&graphics, brow, TeddyPalette.ink, width: 1.5)
        }
    }

    private static func drawMouth(in graphics: inout GraphicsContext, _ face: TeddyFace) {
        let ink = TeddyPalette.ink
        if face.grumpy {
            var frown = Path()
            frown.move(to: CGPoint(x: 14.0, y: 24.4))
            frown.addQuadCurve(to: CGPoint(x: 18.0, y: 24.4), control: CGPoint(x: 16, y: 22.6))
            stroke(&graphics, frown, ink, width: 0.9)
            return
        }
        switch face.mouth {
        case .grin:
            var grin = Path()
            grin.move(to: CGPoint(x: 12.4, y: 22.6))
            grin.addLine(to: CGPoint(x: 19.6, y: 22.6))
            grin.addQuadCurve(to: CGPoint(x: 12.4, y: 22.6), control: CGPoint(x: 16, y: 29.4))
            fill(&graphics, grin, ink)
            var inside = graphics
            inside.clip(to: grin)
            fill(&inside, Path(ellipseIn: CGRect(x: 13.4, y: 24.2, width: 5.2, height: 3.4)), TeddyPalette.tongue)
        case .oh:
            fill(&graphics, Path(ellipseIn: CGRect(x: 14.8, y: 22.5, width: 2.4, height: 2.8)), ink)
        case .flat:
            var line = Path()
            line.move(to: CGPoint(x: 14.4, y: 23.6))
            line.addLine(to: CGPoint(x: 17.6, y: 23.2))
            stroke(&graphics, line, ink, width: 0.9)
        case .natural:
            if face.mouthOpen > 0.05 {
                let open = face.mouthOpen
                let width = 2.6 + 2.2 * open
                let height = 0.9 + 2.6 * open
                let mouth = Path(ellipseIn: CGRect(x: 16 - width / 2, y: 22.6, width: width, height: height))
                fill(&graphics, mouth, ink)
                if height > 1.8 {
                    var inside = graphics
                    inside.clip(to: mouth)
                    fill(&inside, Path(ellipseIn: CGRect(x: 16 - width * 0.3, y: 22.6 + height * 0.55, width: width * 0.6, height: height * 0.7)), TeddyPalette.tongue)
                }
            } else {
                var philtrum = Path()
                philtrum.move(to: CGPoint(x: 16, y: 22.0))
                philtrum.addLine(to: CGPoint(x: 16, y: 23.2))
                stroke(&graphics, philtrum, ink, width: 0.7)
                var smile = Path()
                let thinking = face.isThinking
                smile.move(to: CGPoint(x: thinking ? 15 : 14.2, y: 23.3))
                smile.addQuadCurve(
                    to: CGPoint(x: thinking ? 17.4 : 17.8, y: 23.3),
                    control: CGPoint(x: 16, y: thinking ? 23.3 : 24.7)
                )
                stroke(&graphics, smile, ink, width: 0.9)
            }
        }
    }

    private static func drawGlasses(in graphics: inout GraphicsContext) {
        let ink = TeddyPalette.ink
        var temples = Path()
        temples.move(to: CGPoint(x: 8.8, y: 14.7))
        temples.addLine(to: CGPoint(x: 5.0, y: 13.9))
        temples.move(to: CGPoint(x: 23.2, y: 14.7))
        temples.addLine(to: CGPoint(x: 27.0, y: 13.9))
        stroke(&graphics, temples, ink, width: 0.9)
        for x in eyeXs {
            let lens = circle(CGPoint(x: x, y: 15.1), 3.0)
            fill(&graphics, lens, Color(red: 0.85, green: 0.94, blue: 1.0).opacity(0.3))
            graphics.stroke(lens, with: .color(ink), lineWidth: 1.0)
        }
        var bridge = Path()
        bridge.move(to: CGPoint(x: 14.7, y: 14.6))
        bridge.addQuadCurve(to: CGPoint(x: 17.3, y: 14.6), control: CGPoint(x: 16, y: 13.5))
        stroke(&graphics, bridge, ink, width: 0.9)
    }

    // MARK: Hoodie

    /// The hood's opening: a purple ring around the face with the ears poking out of it.
    static func drawHoodLip(in graphics: inout GraphicsContext) {
        let ring = circle(headCenter, 11.6)
        graphics.stroke(ring, with: .color(TeddyPalette.hoodie), lineWidth: 2.4)
        graphics.stroke(circle(headCenter, 10.8), with: .color(TeddyPalette.hoodieDark), lineWidth: 0.9)
        graphics.stroke(circle(headCenter, 10.3), with: .color(TeddyPalette.ink), lineWidth: 0.85)
    }

    /// Two cords hanging under the chin, for the head-only pill bear.
    static func drawDrawstrings(in graphics: inout GraphicsContext) {
        for (top, bottom) in [(CGPoint(x: 12.6, y: 29.0), CGPoint(x: 12.0, y: 31.0)), (CGPoint(x: 19.4, y: 29.0), CGPoint(x: 20.0, y: 31.0))] {
            var cord = Path()
            cord.move(to: top)
            cord.addLine(to: bottom)
            stroke(&graphics, cord, TeddyPalette.ink, width: 1.9)
            stroke(&graphics, cord, TeddyPalette.cord, width: 0.7)
            sticker(&graphics, circle(bottom, 0.7), TeddyPalette.cord, rim: 0.45)
        }
    }

    // MARK: Suit

    /// Jacket shoulders behind the pill bear's chin.
    static func drawJacketShoulders(in graphics: inout GraphicsContext) {
        var shoulders = Path()
        shoulders.move(to: CGPoint(x: 3.6, y: 33))
        shoulders.addQuadCurve(to: CGPoint(x: 9.6, y: 28.6), control: CGPoint(x: 4.8, y: 29.4))
        shoulders.addLine(to: CGPoint(x: 22.4, y: 28.6))
        shoulders.addQuadCurve(to: CGPoint(x: 28.4, y: 33), control: CGPoint(x: 27.2, y: 29.4))
        shoulders.closeSubpath()
        sticker(&graphics, shoulders, TeddyPalette.suit)
    }

    /// White collar points and a dark tie knot tucked under the chin.
    static func drawCollarAndTie(in graphics: inout GraphicsContext) {
        var vee = Path()
        vee.move(to: CGPoint(x: 11.6, y: 28.7))
        vee.addLine(to: CGPoint(x: 20.4, y: 28.7))
        vee.addLine(to: CGPoint(x: 16, y: 33))
        vee.closeSubpath()
        sticker(&graphics, vee, TeddyPalette.shirt, rim: 0.7)
        for sign in [-1.0, 1.0] as [CGFloat] {
            var collar = Path()
            collar.move(to: CGPoint(x: 16 + sign * 0.6, y: 29.4))
            collar.addLine(to: CGPoint(x: 16 + sign * 4.6, y: 28.6))
            collar.addLine(to: CGPoint(x: 16 + sign * 2.6, y: 31.8))
            collar.closeSubpath()
            sticker(&graphics, collar, TeddyPalette.shirt, rim: 0.6)
        }
        var blade = Path()
        blade.move(to: CGPoint(x: 15.3, y: 30.5))
        blade.addLine(to: CGPoint(x: 16.7, y: 30.5))
        blade.addLine(to: CGPoint(x: 17.1, y: 32.2))
        blade.addLine(to: CGPoint(x: 14.9, y: 32.2))
        blade.closeSubpath()
        sticker(&graphics, blade, TeddyPalette.tie, rim: 0.5)
        sticker(&graphics, Path(ellipseIn: CGRect(x: 14.9, y: 29.2, width: 2.2, height: 1.8)), TeddyPalette.tie, rim: 0.5)
    }

    /// A tweed newsboy cap: puffy dome, button on top, small peak at the front.
    static func drawFlatCap(in graphics: inout GraphicsContext) {
        var cap = graphics
        cap.translateBy(x: 0, y: -1.1)
        var dome = Path()
        dome.move(to: CGPoint(x: 8.0, y: 12.6))
        dome.addCurve(to: CGPoint(x: 25.0, y: 12.2), control1: CGPoint(x: 7.2, y: 3.0), control2: CGPoint(x: 25.2, y: 2.6))
        dome.addQuadCurve(to: CGPoint(x: 8.0, y: 12.6), control: CGPoint(x: 16.6, y: 14.4))
        dome.closeSubpath()
        sticker(&cap, dome, TeddyPalette.tweed)
        drawTweedFlecks(in: &cap, clip: dome)
        var seams = Path()
        seams.move(to: CGPoint(x: 16.6, y: 5.6))
        seams.addQuadCurve(to: CGPoint(x: 11.4, y: 12.6), control: CGPoint(x: 12.6, y: 8.2))
        seams.move(to: CGPoint(x: 16.6, y: 5.6))
        seams.addQuadCurve(to: CGPoint(x: 21.8, y: 12.4), control: CGPoint(x: 20.6, y: 8.2))
        var clipped = cap
        clipped.clip(to: dome)
        clipped.stroke(seams, with: .color(TeddyPalette.tweedDark), style: StrokeStyle(lineWidth: 0.6, lineCap: .round))
        var peak = Path()
        peak.move(to: CGPoint(x: 9.2, y: 12.2))
        peak.addQuadCurve(to: CGPoint(x: 24.0, y: 11.9), control: CGPoint(x: 16.8, y: 14.2))
        peak.addQuadCurve(to: CGPoint(x: 9.2, y: 12.2), control: CGPoint(x: 16.8, y: 11.9))
        sticker(&cap, peak, TeddyPalette.tweedDark, rim: 0.8)
        sticker(&cap, circle(CGPoint(x: 16.6, y: 5.4), 0.95), TeddyPalette.tweedDark, rim: 0.7)
    }

    static func drawTweedFlecks(in graphics: inout GraphicsContext, clip: Path) {
        var flecks = graphics
        flecks.clip(to: clip)
        for row in 0..<7 {
            for column in 0..<11 {
                let x = 4.5 + CGFloat(column) * 2.3 + (row % 2 == 0 ? 0 : 1.15)
                let y = 3.0 + CGFloat(row) * 2.0
                let color = (row + column) % 3 == 0 ? TeddyPalette.tweedDark : Color(red: 0.62, green: 0.58, blue: 0.52)
                flecks.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 0.7, height: 0.45)), with: .color(color))
            }
        }
    }

    // MARK: Party hat

    static func drawPartyHat(in graphics: inout GraphicsContext) {
        var cone = Path()
        cone.move(to: CGPoint(x: 10.0, y: 8.2))
        cone.addLine(to: CGPoint(x: 18.8, y: 1.6))
        cone.addLine(to: CGPoint(x: 22.8, y: 7.6))
        cone.closeSubpath()
        sticker(&graphics, cone, Color(red: 0.96, green: 0.38, blue: 0.56))
        var stripes = graphics
        stripes.clip(to: cone)
        var bands = Path()
        for offset in [0.0, 2.6, 5.2] as [CGFloat] {
            bands.move(to: CGPoint(x: 8 + offset, y: 9.2))
            bands.addLine(to: CGPoint(x: 15 + offset, y: 2))
        }
        stripes.stroke(bands, with: .color(Color(red: 1.0, green: 0.85, blue: 0.25)), lineWidth: 1.1)
        var rim = Path()
        rim.move(to: CGPoint(x: 9.4, y: 8.3))
        rim.addLine(to: CGPoint(x: 23.2, y: 7.7))
        stroke(&graphics, rim, TeddyPalette.ink, width: 2.6)
        stroke(&graphics, rim, Color(red: 1.0, green: 0.85, blue: 0.25), width: 1.1)
        sticker(&graphics, circle(CGPoint(x: 18.8, y: 1.9), 1.2), .white, rim: 0.7)
    }
}
