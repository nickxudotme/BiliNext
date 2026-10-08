import Foundation
import CryptoKit

// Protocol permutation also documented in PiliPlus and BBHouse's signers.
public enum WBISigner {
    private static let permutation = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13]
    public static func mixinKey(image: String, sub: String) throws -> String {
        let bytes = Array((image + sub).utf8)
        guard image.utf8.count == 32, sub.utf8.count == 32 else { throw APIError(code: -1, message: "WBI 密钥格式异常") }
        return String(decoding: permutation.map { bytes[$0] }, as: UTF8.self)
    }
    public static func query(_ parameters: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed)! }
        return parameters.keys.sorted().map { "\(encode($0))=\(encode(parameters[$0]!))" }.joined(separator: "&")
    }
    public static func sign(_ parameters: [String: String], key: String, timestamp: Int) -> [String: String] {
        var clean = parameters.mapValues { String($0.filter { !"!'()*".contains($0) }) }
        clean.removeValue(forKey: "w_rid"); clean["wts"] = String(timestamp)
        let digest = Insecure.MD5.hash(data: Data((query(clean) + key).utf8))
        clean["w_rid"] = digest.map { String(format: "%02x", $0) }.joined()
        return clean
    }
}
