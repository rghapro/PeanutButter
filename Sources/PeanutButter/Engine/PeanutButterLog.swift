import Foundation
import os

public enum PeanutButterLog {
    public static let subsystem = "com.peanutbutter.app"
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let hardware = Logger(subsystem: subsystem, category: "hardware")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let remote = Logger(subsystem: subsystem, category: "remote")
}
