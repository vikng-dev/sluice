public enum Sluice {
    public static let version = "0.11.0"
    public static let port: UInt16 = 7483
    public static let address = "http://localhost:\(port)"
    /// Its bundle, its log and its Keychain item go by this.
    public static let id = "dev.vikng.sluice"
}
