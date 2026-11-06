import Foundation

public struct SayoDeviceSnapshot: Equatable, Codable, Sendable {
    public var product: String
    public var manufacturer: String
    public var serialNumber: String
    public var vendorID: UInt16
    public var productID: UInt16
    public var locationID: UInt32
    public var firmwareVersion: UInt16?
    public var modelCode: UInt16?
    public var supportedCommands: [UInt8]
    public var buttons: [SayoButtonConfiguration]

    public init(
        product: String,
        manufacturer: String,
        serialNumber: String,
        vendorID: UInt16,
        productID: UInt16,
        locationID: UInt32,
        firmwareVersion: UInt16? = nil,
        modelCode: UInt16? = nil,
        supportedCommands: [UInt8] = [],
        buttons: [SayoButtonConfiguration] = []
    ) {
        self.product = product
        self.manufacturer = manufacturer
        self.serialNumber = serialNumber
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
        self.firmwareVersion = firmwareVersion
        self.modelCode = modelCode
        self.supportedCommands = supportedCommands
        self.buttons = buttons
    }
}
