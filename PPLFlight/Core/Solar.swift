import Foundation

/// Sunrise / sunset (official zenith 90.833°) using the NOAA "Almanac for Computers" algorithm.
enum Solar {
    static func times(on date: Date, latitude: Double, longitude: Double) -> (sunrise: Date?, sunset: Date?) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let dayStart = utc.startOfDay(for: date)
        let n = Double(utc.ordinality(of: .day, in: .year, for: date) ?? 1)
        let lngHour = longitude / 15
        let localMidnight = dayStart.addingTimeInterval(-lngHour * 3600)

        func event(_ rising: Bool) -> Date? {
            let t = n + ((rising ? 6 : 18) - lngHour) / 24
            let m = 0.9856 * t - 3.289
            var l = m + 1.916 * sin(Geo.rad(m)) + 0.020 * sin(Geo.rad(2 * m)) + 282.634
            l = Geo.norm360(l)
            var ra = Geo.norm360(Geo.deg(atan(0.91764 * tan(Geo.rad(l)))))
            ra += floor(l / 90) * 90 - floor(ra / 90) * 90
            ra /= 15
            let sinDec = 0.39782 * sin(Geo.rad(l))
            let cosDec = cos(asin(sinDec))
            let cosH = (cos(Geo.rad(90.833)) - sinDec * sin(Geo.rad(latitude))) / (cosDec * cos(Geo.rad(latitude)))
            if cosH > 1 || cosH < -1 { return nil }
            var h = rising ? 360 - Geo.deg(acos(cosH)) : Geo.deg(acos(cosH))
            h /= 15
            let localT = h + ra - 0.06571 * t - 6.622
            var ut = (localT - lngHour).truncatingRemainder(dividingBy: 24)
            if ut < 0 { ut += 24 }
            var result = dayStart.addingTimeInterval(ut * 3600)
            while result < localMidnight { result.addTimeInterval(86400) }
            while result >= localMidnight.addingTimeInterval(86400) { result.addTimeInterval(-86400) }
            return result
        }
        return (event(true), event(false))
    }
}
