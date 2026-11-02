import SwiftUI

// Torsos and shoes for the full-body teddy, in both outfits and both views (40 x 50 grid).
extension TeddyArt {
    /// Hoodie or jacket: rounded top, straight-ish hem at y = 37.
    static func torsoPath() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 20, y: 24.5))
        path.addCurve(to: CGPoint(x: 28.6, y: 31.8), control1: CGPoint(x: 25, y: 24.5), control2: CGPoint(x: 28.6, y: 27.6))
        path.addCurve(to: CGPoint(x: 27.2, y: 37.2), control1: CGPoint(x: 28.6, y: 34.2), control2: CGPoint(x: 28.2, y: 36))
        path.addQuadCurve(to: CGPoint(x: 12.8, y: 37.2), control: CGPoint(x: 20, y: 38.7))
        path.addCurve(to: CGPoint(x: 11.4, y: 31.8), control1: CGPoint(x: 11.8, y: 36), control2: CGPoint(x: 11.4, y: 34.2))
        path.addCurve(to: CGPoint(x: 20, y: 24.5), control1: CGPoint(x: 11.4, y: 27.6), control2: CGPoint(x: 15, y: 24.5))
        path.closeSubpath()
        return path
    }

    /// The jeans or trousers seat that the torso hangs over.
    static func seatPath() -> Path {
        Path(roundedRect: CGRect(x: 12.2, y: 35.4, width: 15.6, height: 6.6), cornerRadius: 3.2)
    }

    // MARK: Front

    static func drawFrontTorso(in graphics: inout GraphicsContext, outfit: TeddyOutfit) {
        switch outfit {
        case .hoodie: drawFrontHoodie(in: &graphics)
        case .suit: drawFrontSuit(in: &graphics)
        }
    }

    private static func drawFrontHoodie(in graphics: inout GraphicsContext) {
        sticker(&graphics, seatPath(), TeddyPalette.jeans)
        var fly = Path()
        fly.move(to: CGPoint(x: 20, y: 38.4))
        fly.addLine(to: CGPoint(x: 20, y: 41.6))
        graphics.stroke(fly, with: .color(TeddyPalette.jeansDark), style: StrokeStyle(lineWidth: 0.6, lineCap: .round, dash: [0.9, 0.7]))

        let torso = torsoPath()
        fill(&graphics, torso, TeddyPalette.hoodie)
        var inside = graphics
        inside.clip(to: torso)
        fill(&inside, Path(CGRect(x: 10, y: 35.2, width: 20, height: 5)), TeddyPalette.hoodieDark)
        // Kangaroo pocket.
        var pocket = Path()
        pocket.move(to: CGPoint(x: 14.4, y: 30.4))
        pocket.addLine(to: CGPoint(x: 25.6, y: 30.4))
        pocket.addLine(to: CGPoint(x: 26.6, y: 35.2))
        pocket.addLine(to: CGPoint(x: 13.4, y: 35.2))
        pocket.closeSubpath()
        fill(&inside, pocket, TeddyPalette.hoodiePocket)
        inside.stroke(pocket, with: .color(TeddyPalette.hoodieDark), style: StrokeStyle(lineWidth: 0.7, lineJoin: .round))
        var openings = Path()
        openings.move(to: CGPoint(x: 14.9, y: 31.0))
        openings.addLine(to: CGPoint(x: 15.9, y: 34.2))
        openings.move(to: CGPoint(x: 25.1, y: 31.0))
        openings.addLine(to: CGPoint(x: 24.1, y: 34.2))
        stroke(&inside, openings, TeddyPalette.hoodieDark, width: 0.6)
        // Drawstrings.
        for (x, bottom) in [(17.4, 17.0), (22.6, 23.0)] as [(CGFloat, CGFloat)] {
            var cord = Path()
            cord.move(to: CGPoint(x: x, y: 25))
            cord.addLine(to: CGPoint(x: bottom, y: 30.4))
            stroke(&inside, cord, TeddyPalette.ink, width: 1.9)
            stroke(&inside, cord, TeddyPalette.cord, width: 0.75)
            sticker(&inside, circle(CGPoint(x: bottom, y: 30.7), 0.75), TeddyPalette.cord, rim: 0.45)
        }
        graphics.stroke(torso, with: .color(TeddyPalette.ink), style: StrokeStyle(lineWidth: outline, lineJoin: .round))
    }

    private static func drawFrontSuit(in graphics: inout GraphicsContext) {
        sticker(&graphics, seatPath(), TeddyPalette.suit)
        var crease = Path()
        crease.move(to: CGPoint(x: 20, y: 38.6))
        crease.addLine(to: CGPoint(x: 20, y: 41.6))
        stroke(&graphics, crease, TeddyPalette.suitDark, width: 0.6)

        let torso = torsoPath()
        fill(&graphics, torso, TeddyPalette.suit)
        var inside = graphics
        inside.clip(to: torso)

        // Waistcoat, white shirt and tie down the middle.
        var vest = Path()
        vest.move(to: CGPoint(x: 16.2, y: 24.4))
        vest.addLine(to: CGPoint(x: 23.8, y: 24.4))
        vest.addLine(to: CGPoint(x: 23.0, y: 36.4))
        vest.addLine(to: CGPoint(x: 20, y: 38.4))
        vest.addLine(to: CGPoint(x: 17.0, y: 36.4))
        vest.closeSubpath()
        sticker(&inside, vest, TeddyPalette.waistcoat, rim: 0.6)
        var shirt = Path()
        shirt.move(to: CGPoint(x: 17.3, y: 24.4))
        shirt.addLine(to: CGPoint(x: 22.7, y: 24.4))
        shirt.addLine(to: CGPoint(x: 20, y: 30.2))
        shirt.closeSubpath()
        sticker(&inside, shirt, TeddyPalette.shirt, rim: 0.5)
        // Lapels.
        for sign in [-1.0, 1.0] as [CGFloat] {
            var lapel = Path()
            lapel.move(to: CGPoint(x: 20 + sign * 5.0, y: 24.4))
            lapel.addLine(to: CGPoint(x: 20 + sign * 2.6, y: 24.4))
            lapel.addLine(to: CGPoint(x: 20 + sign * 0.5, y: 29.6))
            lapel.addLine(to: CGPoint(x: 20 + sign * 2.9, y: 31.4))
            lapel.closeSubpath()
            sticker(&inside, lapel, TeddyPalette.suitLight, rim: 0.6)
        }
        var blade = Path()
        blade.move(to: CGPoint(x: 19.1, y: 26.4))
        blade.addLine(to: CGPoint(x: 20.9, y: 26.4))
        blade.addLine(to: CGPoint(x: 21.2, y: 30.4))
        blade.addLine(to: CGPoint(x: 20, y: 31.4))
        blade.addLine(to: CGPoint(x: 18.8, y: 30.4))
        blade.closeSubpath()
        sticker(&inside, blade, TeddyPalette.tie, rim: 0.45)
        sticker(&inside, Path(ellipseIn: CGRect(x: 19.0, y: 24.9, width: 2.0, height: 1.8)), TeddyPalette.tie, rim: 0.45)
        // Gold buttons, pocket-watch chain and jacket pocket flaps.
        for y in [33.0, 34.9, 36.6] as [CGFloat] {
            sticker(&inside, circle(CGPoint(x: 20, y: y), 0.6), TeddyPalette.gold, rim: 0.3)
        }
        var chain = Path()
        chain.move(to: CGPoint(x: 20.4, y: 33.0))
        chain.addQuadCurve(to: CGPoint(x: 22.6, y: 34.4), control: CGPoint(x: 21.4, y: 35.6))
        stroke(&inside, chain, TeddyPalette.ink, width: 1.3)
        stroke(&inside, chain, TeddyPalette.gold, width: 0.6)
        sticker(&inside, circle(CGPoint(x: 22.6, y: 34.4), 0.85), TeddyPalette.gold, rim: 0.4)
        var flaps = Path()
        flaps.move(to: CGPoint(x: 13.2, y: 34.8))
        flaps.addLine(to: CGPoint(x: 16.0, y: 35.0))
        flaps.move(to: CGPoint(x: 26.8, y: 34.8))
        flaps.addLine(to: CGPoint(x: 24.8, y: 35.0))
        stroke(&inside, flaps, TeddyPalette.suitDark, width: 0.8)
        graphics.stroke(torso, with: .color(TeddyPalette.ink), style: StrokeStyle(lineWidth: outline, lineJoin: .round))
    }

    // MARK: Back

    static func drawBackTorso(in graphics: inout GraphicsContext, outfit: TeddyOutfit) {
        switch outfit {
        case .hoodie: drawBackHoodie(in: &graphics)
        case .suit: drawBackSuit(in: &graphics)
        }
    }

    private static func drawBackHoodie(in graphics: inout GraphicsContext) {
        sticker(&graphics, seatPath(), TeddyPalette.jeans)
        drawBackPockets(in: &graphics, stitch: TeddyPalette.jeansDark)

        let torso = torsoPath()
        fill(&graphics, torso, TeddyPalette.hoodie)
        var inside = graphics
        inside.clip(to: torso)
        fill(&inside, Path(CGRect(x: 10, y: 35.2, width: 20, height: 5)), TeddyPalette.hoodieDark)
        // The hood draped over the shoulders.
        fill(&inside, Path(ellipseIn: CGRect(x: 12.2, y: 23.6, width: 15.6, height: 6.2)), TeddyPalette.hoodieDark)
        var seam = Path()
        seam.move(to: CGPoint(x: 20, y: 30.2))
        seam.addLine(to: CGPoint(x: 20, y: 35))
        inside.stroke(seam, with: .color(TeddyPalette.hoodieDark), style: StrokeStyle(lineWidth: 0.7, lineCap: .round, dash: [1.2, 1.2]))
        graphics.stroke(torso, with: .color(TeddyPalette.ink), style: StrokeStyle(lineWidth: outline, lineJoin: .round))
        drawTail(in: &graphics)
    }

    private static func drawBackSuit(in graphics: inout GraphicsContext) {
        sticker(&graphics, seatPath(), TeddyPalette.suit)
        var welts = Path()
        welts.move(to: CGPoint(x: 14.0, y: 39.4))
        welts.addLine(to: CGPoint(x: 17.4, y: 39.4))
        welts.move(to: CGPoint(x: 22.6, y: 39.4))
        welts.addLine(to: CGPoint(x: 26.0, y: 39.4))
        stroke(&graphics, welts, TeddyPalette.suitDark, width: 0.8)

        let torso = torsoPath()
        fill(&graphics, torso, TeddyPalette.suit)
        var inside = graphics
        inside.clip(to: torso)
        fill(&inside, Path(ellipseIn: CGRect(x: 13.6, y: 23.4, width: 12.8, height: 4.0)), TeddyPalette.suitLight)
        var seams = Path()
        seams.move(to: CGPoint(x: 20, y: 27))
        seams.addLine(to: CGPoint(x: 20, y: 37.6))
        seams.move(to: CGPoint(x: 14.2, y: 28.5))
        seams.addQuadCurve(to: CGPoint(x: 15.0, y: 36.4), control: CGPoint(x: 14.0, y: 32.5))
        seams.move(to: CGPoint(x: 25.8, y: 28.5))
        seams.addQuadCurve(to: CGPoint(x: 25.0, y: 36.4), control: CGPoint(x: 26.0, y: 32.5))
        stroke(&inside, seams, TeddyPalette.suitDark, width: 0.65)
        // Vent flaps at the hem.
        var vent = Path()
        vent.move(to: CGPoint(x: 20.8, y: 34.6))
        vent.addLine(to: CGPoint(x: 20.8, y: 37.8))
        stroke(&inside, vent, TeddyPalette.suitDark, width: 0.6)
        graphics.stroke(torso, with: .color(TeddyPalette.ink), style: StrokeStyle(lineWidth: outline, lineJoin: .round))
        drawTail(in: &graphics)
    }

    /// Two jeans back pockets with stitching.
    private static func drawBackPockets(in graphics: inout GraphicsContext, stitch: Color) {
        for x in [13.2, 22.2] as [CGFloat] {
            var pocket = Path()
            pocket.move(to: CGPoint(x: x, y: 38.4))
            pocket.addLine(to: CGPoint(x: x + 4.6, y: 38.4))
            pocket.addLine(to: CGPoint(x: x + 4.6, y: 40.6))
            pocket.addLine(to: CGPoint(x: x + 2.3, y: 41.6))
            pocket.addLine(to: CGPoint(x: x, y: 40.6))
            pocket.closeSubpath()
            graphics.stroke(pocket, with: .color(stitch), style: StrokeStyle(lineWidth: 0.7, lineJoin: .round, dash: [1.1, 0.7]))
        }
    }

    private static func drawTail(in graphics: inout GraphicsContext) {
        sticker(&graphics, circle(CGPoint(x: 20, y: 38.0), 2.5), TeddyPalette.fur)
        fill(&graphics, circle(CGPoint(x: 19.3, y: 37.3), 0.8), TeddyPalette.tan)
    }

    // MARK: Shoes

    /// White low-top sneakers (plain, light grey sole, no logo) or black dress shoes.
    /// Front-view toes point outwards; from behind only the heel shows.
    static func drawShoe(in graphics: inout GraphicsContext, at tip: CGPoint, isLeft: Bool, isBack: Bool, outfit: TeddyOutfit) {
        let isSneaker = outfit == .hoodie
        let width: CGFloat = isBack ? 7.0 : 8.8
        let height: CGFloat = 4.6
        let originX: CGFloat
        if isBack {
            originX = tip.x - width / 2
        } else {
            originX = isLeft ? tip.x - (width - 3.9) : tip.x - 3.9
        }
        let rect = CGRect(x: originX, y: tip.y - 0.7, width: width, height: height)
        let shape = Path(roundedRect: rect, cornerRadius: 2.1)
        fill(&graphics, shape, isSneaker ? TeddyPalette.sneaker : TeddyPalette.shoe)
        var inside = graphics
        inside.clip(to: shape)
        let soleRect = CGRect(x: rect.minX, y: rect.maxY - 1.4, width: width, height: 1.4)
        fill(&inside, Path(soleRect), isSneaker ? TeddyPalette.sole : Color(red: 0.06, green: 0.055, blue: 0.06))
        var detail = Path()
        if isSneaker {
            // Plain laces on the front view, a heel tab from behind.
            if isBack {
                detail.move(to: CGPoint(x: tip.x, y: rect.minY + 0.7))
                detail.addLine(to: CGPoint(x: tip.x, y: rect.maxY - 1.8))
            } else {
                let towardsToe: CGFloat = isLeft ? -1 : 1
                for dx in [0.2, 1.3] as [CGFloat] {
                    detail.move(to: CGPoint(x: tip.x + towardsToe * dx * 1.6, y: rect.minY + 0.5))
                    detail.addLine(to: CGPoint(x: tip.x + towardsToe * dx * 1.6, y: rect.minY + 1.6))
                }
            }
            stroke(&inside, detail, TeddyPalette.sole, width: 0.6)
        } else if !isBack {
            let towardsToe: CGFloat = isLeft ? -1 : 1
            detail.move(to: CGPoint(x: tip.x + towardsToe * 3.0, y: rect.minY + 1.0))
            detail.addQuadCurve(to: CGPoint(x: tip.x + towardsToe * 1.0, y: rect.minY + 0.7), control: CGPoint(x: tip.x + towardsToe * 2.0, y: rect.minY + 0.5))
            stroke(&inside, detail, Color(red: 0.5, green: 0.5, blue: 0.54), width: 0.6)
        }
        graphics.stroke(shape, with: .color(TeddyPalette.ink), style: StrokeStyle(lineWidth: 0.9, lineJoin: .round))
    }
}
