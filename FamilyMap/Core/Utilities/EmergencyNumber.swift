import Foundation

/// Emergency number for the device's region (worldwide release, STAGE-7 addendum). Region comes
/// from `Locale.current.region` (iOS 16), i.e. the user's Region setting, not the SIM or GPS.
enum EmergencyNumber {
    /// GSM standard; also valid across the EU and most other networks, so it is the fallback.
    private static let fallback = "112"

    private static let byRegion: [String: String] = [
        // 000 / 111
        "AU": "000", "NZ": "111",
        // 911
        "US": "911", "CA": "911", "MX": "911", "PH": "911", "AR": "911", "SA": "911", "AE": "911",
        "CR": "911", "PA": "911", "DO": "911", "GT": "911", "HN": "911", "SV": "911", "UY": "911", "PE": "911",
        // 999
        "GB": "999", "IE": "999", "HK": "999", "SG": "999", "MY": "999", "KE": "999", "BD": "999", "QA": "999",
        // 110 / 119 / 100 / 190 / 10111
        "JP": "110", "CN": "110", "TW": "110", "ID": "110", "BR": "190", "ZA": "10111", "TH": "191", "VN": "113",
        "PK": "15", "NG": "112", "EG": "122", "IL": "100", "CL": "133", "CO": "123", "VE": "911",
        // 112 (EU, Korea, India, Russia, Turkey and most GSM networks) is the fallback
        "KR": "112", "IN": "112"
    ]

    static func forCurrentRegion() -> String {
        guard let region = Locale.current.region?.identifier else { return fallback }
        return byRegion[region] ?? fallback
    }
}
