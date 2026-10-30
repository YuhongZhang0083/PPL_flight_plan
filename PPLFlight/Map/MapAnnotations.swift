import Foundation
import MapKit
import UIKit

final class AirportAnnotation: NSObject, MKAnnotation {
    let airport: Airport
    var category: String?
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(airport: Airport, category: String?) {
        self.airport = airport
        self.category = category
        self.coordinate = airport.coordinate
    }
}

final class OwnshipAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var track: Double = 0
    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}

final class ObstacleAnnotation: NSObject, MKAnnotation {
    let obstacle: Obstacle
    var coordinate: CLLocationCoordinate2D { obstacle.coordinate }
    var title: String? { "\(obstacle.type.capitalized) \(Int(obstacle.amslFt))' MSL" }
    var subtitle: String? { "\(Int(obstacle.aglFt))' AGL\(obstacle.lighted ? " · lighted" : "")" }
    init(_ o: Obstacle) { obstacle = o }
}

final class WaypointAnnotation: NSObject, MKAnnotation {
    let waypoint: Waypoint
    var coordinate: CLLocationCoordinate2D { waypoint.coordinate }
    var title: String? { waypoint.ident }
    init(_ w: Waypoint) { waypoint = w }
}

final class PinAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(_ c: CLLocationCoordinate2D) { coordinate = c }
}

enum MarkerImages {
    private static var cache: [String: UIImage] = [:]

    static func airport(ident: String, color: UIColor, rank: Int, towered: Bool, showLabel: Bool) -> UIImage {
        let key = "\(ident)|\(color.description)|\(rank)|\(towered)|\(showLabel)"
        if let i = cache[key] { return i }
        let r: CGFloat = rank >= 2 ? 7 : 5.5
        let font = UIFont.systemFont(ofSize: 11, weight: .bold)
        let label = ident as NSString
        let textSize = showLabel ? label.size(withAttributes: [.font: font]) : .zero
        let size = CGSize(width: r * 2 + 4 + (showLabel ? textSize.width + 8 : 0), height: max(r * 2 + 4, textSize.height + 4))
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let center = CGPoint(x: r + 2, y: size.height / 2)
            let circle = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            c.setFillColor(color.cgColor)
            c.fillEllipse(in: circle)
            c.setStrokeColor(UIColor.black.withAlphaComponent(0.8).cgColor)
            c.setLineWidth(1.5)
            c.strokeEllipse(in: circle)
            if towered {
                c.setStrokeColor(UIColor.white.cgColor)
                c.setLineWidth(1.2)
                c.strokeEllipse(in: circle.insetBy(dx: 2.2, dy: 2.2))
            }
            if showLabel {
                let tr = CGRect(x: r * 2 + 6, y: (size.height - textSize.height) / 2 - 1, width: textSize.width + 6, height: textSize.height + 2)
                let bg = UIBezierPath(roundedRect: tr.insetBy(dx: -1, dy: 0), cornerRadius: 3)
                UIColor.black.withAlphaComponent(0.65).setFill()
                bg.fill()
                label.draw(at: CGPoint(x: tr.minX + 3, y: tr.minY + 1), withAttributes: [.font: font, .foregroundColor: UIColor.white])
            }
        }
        cache[key] = img
        return img
    }

    static let ownship: UIImage = {
        let s: CGFloat = 40
        return UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: s / 2, y: s / 2)
            let k: CGFloat = s / 520
            let pts: [(CGFloat, CGFloat)] = [(0, -250), (28, -210), (34, -70), (250, 10), (250, 52), (34, 20), (24, 170), (95, 215), (95, 245), (0, 225),
                                             (-95, 245), (-95, 215), (-24, 170), (-34, 20), (-250, 52), (-250, 10), (-34, -70), (-28, -210)]
            let path = UIBezierPath()
            for (i, p) in pts.enumerated() {
                let q = CGPoint(x: p.0 * k, y: p.1 * k)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            path.close()
            c.setShadow(offset: .zero, blur: 3, color: UIColor.black.cgColor)
            UIColor(red: 0.2, green: 0.85, blue: 1, alpha: 1).setFill()
            path.fill()
            c.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor.black.setStroke()
            path.lineWidth = 1.2
            path.stroke()
        }
    }()

    static func obstacle(color: UIColor, tall: Bool) -> UIImage {
        let key = "obs|\(color.description)|\(tall)"
        if let i = cache[key] { return i }
        let h: CGFloat = tall ? 18 : 13, w: CGFloat = tall ? 12 : 9
        let img = UIGraphicsImageRenderer(size: CGSize(width: w + 2, height: h + 2)).image { ctx in
            let p = UIBezierPath()
            p.move(to: CGPoint(x: 1, y: h + 1)); p.addLine(to: CGPoint(x: w / 2 + 1, y: 1)); p.addLine(to: CGPoint(x: w + 1, y: h + 1))
            UIColor.black.setStroke(); p.lineWidth = 3.5; p.stroke()
            color.setStroke(); p.lineWidth = 2; p.stroke()
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: w / 2 - 1, y: h - 3, width: 4, height: 4)).fill()
        }
        cache[key] = img
        return img
    }

    static func waypoint(_ ident: String) -> UIImage {
        let key = "wp|\(ident)"
        if let i = cache[key] { return i }
        let font = UIFont.systemFont(ofSize: 11, weight: .heavy)
        let ts = (ident as NSString).size(withAttributes: [.font: font])
        let size = CGSize(width: 16 + ts.width + 8, height: max(16, ts.height + 4))
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            let d = UIBezierPath()
            let cy = size.height / 2
            d.move(to: CGPoint(x: 8, y: cy - 7)); d.addLine(to: CGPoint(x: 15, y: cy)); d.addLine(to: CGPoint(x: 8, y: cy + 7)); d.addLine(to: CGPoint(x: 1, y: cy)); d.close()
            UIColor(red: 1, green: 0, blue: 0.8, alpha: 1).setFill(); d.fill()
            UIColor.white.setStroke(); d.lineWidth = 1.2; d.stroke()
            (ident as NSString).draw(at: CGPoint(x: 19, y: cy - ts.height / 2), withAttributes: [.font: font, .foregroundColor: UIColor.white,
                                                                                                  .strokeColor: UIColor.black, .strokeWidth: -3])
        }
        cache[key] = img
        return img
    }
}
