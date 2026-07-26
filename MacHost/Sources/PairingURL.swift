import Foundation

enum PairingURL {
    static func build(host: String, port: UInt16, token: Data, name: String) -> String {
        let tokenStr = base64URLEncode(token)
        var nameAllowed = CharacterSet.urlQueryAllowed
        nameAllowed.remove(charactersIn: "&=?#")
        let nameEncoded = name.addingPercentEncoding(withAllowedCharacters: nameAllowed) ?? ""
        return "sidescreen://\(host):\(port)?t=\(tokenStr)&name=\(nameEncoded)"
    }

    static func buildCameraAppURL(host: String, port: UInt16) -> String {
        "sidescreen://\(host):\(port)/camera"
    }

    static func buildCameraPairPageURL(host: String, previewPort: UInt16, cameraPort: UInt16) -> String {
        "http://\(host):\(previewPort)/camera-pair?h=\(host)&p=\(cameraPort)"
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
